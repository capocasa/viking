## viking — German tax submissions via the ELSTER ERiC library.
##
## CLI entry point. One subcommand per Steuerart:
##
## * `ustva`    — UStVA (Umsatzsteuervoranmeldung)
## * `euer`     — EÜR (Einnahmenüberschussrechnung)
## * `est`      — ESt (Einkommensteuererklärung), aggregates every source
## * `ust`      — annual USt (Umsatzsteuererklärung)
## * `iban`     — change bank account (AenderungBankverbindung)
## * `message`  — SonstigeNachrichten (free-text message to the Finanzamt)
## * `list`     — list documents in the ELSTER Postfach
## * `download` — fetch documents from the Postfach
## * `fetch`    — download/install the ERiC runtime
## * `init`     — seed `viking.conf` and `deductions.tsv` skeletons
##
## Configuration lives in `viking.conf`; signing in `[auth]`. See
## `vikingconf <vikingconf.html>`_ for the data model and `docs.rst`
## for the user guide.

import std/[strutils, strformat, options, os, tables]
import cligen
import viking/[config, ericffi, ottoffi, ustva_xml, euer_xml, est_xml, ust_xml, ericsetup, invoices, abholung_xml, nachricht_xml, bankverbindung_xml]
import viking/[vikingconf, deductions, kap, log, abholung, codes]

const NimblePkgVersion {.strdefine.} = "dev"

proc loadConf(conf: string, validate: proc(conf: VikingConf): seq[string]): tuple[ok: bool, conf: VikingConf] =
  var vikingConf: VikingConf
  try:
    vikingConf = loadVikingConf(conf)
  except IOError as e:
    err &"Error: {e.msg}"
    return (false, vikingConf)
  except ValueError as e:
    err &"Error parsing viking.conf: {e.msg}"
    return (false, vikingConf)
  let errors = validate(vikingConf)
  if errors.len > 0:
    err "Configuration errors:"
    for e in errors:
      err &"  - {e}"
    return (false, vikingConf)
  return (true, vikingConf)

proc loadConfForSource(conf: string, srcName: string,
                       kinds: set[SourceKind],
                       validate: proc(conf: VikingConf, src: Source): seq[string]):
                       tuple[ok: bool, conf: VikingConf, src: Source] =
  var vc: VikingConf
  var src: Source
  try:
    vc = loadVikingConf(conf)
  except IOError as e:
    err &"Error: {e.msg}"
    return (false, vc, src)
  except ValueError as e:
    err &"Error parsing viking.conf: {e.msg}"
    return (false, vc, src)

  let candidates = vc.sourcesOfKind(kinds)
  if candidates.len == 0:
    err &"Error: no matching source defined in viking.conf"
    return (false, vc, src)

  var chosen = -1
  if srcName == "":
    if candidates.len == 1:
      for i, s in vc.sources:
        if s.name == candidates[0].name:
          chosen = i
          break
    else:
      var names: seq[string]
      for s in candidates: names.add(s.name)
      err &"Error: multiple sources defined, specify one: " & names.join(", ")
      return (false, vc, src)
  else:
    chosen = vc.findSource(srcName)
    if chosen < 0:
      err &"Error: source '{srcName}' not found in viking.conf"
      return (false, vc, src)
    if vc.sources[chosen].kind notin kinds:
      err &"Error: source '{srcName}' is not a matching kind for this command"
      return (false, vc, src)

  src = vc.sources[chosen]
  let errors = validate(vc, src)
  if errors.len > 0:
    err "Configuration errors:"
    for e in errors:
      err &"  - {e}"
    return (false, vc, src)
  return (true, vc, src)

proc loadTechConfig(dataDir: string, test: bool): tuple[ok: bool, cfg: Config] =
  ## Derive ERiC paths from the data dir and carry the --test flag.
  let cfg = loadConfig(dataDir, test)
  let errors = cfg.validate()
  if errors.len > 0:
    err "Configuration error:"
    for e in errors:
      err &"  - {e}"
    return (false, cfg)
  return (true, cfg)

proc resolveSigningAuth(vc: VikingConf): tuple[ok: bool, certPath, certPin: string] =
  ## Resolve cert path + pin for actual signing. Returns (false, ...) on error.
  let certPath = vc.resolveCertPath()
  if not fileExists(certPath):
    err &"Error: cert not found: {certPath} (check [auth].cert in viking.conf)"
    return (false, "", "")
  var pin: string
  try:
    pin = vc.resolvePin()
  except CatchableError as e:
    err &"Error: {e.msg}"
    return (false, "", "")
  (true, certPath, pin)

proc handleEricError(rc: int, response, serverResponse: string, ericLogPath: string) =
  err &"Error: ERiC code {rc}: {ericHoleFehlerText(rc)}"
  case rc
  of 610301202:
    err "Hint: The HerstellerID is blocked."
    err "  Register at https://www.elster.de/elsterweb/entwickler"
  of 610301200:
    err "Hint: XML schema validation failed."
    let logFile = ericLogPath / "eric.log"
    if fileExists(logFile):
      let logContent = readFile(logFile).strip
      if logContent.len > 0:
        err logContent
  of 610001050:
    err "Hint: Buffer instance mismatch - likely a bug in the FFI bindings."
  else:
    discard
  if response.len > 0:
    log response
  if serverResponse.len > 0:
    log serverResponse

template initEric(cfg: Config, dryRun: bool, xml: string) =
  if not loadEricLib(cfg.ericLibPath):
    err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()
  createDir(cfg.ericLogPath)
  block:
    let ericInitRc {.inject.} = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
    if ericInitRc != 0:
      err &"Error: ERiC initialization failed with code {ericInitRc}: {ericHoleFehlerText(ericInitRc)}"
      return 1
  defer: discard ericBeende()
  if dryRun:
    echo xml

template initBuffersAndCert(certPath, certPin: string, dryRun: bool, outputPdf: string) =
  let responseBuf {.inject.} = ericRueckgabepufferErzeugen()
  let serverBuf {.inject.} = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    err "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)
  var flags {.inject.}: uint32 = ERIC_VALIDIERE
  if not dryRun:
    flags = flags or ERIC_SENDE
  var druckParam: EricDruckParameterT
  var druckParamPtr {.inject.}: ptr EricDruckParameterT = nil
  if outputPdf != "":
    flags = flags or ERIC_DRUCKE
    druckParam.version = 4
    druckParam.vorschau = if dryRun: 1 else: 0
    druckParam.ersteSeite = 1
    druckParam.duplexDruck = 0
    druckParam.pdfName = outputPdf.cstring
    druckParam.fussText = nil
    druckParamPtr = addr druckParam
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr {.inject.}: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0
  if not dryRun:
    block:
      let (ericCertRc {.inject.}, ericCertHandle {.inject.}) = ericGetHandleToCertificate(certPath)
      if ericCertRc != 0:
        err &"Error: Failed to open certificate: {ericHoleFehlerText(ericCertRc)}"
        return 1
      certHandle = ericCertHandle
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = certPin.cstring
    cryptParamPtr = addr cryptParam
  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

template submitAndCheck(xml: string, datenartVersion: string) =
  var transferHandle {.inject.}: uint32 = 0
  let rc {.inject.} = ericBearbeiteVorgang(xml, datenartVersion, flags, druckParamPtr,
    cryptParamPtr, addr transferHandle, responseBuf, serverBuf)
  let response {.inject.} = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse {.inject.} = ericRueckgabepufferInhalt(serverBuf)
  if rc == 0:
    if serverResponse.len > 0: log serverResponse
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

proc ustva(
  source: seq[string] = @[],
  period: string = "",
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit a UStVA (Umsatzsteuervoranmeldung) for a source.
  ##
  ## Source positional arg selects the income source from viking.conf;
  ## omit if exactly one EÜR source is defined. Amounts come from
  ## the source's `euer=` TSV; tax year comes from `personal.year`.

  if period == "":
    err "Error: --period is required; " & periodMap.listing
    return 1
  var normalizedPeriod: string
  try:
    normalizedPeriod = periodMap.resolve(period)
  except ValueError:
    err &"Error: Invalid period '{period}'; " & periodMap.listing
    return 1

  let srcName = if source.len > 0: source[0] else: ""
  let (confOk, vikingConf, src) = loadConfForSource(conf, srcName,
    {skGewerbe, skFreelance}, validateForUstva)
  if not confOk: return 1

  let year = vikingConf.personal.year
  log.verbose = verbose
  initLog(year)
  defer: closeLog()

  var amount19, amount7, amount0: Option[float]
  let tsvPath = resolveEuerPath(vikingConf, src)
  if tsvPath == "":
    err &"Warning: source [{src.name}] has no euer= set; submitting zeros"
    amount19 = some(0.0)
  elif not fileExists(tsvPath):
    err &"Error: invoice TSV not found: {tsvPath}"
    return 1
  else:
    let (agg, _, ok) = loadAndAggregateInvoices(tsvPath, year, normalizedPeriod)
    if not ok: return 1
    amount19 = agg.amount19
    amount7 = agg.amount7
    amount0 = agg.amount0
    if amount19.isNone and amount7.isNone and amount0.isNone:
      amount19 = some(0.0)

  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let p = vikingConf.personal
  let fullName = p.firstname & " " & p.lastname
  let fullStreet = p.street & " " & p.housenumber
  let stnr = vikingConf.effectiveTaxnumber(src)

  let xml = generateUstva(
    steuernummer = stnr,
    jahr = year,
    zeitraum = normalizedPeriod,
    kz81 = amount19,
    kz86 = amount7,
    kz45 = amount0,
    name = fullName,
    strasse = fullStreet,
    plz = p.zip,
    ort = p.city,
    test = cfg.test,
    produktVersion = NimblePkgVersion,
  )

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, &"UStVA_{year}")
  return 0

proc euer(
  source: seq[string] = @[],
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit an EÜR for a source.
  ##
  ## Loads the source's `euer=` TSV. Positive = income,
  ## negative = expenses. Tax year comes from `personal.year`.

  let srcName = if source.len > 0: source[0] else: ""
  let (confOk, vikingConf, src) = loadConfForSource(conf, srcName,
    {skGewerbe, skFreelance}, validateForEuer)
  if not confOk: return 1

  let year = vikingConf.personal.year
  log.verbose = verbose
  initLog(year)
  defer: closeLog()

  let tsvPath = resolveEuerPath(vikingConf, src)
  var agg: EuerAggregation
  if tsvPath == "":
    err &"Warning: source [{src.name}] has no euer= set; submitting zeros"
  elif not fileExists(tsvPath):
    err &"Error: invoice TSV not found: {tsvPath}"
    return 1
  else:
    let (a, ok) = loadAndAggregateForEuer(tsvPath)
    if not ok: return 1
    agg = a

  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let p = vikingConf.personal
  let fullName = p.firstname & " " & p.lastname
  let fullStreet = p.street & " " & p.housenumber
  let einkunftsart = case src.kind
    of skGewerbe: "2"
    of skFreelance: "3"
    else: "3"

  let xml = generateEuer(EuerInput(
    steuernummer: vikingConf.effectiveTaxnumber(src), jahr: year,
    incomeNet: agg.incomeNet, incomeVat: agg.incomeVat,
    expenseNet: agg.expenseNet, expenseVorsteuer: agg.expenseVorsteuer,
    rechtsform: src.rechtsform, einkunftsart: einkunftsart,
    name: fullName, strasse: fullStreet, plz: p.zip, ort: p.city,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, &"EUER_{year}")
  return 0

proc est(
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  force: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit an ESt (Einkommensteuererklarung / income tax return).
  ##
  ## Aggregates all sources in viking.conf:
  ## - Anlage G/S: loads each source's `euer=` TSV,
  ##   computes profit, adds to Anlage G/S
  ## - Anlage KAP: reads inline values
  ##
  ## Deductions come from `personal.deductions`. Tax year from
  ## `personal.year`.

  let (confOk, vikingConf) = loadConf(conf, validateForEst)
  if not confOk: return 1

  let year = vikingConf.personal.year
  log.verbose = verbose
  initLog(year)
  defer: closeLog()

  var gewerbeProfits: seq[ProfitEntry] = @[]
  var freelanceProfits: seq[ProfitEntry] = @[]

  for src in vikingConf.euerSources:
    let tsvPath = resolveEuerPath(vikingConf, src)
    var profit = 0.0
    if tsvPath == "":
      err &"Warning: source [{src.name}] has no euer= set; counting 0 profit"
    elif not fileExists(tsvPath):
      err &"Error: source [{src.name}] invoice TSV not found: {tsvPath}"
      return 1
    else:
      let (agg, ok) = loadAndAggregateForEuer(tsvPath)
      if not ok: return 1
      profit = (agg.incomeNet + agg.incomeVat) - (agg.expenseNet + agg.expenseVorsteuer)
    let entry = ProfitEntry(label: src.name, profit: profit)
    case src.kind
    of skGewerbe: gewerbeProfits.add(entry)
    of skFreelance: freelanceProfits.add(entry)
    else: discard

  let kapTotals = aggregateKap(vikingConf.sources)

  var ded: DeductionsByForm
  let dedPath = resolveDeductionsPath(vikingConf)
  if dedPath != "":
    if not fileExists(dedPath):
      err &"Error: Deductions file not found: {dedPath}"
      return 1
    try:
      ded = loadDeductions(dedPath, vikingConf.kidFirstnames)
    except ValueError as e:
      err &"Error parsing deductions: {e.msg}"
      return 1
  elif not force:
    err "Warning: no deductions set. Either add `deductions = …` to the taxpayer section of viking.conf, or use --force to suppress."

  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let xml = generateEst(EstInput(
    conf: vikingConf, year: year,
    gewerbeProfits: gewerbeProfits, freelanceProfits: freelanceProfits,
    kapTotals: kapTotals, deductions: ded,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, &"ESt_{year}")
  return 0

proc ust(
  source: seq[string] = @[],
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit an annual VAT return (Umsatzsteuererklaerung) for a source.
  ##
  ## Loads the source's `euer=` TSV. Vorauszahlungen from source section.
  ## Tax year comes from `personal.year`.

  let srcName = if source.len > 0: source[0] else: ""
  let (confOk, vikingConf, src) = loadConfForSource(conf, srcName,
    {skGewerbe, skFreelance}, validateForUst)
  if not confOk: return 1

  let year = vikingConf.personal.year
  log.verbose = verbose
  initLog(year)
  defer: closeLog()

  let tsvPath = resolveEuerPath(vikingConf, src)
  var agg: UstAggregation
  if tsvPath == "":
    err &"Warning: source [{src.name}] has no euer= set; submitting zeros"
  elif not fileExists(tsvPath):
    err &"Error: invoice TSV not found: {tsvPath}"
    return 1
  else:
    let (a, ok) = loadAndAggregateForUst(tsvPath)
    if not ok: return 1
    agg = a

  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let p = vikingConf.personal
  let fullName = p.firstname & " " & p.lastname
  let xml = generateUst(UstInput(
    steuernummer: vikingConf.effectiveTaxnumber(src), jahr: year,
    income19: agg.income19, income7: agg.income7, income0: agg.income0,
    has19: agg.has19, has7: agg.has7, has0: agg.has0,
    vorsteuer: agg.vorsteuer, vorauszahlungen: src.vorauszahlungen,
    besteuerungsart: src.besteuerungsart,
    name: fullName, strasse: p.street & " " & p.housenumber,
    plz: p.zip, ort: p.city,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, &"USt_{year}")
  return 0

proc fetch(file: string = "", check: bool = false, data_dir: string = ""): int =
  ## Fetch and install the ERiC library.

  initLog()
  defer: closeLog()

  let effectiveDataDir = if dataDir != "": dataDir else: getAppDataDir()
  let ericDir = effectiveDataDir / "eric"

  if check:
    let existing = findExistingEric(ericDir)
    if existing.valid:
      printStatus(existing)
      let years = listAvailableYears(existing)
      if years.len > 0:
        echo &"  UStVA years: {years.join(\", \")}"
      let euerYears = listAvailableEuerYears(existing)
      if euerYears.len > 0:
        echo &"  EUER years:  {euerYears.join(\", \")}"
      let estYears = listAvailableEstYears(existing)
      if estYears.len > 0:
        echo &"  ESt years:   {estYears.join(\", \")}"
      let ustYears = listAvailableUstYears(existing)
      if ustYears.len > 0:
        echo &"  USt years:   {ustYears.join(\", \")}"
      return 0
    else:
      stderr.writeLine "No ERiC installation found."
      printDownloadInstructions(effectiveDataDir)
      return 1

  var installation: EricInstallation
  if file != "":
    installation = setupEric(file, ericDir)
  else:
    installation = findExistingEric(ericDir)
    if not installation.valid:
      let (inst, success) = fetchEric(effectiveDataDir)
      if success:
        installation = inst
      else:
        return 1

  if installation.valid:
    echo &"ERiC installed at {installation.path}"
    stderr.writeLine ""
    stderr.writeLine "For sandbox testing, grab ELSTER's test certs:"
    stderr.writeLine "  wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip"
    stderr.writeLine "  unzip Test_Zertifikate.zip   # PIN for all certs: 123456"
    return 0
  else:
    stderr.writeLine "ERiC setup incomplete. Use 'viking fetch --file=<path>' with a local archive."
    return 1

proc loadConfigAndEricForAbholung(
    conf, dataDir: string, test: bool
): tuple[rc: int, cfg: Config, vc: VikingConf, name: string] =
  let (confOk, vikingConf) = loadConf(conf, validateForAbholung)
  var cfg: Config
  var emptyVc: VikingConf
  if not confOk: return (1, cfg, emptyVc, "")

  let (techOk, cfgLoaded) = loadTechConfig(dataDir, test)
  if not techOk: return (1, cfgLoaded, emptyVc, "")
  cfg = cfgLoaded

  let name = vikingConf.personal.firstname & " " & vikingConf.personal.lastname

  if not loadEricLib(cfg.ericLibPath):
    err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return (1, cfg, emptyVc, "")

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    err &"Error: ERiC initialization failed: {ericHoleFehlerText(initRc)}"
    unloadEricLib()
    return (1, cfg, emptyVc, "")

  return (0, cfg, vikingConf, name)

proc list(
  conf: string = "",
  verbose: bool = false,
  dry_run: bool = false,
  data_dir: string = "",
  test: bool = false,
): int =
  ## List available documents in the tax office Postfach

  log.verbose = verbose
  initLog()
  defer: closeLog()

  let (cfgRc, cfg, vc, name) = loadConfigAndEricForAbholung(conf, dataDir, test)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
    return 0

  let (authOk, certPath, certPin) = resolveSigningAuth(vc)
  if not authOk: return 1

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(
    cfg, certPath, certPin, name, NimblePkgVersion, verbose)
  if rc != 0: return rc

  displayBereitstellungen(bereitstellungen)
  return 0

proc download(
  files: seq[string],
  conf: string = "",
  output_dir: string = "",
  force: bool = false,
  verbose: bool = false,
  dry_run: bool = false,
  data_dir: string = "",
  test: bool = false,
): int =
  ## Download documents from the tax office Postfach

  log.verbose = verbose
  initLog()
  defer: closeLog()

  let (cfgRc, cfg, vc, name) = loadConfigAndEricForAbholung(conf, dataDir, test)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
    return 0

  let (authOk, certPath, certPin) = resolveSigningAuth(vc)
  if not authOk: return 1

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(
    cfg, certPath, certPin, name, NimblePkgVersion, verbose)
  if rc != 0: return rc

  if bereitstellungen.len == 0:
    return 0

  let outDir = if output_dir.len > 0: output_dir else: "."
  if outDir != ".":
    createDir(outDir)

  let ottoLibName = when defined(macosx): "libotto.dylib"
                    elif defined(windows): "otto.dll"
                    else: "libotto.so"
  let ottoLibPath = cfg.ericLibPath.parentDir / ottoLibName
  if not loadOttoLib(ottoLibPath):
    err &"Error: Failed to load Otto library from {ottoLibPath}"
    return 1
  defer: unloadOttoLib()

  let (ottoRc, ottoInstanz) = ottoInstanzErzeugen(cfg.ericLogPath)
  if ottoRc != 0:
    err &"Error: Failed to create Otto instance: {ottoHoleFehlertext(ottoRc)}"
    return 1
  defer: discard ottoInstanzFreigeben(ottoInstanz)

  var confirmedIds: seq[string] = @[]
  var downloadErrors = 0

  for b in bereitstellungen:
    var allOk = true
    var anySelected = false
    var allSelected = true

    for a in b.anhaenge:
      let filename = constructFilename(b, a)

      if files.len > 0 and filename notin files:
        allSelected = false
        continue

      anySelected = true
      let filepath = outDir / filename

      if not force and fileExists(filepath):
        err &"Skipping {filename} (already exists, use --force to overwrite)"
        continue

      let (bufRc, ottoBuf) = ottoRueckgabepufferErzeugen(ottoInstanz)
      if bufRc != 0:
        err &"Error: Failed to create download buffer (code {bufRc})"
        allOk = false
        inc downloadErrors
        continue
      defer: discard ottoRueckgabepufferFreigeben(ottoBuf)

      let dlRc = ottoDatenAbholen(
        ottoInstanz, a.dateiReferenzId, a.dateiGroesse.uint32,
        certPath, certPin, HerstellerId, ottoBuf,
      )

      if dlRc != 0:
        err &"Error: Download failed: {ottoHoleFehlertext(dlRc)}"
        allOk = false
        inc downloadErrors
        continue

      let dataPtr = ottoRueckgabepufferInhalt(ottoBuf)
      let dataSize = ottoRueckgabepufferGroesse(ottoBuf)

      if dataPtr == nil or dataSize == 0:
        err "Error: Downloaded empty data"
        allOk = false
        inc downloadErrors
        continue

      var data = newString(dataSize.int)
      copyMem(addr data[0], dataPtr, dataSize.int)
      writeFile(filepath, data)

    if allOk and anySelected and allSelected:
      confirmedIds.add(b.id)

  if confirmedIds.len > 0:
    let (certRc, certHandle) = ericGetHandleToCertificate(certPath)
    if certRc != 0:
      err &"Error: Failed to open certificate for confirmation: {ericHoleFehlerText(certRc)}"
      err "Documents were downloaded but not confirmed. Run 'viking download' again."
      return 1
    defer: discard ericCloseHandleToCertificate(certHandle)

    var cryptParam: EricVerschluesselungsParameterT
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = certPin.cstring

    let bestXml = generatePostfachBestaetigungXml(
      confirmedIds, name, cfg.test, NimblePkgVersion,
    )
    log bestXml

    var bestTransferHandle: uint32 = 0
    let bestResponseBuf = ericRueckgabepufferErzeugen()
    let bestServerBuf = ericRueckgabepufferErzeugen()
    if bestResponseBuf == nil or bestServerBuf == nil:
      err "Error: Failed to create return buffers for confirmation"
      return 1
    defer:
      discard ericRueckgabepufferFreigabe(bestResponseBuf)
      discard ericRueckgabepufferFreigabe(bestServerBuf)

    let bestRc = ericBearbeiteVorgang(bestXml, "PostfachBestaetigung_31",
      ERIC_VALIDIERE or ERIC_SENDE, nil, addr cryptParam,
      addr bestTransferHandle, bestResponseBuf, bestServerBuf)

    if bestRc != 0:
      let bestResponse = ericRueckgabepufferInhalt(bestResponseBuf)
      let bestServerResponse = ericRueckgabepufferInhalt(bestServerBuf)
      err &"Warning: Confirmation failed: {ericHoleFehlerText(bestRc)}"
      if bestResponse.len > 0: log bestResponse
      if bestServerResponse.len > 0: log bestServerResponse
      err "Documents were downloaded but not confirmed. Confirm within 24h to avoid HerstellerID suspension."
  if downloadErrors > 0:
    err &"Download complete with {downloadErrors} error(s)."
  return 0

proc iban(
  new_iban: string = "",
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Change bank account (IBAN) at the Finanzamt

  log.verbose = verbose
  initLog()
  defer: closeLog()

  if new_iban == "":
    err "Error: --new-iban is required"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForBankverbindung)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let p = vikingConf.personal
  let fullName = p.firstname & " " & p.lastname
  let xml = generateBankverbindungXml(
    steuernummer = p.taxnumber, name = fullName,
    vorname = p.firstname, nachname = p.lastname,
    idnr = p.idnr, geburtsdatum = p.birthdate,
    iban = new_iban, test = cfg.test,
  )

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, "AenderungBankverbindung_20")
  return 0

proc message(
  subject: string = "",
  text: string = "",
  text_file: string = "",
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Send a message (Sonstige Nachricht) to the Finanzamt

  log.verbose = verbose
  initLog()
  defer: closeLog()

  if subject == "":
    err "Error: --subject is required"
    return 1
  if subject.len > 99:
    err "Error: --subject must be at most 99 characters"
    return 1

  var messageText = text
  if text_file != "" and text != "":
    err "Error: --text and --text-file are mutually exclusive"
    return 1
  elif text_file != "":
    if text_file == "-":
      messageText = stdin.readAll().strip
    elif not fileExists(text_file):
      err &"Error: File not found: {text_file}"
      return 1
    else:
      messageText = readFile(text_file).strip

  if messageText == "":
    err "Error: --text or --text-file is required"
    return 1
  if messageText.len > 15000:
    err &"Error: Message text exceeds 15000 characters ({messageText.len})"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForNachricht)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(dataDir, test)
  if not techOk: return 1

  let p = vikingConf.personal
  let fullName = p.firstname & " " & p.lastname
  let xml = generateNachrichtXml(NachrichtInput(
    steuernummer: p.taxnumber, name: fullName,
    strasse: p.street, hausnummer: p.housenumber,
    plz: p.zip, ort: p.city,
    betreff: subject, text: messageText,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  var certPath, certPin: string
  if not dryRun:
    let (authOk, cp, pn) = resolveSigningAuth(vikingConf)
    if not authOk: return 1
    certPath = cp; certPin = pn

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(certPath, certPin, dryRun, outputPdf)

  submitAndCheck(xml, "SonstigeNachrichten_21")
  return 0

const initConfTemplate = """; First section = taxpayer. Section name = "Vornamen Nachname".
; `year` is required — copy this directory per tax year.
[Vorname Nachname]
year         = 2025
geburtsdatum = ""
idnr         = ""
steuernr     = ""
strasse      = ""
nr           = ""
plz          = ""
ort          = ""
iban         = ""
religion     = keine
beruf        = ""
krankenkasse = privat
deductions   = deductions.tsv  ; TSV with vor/sa/agb/per-kid codes for ESt (optional)

; Spouse (optional, for Zusammenveranlagung). Any later person-named
; section with an `idnr` is the co-filing spouse. Section name = full name.
; [Vorname Nachname]
; geburtsdatum = ""
; idnr         = ""
; religion     = keine

; Income sources. Reserved names: freiberuf (Anlage S), gewerbe
; (Einzelgewerbe). Otherwise the section name IS a handle; rechtsform
; is inferred from a legal-form suffix (GmbH, UG, AG, KG, OHG, GbR,
; PartG, eK, eG, KGaA, SE, "GmbH & Co. KG", …). No suffix = Einzelgewerbe.
; Company sections (with a legal-form suffix) are accepted but only
; submit EÜR today — full double-entry bookkeeping is future work.
; Each EÜR source declares its income/cost TSV via `euer=` (EÜR =
; Einnahmen-Überschuss-Rechnung). Optional — sources without `euer=`
; submit zeros with a warning. Copy this conf (and its TSVs) into a
; per-year directory so each year's data stays isolated.

; [freiberuf]
; versteuerung    = ist      ; ist or soll
; vorauszahlungen = 0
; euer            = freiberuf.tsv

; [gewerbe]
; versteuerung    = ist
; vorauszahlungen = 0
; euer            = gewerbe.tsv

; [Musterfirma GmbH]          ; rechtsform inferred: gmbh
; versteuerung    = soll
; vorauszahlungen = 0
; euer            = musterfirma.tsv

; Anlage KAP. Marker: guenstigerpruefung or pauschbetrag. No TSV —
; values are inline.
; [ibkr]
; guenstigerpruefung = 1
; pauschbetrag       = 1000
; gains              = 0
; tax                = 0
; soli               = 0

; Kids. Marker: verhaeltnis (leiblich | pflege | enkel).
; Section name = full name. The firstname's first word (lowercased) is
; the deduction-code prefix, e.g. alice174.
; [Alice Maier]
; geburtsdatum        = ""
; idnr                = ""
; verhaeltnis         = leiblich
; personb-verhaeltnis = leiblich
; personb-name        = ""
; familienkasse       = ""
; kindergeld          = 0

; Signing material. Required for live submissions (not for --dry-run or
; --validate-only). `cert` is the .pfx (required). Set exactly one of:
; * `pin`    — path to a plaintext PIN file, OR the PIN text itself
;              (inline; not recommended if the conf is checked in).
; * `pincmd` — shell command that prints the PIN on stdout (runs with
;              this conf's dir as cwd). Any shell snippet works:
;              `./viking.pin.sh`, `pass show elster/pin`, `cat pin.txt`,
;              `security find-generic-password -s elster -w`, ...
; Relative paths resolve against this conf's dir.
[auth]
; cert   = viking.pfx
; pin    = viking.pin
; pincmd = pass show elster/pin
"""

const initDeductionsTemplate =
  "code\tamount\tdescription\n" &
  "vor300\t0\tRentenversicherung\n" &
  "vor326\t0\tKrankenversicherung gesetzlich\n" &
  "vor329\t0\tPflegeversicherung gesetzlich\n" &
  "vor338\t0\tZusatzbeitrag KV gesetzlich\n" &
  "vor316\t0\tKrankenversicherung privat\n" &
  "vor319\t0\tPflegeversicherung privat\n" &
  "vor328\t0\tZusatzbeitrag KV privat\n" &
  "vor502\t0\tHaftpflicht/Unfallversicherung\n" &
  "sa140\t0\tKirchensteuer gezahlt\n" &
  "sa141\t0\tKirchensteuer erstattet\n" &
  "sa131\t0\tSpenden\n" &
  "agb187\t0\tKrankheitskosten\n"

const initEuerTemplate =
  "amount\trate\tdate\tid\tdescription\n" &
  "0\t19\t2025-01-01\tINV-001\tExample invoice\n" &
  "-0\t19\t2025-01-01\tEXP-001\tExample expense\n"

proc initFiles(
  dir: string = ".",
  global: bool = false,
  force: bool = false,
): int =
  ## Create skeleton viking.conf and deductions.tsv
  ##
  ## With --global, seeds ~/.config/viking/viking.conf.
  ## Otherwise writes viking.conf, deductions.tsv, example.tsv to dir.

  if global:
    let gpath = globalConfPath()
    let gdir = gpath.parentDir
    if not dirExists(gdir):
      createDir(gdir)
    if not force and fileExists(gpath):
      echo &"Skipped: {gpath} (exists, use --force)"
      return 0
    writeFile(gpath, initConfTemplate)
    echo &"Created: {gpath}"
    return 0

  let confPath = dir / "viking.conf"
  let deductionsPath = dir / "deductions.tsv"
  let euerPath = dir / "example.tsv"

  if not dirExists(dir):
    stderr.writeLine &"Error: directory '{dir}' does not exist"
    return 1

  var created: seq[string]
  var skipped: seq[string]

  template writeOrSkip(path: string, content: string) =
    if not force and fileExists(path):
      skipped.add(path)
    else:
      writeFile(path, content)
      created.add(path)

  writeOrSkip(confPath, initConfTemplate)
  writeOrSkip(deductionsPath, initDeductionsTemplate)
  writeOrSkip(euerPath, initEuerTemplate)

  if created.len > 0:
    echo "Created:"
    for f in created:
      echo &"  {f}"
  if skipped.len > 0:
    echo "Skipped (already exist, use --force to overwrite):"
    for f in skipped:
      echo &"  {f}"

  if created.len == 0 and skipped.len > 0:
    echo ""
    echo "All files already exist. Use --force to overwrite."

  return 0

when isMainModule:
  import cligen
  clCfg.version = NimblePkgVersion
  const dryRunHelp = "Validate via ERiC and print XML; don't actually send"
  const dataDirHelp = "Viking data dir (default: ~/.local/share/viking)"
  dispatchMulti(
    [ustva,
      positional = "source",
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "period": "Period: 01-12 (monthly) or 41-44 (quarterly)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "period": 'p',
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [euer,
      positional = "source",
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [est,
      help = {
        "conf": "viking.conf file (optional; default search chain)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "force": "Suppress warnings (e.g. no deductions)",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "force": 'f',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [ust,
      positional = "source",
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [iban,
      help = {
        "new_iban": "New IBAN for the Finanzamt",
        "conf": "Path to viking.conf (optional; default search chain)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "new_iban": 'i',
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [message,
      help = {
        "subject": "Message subject (Betreff, max 99 chars)",
        "text": "Message text (max 15000 chars)",
        "text_file": "Read message text from file (- for stdin)",
        "dry_run": dryRunHelp,
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "data_dir": dataDirHelp,
        "test": "Submit to ELSTER sandbox instead of production",
      },
      short = {
        "subject": 's',
        "text": 't',
        "text_file": 'f',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "data_dir": 'D',
      }
    ],
    [list,
      help = {
        "conf": "viking.conf file (optional; default search chain)",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response XML",
        "data_dir": dataDirHelp,
        "test": "Query ELSTER sandbox instead of production",
      },
      short = {
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "data_dir": 'D',
      }
    ],
    [download,
      help = {
        "files": "Filenames to download (from 'viking list')",
        "conf": "viking.conf file (optional; default search chain)",
        "output_dir": "Output directory for downloaded files (default: current dir)",
        "force": "Overwrite existing files",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response and confirmation XML",
        "data_dir": dataDirHelp,
        "test": "Query ELSTER sandbox instead of production",
      },
      short = {
        "conf": 'c',
        "output_dir": 'o',
        "force": 'f',
        "dry_run": 'd',
        "verbose": 'v',
        "data_dir": 'D',
      }
    ],
    [fetch,
      help = {
        "file": "Path to local ERiC archive (JAR/ZIP/tar.gz)",
        "check": "Check existing ERiC installation in cache",
        "data_dir": dataDirHelp,
      },
      short = {
        "file": 'f',
        "check": 'c',
        "data_dir": 'D',
      }
    ],
    [initFiles, cmdName = "init",
      help = {
        "dir": "Directory to create files in (default: current dir)",
        "global": "Write to ~/.config/viking/viking.conf instead of CWD",
        "force": "Overwrite existing files",
      },
      short = {
        "dir": 'd',
        "global": 'g',
        "force": 'f',
      }
    ]
  )
