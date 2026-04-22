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
## * `init`     — seed `viking.conf` and `abzuege.tsv` skeletons
##
## Configuration lives in `viking.conf`; signing in `[auth]`. See
## `vikingconf <vikingconf.html>`_ for the data model and `docs.rst`
## for the user guide.

import std/[strutils, strformat, options, os, sequtils, tables]
import cligen
import viking/[config, ericffi, ottoffi, ustva_xml, euer_xml, est_xml, ust_xml, ericsetup, invoices, abholung_xml, nachricht_xml, bankverbindung_xml]
import viking/[vikingconf, deductions, kap, log, abholung, codes, ericerror]

const NimblePkgVersion {.strdefine.} = "dev"

const
  ExitOk = 0
  ExitUsage = 2     ## bad or missing CLI arguments
  ExitConfig = 3    ## viking.conf / TSV load or validation failed
  ExitNotFound = 4  ## a file referenced from the conf/CLI doesn't exist
  ExitApi = 5       ## ERiC / Otto call failed (load, init, submit, …)

type ConfigError = object of CatchableError
  ## Raised by the config-loading helpers below. Caught once per command;
  ## `msg` is the ready-to-print user-facing text.

proc loadConf(conf: string, validate: proc(conf: VikingConf): seq[string]): VikingConf =
  try:
    result = loadVikingConf(conf)
  except IOError as e:
    raise newException(ConfigError, "Error: " & e.msg)
  except ValueError as e:
    raise newException(ConfigError, "Error parsing viking.conf: " & e.msg)
  let errors = validate(result)
  if errors.len > 0:
    raise newException(ConfigError, "Configuration errors:\n  - " & errors.join("\n  - "))

proc loadConfForSource(conf: string, srcName: string,
                       kinds: set[SourceKind],
                       validate: proc(conf: VikingConf, src: Source): seq[string]):
                       tuple[conf: VikingConf, src: Source] =
  var vc: VikingConf
  try:
    vc = loadVikingConf(conf)
  except IOError as e:
    raise newException(ConfigError, "Error: " & e.msg)
  except ValueError as e:
    raise newException(ConfigError, "Error parsing viking.conf: " & e.msg)

  let candidates = vc.sourcesOfKind(kinds)
  if candidates.len == 0:
    raise newException(ConfigError, "Error: no matching source defined in viking.conf")

  let chosenName =
    if srcName != "":
      srcName
    elif candidates.len == 1:
      candidates[0].name
    else:
      raise newException(ConfigError,
        "Error: multiple sources defined, specify one: " &
        candidates.mapIt(it.name).join(", "))

  let chosen = vc.findSource(chosenName)
  if chosen < 0:
    raise newException(ConfigError, &"Error: source '{chosenName}' not found in viking.conf")
  if vc.sources[chosen].kind notin kinds:
    raise newException(ConfigError, &"Error: source '{chosenName}' is not a matching kind for this command")

  let errors = validate(vc, vc.sources[chosen])
  if errors.len > 0:
    raise newException(ConfigError, "Configuration errors:\n  - " & errors.join("\n  - "))
  (vc, vc.sources[chosen])

proc loadTechConfig(dataDir: string, test: bool): Config =
  ## Derive ERiC paths from the data dir and carry the --test flag.
  result = loadConfig(dataDir, test)
  let errors = result.validate()
  if errors.len > 0:
    raise newException(ConfigError, "Configuration error:\n  - " & errors.join("\n  - "))

proc resolveSigningAuth(vc: VikingConf): tuple[certPath, certPin: string] =
  ## Resolve cert path + pin for actual signing.
  try:
    let certPath = vc.resolveCertPath()
    if not fileExists(certPath):
      raise newException(ConfigError,
        &"Error: cert not found: {certPath} (check [auth].cert in viking.conf)")
    (certPath, vc.resolvePin())
  except ConfigError: raise
  except CatchableError as e:
    raise newException(ConfigError, "Error: " & e.msg)

func stripFeldXPath(s: string): string =
  ## ELSTER error texts often start with "Feld '$/Elster[1]/.../x[1]$': ".
  ## The XPath is also in <Feldidentifikator>; strip it from the human text.
  const prefix = "Feld '$"
  const sep = "$': "
  if s.startsWith(prefix):
    let i = s.find(sep, prefix.len)
    if i >= 0:
      return s[i + sep.len .. ^1]
  s

proc handleEricError(rc: int, response, serverResponse: string, ericLogPath: string) =
  let parsed = parseFehlerRegelpruefung(response) & parseServerRueckgabeErrors(serverResponse)
  if parsed.len > 0:
    for e in parsed:
      let text = stripFeldXPath(e.text)
      if e.code.len > 0:
        err &"{text}\n\n[{e.code}, {rc}]"
      else:
        err &"{text}\n\n[{rc}]"
  else:
    err &"{ericHoleFehlerText(rc)}\n\n[{rc}]"
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

template initEric(cfg: Config, xml: string) =
  if not loadEricLib(cfg.ericLibPath):
    err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return ExitApi
  defer: unloadEricLib()
  createDir(cfg.ericLogPath)
  block:
    let ericInitRc {.inject.} = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
    if ericInitRc != 0:
      err &"Error: ERiC initialization failed with code {ericInitRc}: {ericHoleFehlerText(ericInitRc)}"
      return ExitApi
  defer: discard ericBeende()
  log xml

template initBuffersAndCert(certPath, certPin: string, dryRun: bool, outputPdf: string) =
  let responseBuf {.inject.} = ericRueckgabepufferErzeugen()
  let serverBuf {.inject.} = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    err "Error: Failed to create return buffers"
    return ExitApi
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
    druckParam.duplexDruck = 0
    druckParam.pdfName = outputPdf.cstring
    druckParam.fussText = nil
    druckParam.pdfCallback = nil
    druckParam.pdfCallbackBenutzerdaten = nil
    druckParamPtr = addr druckParam
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr {.inject.}: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0
  if not dryRun:
    block:
      let (ericCertRc {.inject.}, ericCertHandle {.inject.}) = ericGetHandleToCertificate(certPath)
      if ericCertRc != 0:
        err &"Error: Failed to open certificate: {ericHoleFehlerText(ericCertRc)}"
        return ExitApi
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
    return ExitApi

proc ustva(
  source: string = "",
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
  ## --source selects the income source from viking.conf; omit if
  ## exactly one EÜR source is defined. Amounts come from the source's
  ## `euer=` TSV; tax year comes from `personal.year`.

  if period == "":
    err "Error: --period is required; " & periodMap.listing
    return ExitUsage
  let normalizedPeriod =
    try: periodMap.resolve(period)
    except ValueError:
      err &"Error: Invalid period '{period}'; " & periodMap.listing
      return ExitUsage

  try:
    let (vikingConf, src) = loadConfForSource(conf, source,
      {skGewerbe, skFreelance}, validateForUstva)

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
      return ExitNotFound
    else:
      let (agg, ok) = loadAndAggregateInvoices(tsvPath, year, normalizedPeriod)
      if not ok: return ExitConfig
      amount19 = agg.amount19
      amount7 = agg.amount7
      amount0 = agg.amount0
      if amount19.isNone and amount7.isNone and amount0.isNone:
        amount19 = some(0.0)

    let cfg = loadTechConfig(dataDir, test)

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
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, &"UStVA_{year}")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

proc euer(
  source: string = "",
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit an EÜR for a source.
  ##
  ## --source selects the income source from viking.conf; omit if
  ## exactly one EÜR source is defined. Loads the source's `euer=` TSV.
  ## Positive = income, negative = expenses. Tax year from `personal.year`.

  try:
    let (vikingConf, src) = loadConfForSource(conf, source,
      {skGewerbe, skFreelance}, validateForEuer)

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
      return ExitNotFound
    else:
      let (a, ok) = loadAndAggregateForEuer(tsvPath)
      if not ok: return ExitConfig
      agg = a

    let cfg = loadTechConfig(dataDir, test)

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
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, &"EUER_{year}")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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

  try:
    let vikingConf = loadConf(conf, validateForEst)

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
        return ExitNotFound
      else:
        let (agg, ok) = loadAndAggregateForEuer(tsvPath)
        if not ok: return ExitConfig
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
        return ExitNotFound
      try:
        ded = loadDeductions(dedPath, vikingConf.kidFirstnames)
      except ValueError as e:
        err &"Error parsing abzuege: {e.msg}"
        return ExitConfig
    elif not force:
      err "Warning: no abzuege set. Either add `abzuege = …` to the taxpayer section of viking.conf, or use --force to suppress."

    let cfg = loadTechConfig(dataDir, test)

    let xml = generateEst(EstInput(
      conf: vikingConf, year: year,
      gewerbeProfits: gewerbeProfits, freelanceProfits: freelanceProfits,
      kapTotals: kapTotals, deductions: ded,
      test: cfg.test, produktVersion: NimblePkgVersion,
    ))

    var certPath, certPin: string
    if not dryRun:
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, &"ESt_{year}")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

proc ust(
  source: string = "",
  conf: string = "",
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  data_dir: string = "",
  test: bool = false,
): int =
  ## Submit an annual VAT return (Umsatzsteuererklaerung) for a source.
  ##
  ## --source selects the income source from viking.conf; omit if
  ## exactly one EÜR source is defined. Loads the source's `euer=` TSV.
  ## Vorauszahlungen from source section. Tax year from `personal.year`.

  try:
    let (vikingConf, src) = loadConfForSource(conf, source,
      {skGewerbe, skFreelance}, validateForUst)

    let year = vikingConf.personal.year
    log.verbose = verbose
    initLog(year)
    defer: closeLog()

    let tsvPath = resolveEuerPath(vikingConf, src)
    var agg: UstAggregation
    if tsvPath == "":
      err &"Warning: source [{src.name}] has no euer= set; filing Nullmeldung"
      agg.has19 = true
    elif not fileExists(tsvPath):
      err &"Error: invoice TSV not found: {tsvPath}"
      return ExitNotFound
    else:
      let (a, ok) = loadAndAggregateForUst(tsvPath)
      if not ok: return ExitConfig
      agg = a
      if not (agg.has19 or agg.has7 or agg.has0) and agg.vorsteuer == 0:
        agg.has19 = true

    let cfg = loadTechConfig(dataDir, test)

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
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, &"USt_{year}")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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
      for (label, tag) in {"UStVA": "UStVA", "EUER ": "EUER",
                           "ESt  ": "ESt", "USt  ": "USt"}:
        let years = listPluginYears(existing, tag)
        if years.len > 0:
          echo &"  {label} years: {years.join(\", \")}"
      return ExitOk
    else:
      stderr.writeLine "No ERiC installation found."
      printDownloadInstructions(effectiveDataDir)
      return ExitNotFound

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
        return ExitApi

  if installation.valid:
    echo &"ERiC installed at {installation.path}"
    stderr.writeLine ""
    stderr.writeLine "For sandbox testing, grab ELSTER's test certs:"
    stderr.writeLine "  wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip"
    stderr.writeLine "  unzip Test_Zertifikate.zip   # PIN for all certs: 123456"
    return ExitOk
  else:
    stderr.writeLine "ERiC setup incomplete. Use 'viking fetch --file=<path>' with a local archive."
    return ExitApi

proc loadAbholungConf(conf, dataDir: string, test: bool):
    tuple[cfg: Config, vc: VikingConf, name: string] =
  ## Load viking.conf + tech config for Postfach commands. Raises ConfigError.
  let vc = loadConf(conf, validateForAbholung)
  let cfg = loadTechConfig(dataDir, test)
  (cfg, vc, vc.personal.firstname & " " & vc.personal.lastname)

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

  try:
    let (cfg, vc, name) = loadAbholungConf(conf, dataDir, test)

    if not loadEricLib(cfg.ericLibPath):
      err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
      return ExitApi
    defer: unloadEricLib()
    createDir(cfg.ericLogPath)

    let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
    if initRc != 0:
      err &"Error: ERiC initialization failed: {ericHoleFehlerText(initRc)}"
      return ExitApi
    defer: discard ericBeende()

    if dry_run:
      echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
      return ExitOk

    let (certPath, certPin) = resolveSigningAuth(vc)

    let (rc, bereitstellungen, _) = initEricAndQueryPostfach(
      cfg, certPath, certPin, name, NimblePkgVersion, verbose)
    if rc != 0: return ExitApi

    displayBereitstellungen(bereitstellungen)
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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

  try:
    let (cfg, vc, name) = loadAbholungConf(conf, dataDir, test)

    if not loadEricLib(cfg.ericLibPath):
      err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
      return ExitApi
    defer: unloadEricLib()
    createDir(cfg.ericLogPath)

    let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
    if initRc != 0:
      err &"Error: ERiC initialization failed: {ericHoleFehlerText(initRc)}"
      return ExitApi
    defer: discard ericBeende()

    if dry_run:
      echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
      return ExitOk

    let (certPath, certPin) = resolveSigningAuth(vc)

    let (rc, bereitstellungen, _) = initEricAndQueryPostfach(
      cfg, certPath, certPin, name, NimblePkgVersion, verbose)
    if rc != 0: return ExitApi

    if bereitstellungen.len == 0:
      return ExitOk

    let outDir = if output_dir.len > 0: output_dir else: "."
    if outDir != ".":
      createDir(outDir)

    let ottoLibName = when defined(macosx): "libotto.dylib"
                      elif defined(windows): "otto.dll"
                      else: "libotto.so"
    let ottoLibPath = cfg.ericLibPath.parentDir / ottoLibName
    if not loadOttoLib(ottoLibPath):
      err &"Error: Failed to load Otto library from {ottoLibPath}"
      return ExitApi
    defer: unloadOttoLib()

    let (ottoRc, ottoInstanz) = ottoInstanzErzeugen(cfg.ericLogPath)
    if ottoRc != 0:
      err &"Error: Failed to create Otto instance: {ottoHoleFehlertext(ottoRc)}"
      return ExitApi
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
        return ExitApi
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
        return ExitApi
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
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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
    return ExitUsage

  try:
    let vikingConf = loadConf(conf, validateForBankverbindung)
    let cfg = loadTechConfig(dataDir, test)

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
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, "AenderungBankverbindung_20")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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
    return ExitUsage
  if subject.len > 99:
    err "Error: --subject must be at most 99 characters"
    return ExitUsage

  var messageText = text
  if text_file != "" and text != "":
    err "Error: --text and --text-file are mutually exclusive"
    return ExitUsage
  elif text_file != "":
    if text_file == "-":
      messageText = stdin.readAll().strip
    elif not fileExists(text_file):
      err &"Error: File not found: {text_file}"
      return ExitNotFound
    else:
      messageText = readFile(text_file).strip

  if messageText == "":
    err "Error: --text or --text-file is required"
    return ExitUsage
  if messageText.len > 15000:
    err &"Error: Message text exceeds 15000 characters ({messageText.len})"
    return ExitUsage

  try:
    let vikingConf = loadConf(conf, validateForNachricht)
    let cfg = loadTechConfig(dataDir, test)

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
      (certPath, certPin) = resolveSigningAuth(vikingConf)

    initEric(cfg, xml)
    initBuffersAndCert(certPath, certPin, dryRun, outputPdf)
    submitAndCheck(xml, "SonstigeNachrichten_21")
    ExitOk
  except ConfigError as e:
    err e.msg
    ExitConfig

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
abzuege      = abzuege.tsv     ; TSV with vor/sa/agb/per-kid codes for ESt (optional)

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
; the abzuege-code prefix, e.g. alice174.
; [Alice Maier]
; geburtsdatum        = ""
; idnr                = ""
; verhaeltnis         = leiblich
; personb-verhaeltnis = leiblich
; personb-name        = ""
; familienkasse       = ""
; kindergeld          = 0

; Signing material. Required for live submissions (not for --dry-run).
; `cert` is the .pfx (required). Set exactly one of:
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
  ## Create skeleton viking.conf and abzuege.tsv
  ##
  ## With --global, seeds ~/.config/viking/viking.conf.
  ## Otherwise writes viking.conf, abzuege.tsv, example.tsv to dir.

  if global:
    let gpath = globalConfPath()
    let gdir = gpath.parentDir
    if not dirExists(gdir):
      createDir(gdir)
    if not force and fileExists(gpath):
      echo &"Skipped: {gpath} (exists, use --force)"
      return ExitOk
    writeFile(gpath, initConfTemplate)
    echo &"Created: {gpath}"
    return ExitOk

  let confPath = dir / "viking.conf"
  let deductionsPath = dir / "abzuege.tsv"
  let euerPath = dir / "example.tsv"

  if not dirExists(dir):
    stderr.writeLine &"Error: directory '{dir}' does not exist"
    return ExitUsage

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

  return ExitOk

when isMainModule:
  clCfg.version = NimblePkgVersion
  const dataDirHelp = "Viking data dir (default: ~/.local/share/viking)"
  dispatchMulti(
    [ustva,
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "period": "Period: 01-12 (monthly) or 41-44 (quarterly)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "source": 's',
        "period": 'p',
        "conf": 'c',
        "verbose": 'v',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [euer,
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "source": 's',
        "conf": 'c',
        "verbose": 'v',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [est,
      help = {
        "conf": "viking.conf file (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "force": "Suppress warnings (e.g. no abzuege)",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "conf": 'c',
        "verbose": 'v',
        "force": 'f',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [ust,
      help = {
        "source": "Source name from viking.conf (optional if only one)",
        "conf": "viking.conf file (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "source": 's',
        "conf": 'c',
        "verbose": 'v',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [iban,
      help = {
        "new-iban": "New IBAN for the Finanzamt",
        "conf": "Path to viking.conf (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "new-iban": 'i',
        "conf": 'c',
        "verbose": 'v',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [message,
      help = {
        "subject": "Message subject (Betreff, max 99 chars)",
        "text": "Message text (max 15000 chars)",
        "text-file": "Read message text from file (- for stdin)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "output-pdf": "Write PDF of submitted forms to file",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "subject": 's',
        "text": 't',
        "text-file": 'f',
        "verbose": 'v',
        "output-pdf": 'o',
        "data-dir": 'D',
      }
    ],
    [list,
      help = {
        "conf": "viking.conf file (optional; default search chain)",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response XML",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "conf": 'c',
        "verbose": 'v',
        "data-dir": 'D',
      }
    ],
    [download,
      help = {
        "files": "Filenames to download (from 'viking list')",
        "conf": "viking.conf file (optional; default search chain)",
        "output-dir": "Output directory for downloaded files (default: current dir)",
        "force": "Overwrite existing files",
        "dry-run": "Validate via ERiC; don't actually send",
        "verbose": "Show full server response and confirmation XML",
        "data-dir": dataDirHelp,
        "test": " ",
      },
      short = {
        "dry-run": '\0',
        "conf": 'c',
        "output-dir": 'o',
        "force": 'f',
        "verbose": 'v',
        "data-dir": 'D',
      }
    ],
    [fetch,
      help = {
        "file": "Path to local ERiC archive (JAR/ZIP/tar.gz)",
        "check": "Check existing ERiC installation in cache",
        "data-dir": dataDirHelp,
      },
      short = {
        "file": 'f',
        "check": 'c',
        "data-dir": 'D',
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
