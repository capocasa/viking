## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os, tables]
import cligen, cligen/argcvt
import dotenv
import viking/[config, ericffi, ottoffi, ustva_xml, euer_xml, est_xml, ust_xml, ericsetup, invoices, abholung_xml, nachricht_xml, bankverbindung_xml]
import viking/[vikingconf, deductions, kap, log, abholung]

const NimblePkgVersion {.strdefine.} = "dev"

# Custom cligen converters for Option[float]
proc argParse(dst: var Option[float], dfl: Option[float], a: var ArgcvtParams): bool =
  var f: float
  if argParse(f, 0.0, a):
    dst = some(f)
    result = true
  else:
    result = false

proc argHelp(dfl: Option[float], a: var ArgcvtParams): seq[string] =
  @[a.parNm, "float", if dfl.isSome: $dfl.get else: ""]

proc loadConf(conf: string, validate: proc(conf: VikingConf): seq[string]): tuple[ok: bool, conf: VikingConf] =
  var vikingConf: VikingConf
  try:
    vikingConf = loadVikingConf(conf)
  except IOError as e:
    err &"Error: {e.msg}"
    return (false, vikingConf)
  except ValueError as e:
    err &"Error parsing {conf}: {e.msg}"
    return (false, vikingConf)
  let errors = validate(vikingConf)
  if errors.len > 0:
    err "Configuration errors in " & conf & ":"
    for e in errors:
      err &"  - {e}"
    return (false, vikingConf)
  return (true, vikingConf)

proc loadTechConfig(env: string, validateOnly: bool, dryRun: bool): tuple[ok: bool, cfg: Config] =
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    err &"Error: {e.msg}"
    return (false, cfg)
  let errors = if validateOnly and not dryRun: cfg.validateForValidateOnly()
               else: cfg.validate()
  if errors.len > 0:
    err "Configuration errors in .env:"
    for e in errors:
      err &"  - {e}"
    return (false, cfg)
  return (true, cfg)

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
    return 0

template initBuffersAndCert(cfg: Config, validateOnly: bool, outputPdf: string) =
  let responseBuf {.inject.} = ericRueckgabepufferErzeugen()
  let serverBuf {.inject.} = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    err "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)
  var flags {.inject.}: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE
  var druckParam: EricDruckParameterT
  var druckParamPtr {.inject.}: ptr EricDruckParameterT = nil
  if outputPdf != "":
    flags = flags or ERIC_DRUCKE
    druckParam.version = 4
    druckParam.vorschau = if validateOnly: 1 else: 0
    druckParam.ersteSeite = 1
    druckParam.duplexDruck = 0
    druckParam.pdfName = outputPdf.cstring
    druckParam.fussText = nil
    druckParamPtr = addr druckParam
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr {.inject.}: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0
  if not validateOnly:
    block:
      let (ericCertRc {.inject.}, ericCertHandle {.inject.}) = ericGetHandleToCertificate(cfg.certPath)
      if ericCertRc != 0:
        err &"Error: Failed to open certificate: {ericHoleFehlerText(ericCertRc)}"
        return 1
      certHandle = ericCertHandle
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
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
    log "OK"
    if druckParamPtr != nil:
      log &"PDF written to {$druckParamPtr.pdfName}"
    if serverResponse.len > 0: log serverResponse
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

proc submit(
  amount19: Option[float] = none(float),
  amount7: Option[float] = none(float),
  amount0: Option[float] = none(float),
  invoice_file: string = "",
  period: string = "",
  year: int = 0,
  conf: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Submit a German VAT advance return (Umsatzsteuervoranmeldung)
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking submit -c viking.conf --amount19=1000.00 --period=01 --year=2025
  ##   viking submit -c viking.conf --amount19=1000 --amount7=500 --period=41 --year=2025
  ##   viking submit -c viking.conf --amount19=100 --period=01 --validate-only

  let actualYear = if year == 0: now().year else: year
  log.verbose = verbose
  initLog(actualYear)
  defer: closeLog()

  if conf == "":
    err "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForUstva)
  if not confOk: return 1

  if period == "":
    err "Error: --period is required (01-12 for monthly, 41-44 for quarterly)"
    return 1
  if not isValidPeriod(period):
    err &"Error: Invalid period '{period}'. Use 01-12 for monthly or 41-44 for quarterly."
    return 1

  let hasAmounts = amount19.isSome or amount7.isSome or amount0.isSome
  let hasInvoices = invoiceFile != ""
  if hasAmounts and hasInvoices:
    err "Error: --invoice-file and --amount19/--amount7/--amount0 are mutually exclusive"
    return 1
  if not hasAmounts and not hasInvoices:
    err "Error: Specify --amount19/--amount7/--amount0 or --invoice-file"
    return 1

  var finalAmount19 = amount19
  var finalAmount7 = amount7
  var finalAmount0 = amount0

  if hasInvoices:
    let (agg, totalParsed, ok) = loadAndAggregateInvoices(invoiceFile, actualYear, period)
    if not ok:
      return 1
    finalAmount19 = agg.amount19
    finalAmount7 = agg.amount7
    finalAmount0 = agg.amount0
    if finalAmount19.isNone and finalAmount7.isNone and finalAmount0.isNone:
      finalAmount19 = some(0.0)
    log &"Invoices: {invoiceFile}, count={agg.count}"

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let amt19 = finalAmount19.get(0.0)
  let amt7 = finalAmount7.get(0.0)
  let amt0 = finalAmount0.get(0.0)

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let fullStreet = tp.street & " " & tp.housenumber

  let xml = generateUstva(
    steuernummer = tp.taxnumber,
    jahr = actualYear,
    zeitraum = period,
    kz81 = finalAmount19,
    kz86 = finalAmount7,
    kz45 = finalAmount0,
    name = fullName,
    strasse = fullStreet,
    plz = tp.zip,
    ort = tp.city,
    test = cfg.test,
    produktVersion = NimblePkgVersion,
  )

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly, outputPdf)

  let vat19 = amt19 * 0.19
  let vat7 = amt7 * 0.07
  let totalVat = vat19 + vat7
  let modeStr = if cfg.test: " (TEST)" else: ""
  let modeDesc = if validateOnly: "validate" else: "send"
  log &"UStVA {actualYear} period={period} kz81={amt19:.2f} kz86={amt7:.2f} kz83={totalVat:.2f} mode={modeDesc}{modeStr}"

  submitAndCheck(xml, &"UStVA_{actualYear}")
  return 0

proc euer(
  year: int = 0,
  conf: string = "",
  euer: seq[string] = @[],
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Submit an EÜR (Einnahmenüberschussrechnung / profit-loss statement)
  ##
  ## Personal data from viking.conf, invoices from euer.tsv.
  ## Positive invoice amounts = income, negative = expenses.
  ## Multiple --euer flags submit separate EÜR forms for each income source.
  ##
  ## Examples:
  ##   viking euer -y 2025 -c viking.conf --euer euer.tsv
  ##   viking euer -y 2025 -c viking.conf --euer business1.tsv --euer business2.tsv
  ##   viking euer -y 2025 -c viking.conf --euer euer.tsv --dry-run

  let actualYear = if year == 0: now().year else: year
  log.verbose = verbose
  initLog(actualYear)
  defer: closeLog()

  if conf == "":
    err "Error: --conf is required for EÜR submission (viking.conf file)"
    return 1
  if euer.len == 0:
    err "Error: --euer is required for EÜR submission (invoice TSV file)"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForEuer)
  if not confOk: return 1

  var aggregations: seq[tuple[file: string, agg: EuerAggregation]] = @[]
  for euerFile in euer:
    if not fileExists(euerFile):
      err &"Error: EÜR file not found: {euerFile}"
      return 1
    let (agg, ok) = loadAndAggregateForEuer(euerFile)
    if not ok:
      return 1
    aggregations.add((file: euerFile, agg: agg))
    log &"EÜR {euerFile}: income={agg.incomeNet:.2f}+{agg.incomeVat:.2f} expense={agg.expenseNet:.2f}+{agg.expenseVorsteuer:.2f}"

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let fullStreet = tp.street & " " & tp.housenumber

  var xmls: seq[string] = @[]
  for entry in aggregations:
    xmls.add(generateEuer(EuerInput(
      steuernummer: tp.taxnumber, jahr: actualYear,
      incomeNet: entry.agg.incomeNet, incomeVat: entry.agg.incomeVat,
      expenseNet: entry.agg.expenseNet, expenseVorsteuer: entry.agg.expenseVorsteuer,
      rechtsform: tp.rechtsform, einkunftsart: tp.income,
      name: fullName, strasse: fullStreet, plz: tp.zip, ort: tp.city,
      test: cfg.test, produktVersion: NimblePkgVersion,
    )))

  initEric(cfg, false, "")
  if dryRun:
    for i, xml in xmls:
      echo xml
    return 0

  let euerPdf = if xmls.len > 1 and outputPdf != "":
    let (dir, name, ext) = splitFile(outputPdf)
    dir / name & "_1" & ext
  else:
    outputPdf
  initBuffersAndCert(cfg, validateOnly, euerPdf)

  let modeStr = if cfg.test: " (TEST)" else: ""
  let modeDesc = if validateOnly: "validate" else: "send"
  for i, xml in xmls:
    if xmls.len > 1 and outputPdf != "":
      let (dir, name, ext) = splitFile(outputPdf)
      let numbered = dir / name & "_" & $(i+1) & ext
      druckParamPtr.pdfName = numbered.cstring
    let agg = aggregations[i].agg
    let profit = (agg.incomeNet + agg.incomeVat) - (agg.expenseNet + agg.expenseVorsteuer)
    log &"EUER [{i+1}/{xmls.len}] {actualYear} profit={profit:.2f} mode={modeDesc}{modeStr}"

    submitAndCheck(xml, &"EUER_{actualYear}")

  return 0

proc est(
  year: int = 0,
  conf: string = "",
  euer: seq[string] = @[],
  deductions: string = "",
  kapital: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  force: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Submit an ESt (Einkommensteuererklarung / income tax return)
  ##
  ## Personal data from viking.conf, income from euer.tsv,
  ## deductions from deductions.tsv, capital gains from kap.tsv.
  ## Multiple --euer flags for multiple income sources.
  ##
  ## Examples:
  ##   viking est -y 2025 -c viking.conf --euer euer.tsv --deductions deductions.tsv
  ##   viking est -y 2025 -c viking.conf --euer business1.tsv --euer business2.tsv
  ##   viking est -y 2025 -c viking.conf --kapital kap.tsv
  ##   viking est -y 2025 -c viking.conf --euer euer.tsv --dry-run

  let actualYear = if year == 0: now().year else: year
  log.verbose = verbose
  initLog(actualYear)
  defer: closeLog()

  if conf == "":
    err "Error: --conf is required for ESt submission (viking.conf file)"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForEst)
  if not confOk: return 1

  var profits: seq[float] = @[]
  for euerFile in euer:
    if not fileExists(euerFile):
      err &"Error: EÜR file not found: {euerFile}"
      return 1
    let (agg, ok) = loadAndAggregateForEuer(euerFile)
    if not ok:
      return 1
    let profit = (agg.incomeNet + agg.incomeVat) - (agg.expenseNet + agg.expenseVorsteuer)
    profits.add(profit)
    log &"EÜR {euerFile}: profit={profit:.2f}"

  var ded: DeductionsByForm
  if deductions != "":
    if not fileExists(deductions):
      err &"Error: Deductions file not found: {deductions}"
      return 1
    try:
      ded = loadDeductions(deductions, vikingConf.kidFirstnames)
    except ValueError as e:
      err &"Error parsing deductions: {e.msg}"
      return 1
  elif not force:
    err "Warning: no deductions file provided. Use --force to suppress, or pass --deductions <file>"

  var kapTotals: KapTotals
  if kapital != "":
    if not fileExists(kapital):
      err &"Error: KAP file not found: {kapital}"
      return 1
    try:
      kapTotals = loadKapTsv(kapital)
    except ValueError as e:
      err &"Error parsing kap.tsv: {e.msg}"
      return 1

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer

  let estInput = EstInput(
    conf: vikingConf, year: actualYear, profits: profits,
    deductions: ded, kapTotals: kapTotals,
    test: cfg.test, produktVersion: NimblePkgVersion,
  )
  let xml = generateEst(estInput)

  let modeStr = if cfg.test: " (TEST)" else: ""
  let modeDesc = if validateOnly: "validate" else: "send"
  log &"ESt {actualYear} profits={profits.len} mode={modeDesc}{modeStr}"

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly, outputPdf)

  submitAndCheck(xml, &"ESt_{actualYear}")
  return 0

proc ust(
  year: int = 0,
  conf: string = "",
  euer: seq[string] = @[],
  vorauszahlungen: float = 0.0,
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Submit an annual VAT return (Umsatzsteuererklaerung)
  ##
  ## Positive amounts = revenue, negative = expenses (for Vorsteuer).
  ## Provide --vorauszahlungen with the total UStVA advance payments made.
  ## Multiple --euer flags for multiple income sources.
  ##
  ## Examples:
  ##   viking ust -y 2025 -c viking.conf --euer euer.tsv --vorauszahlungen=1200
  ##   viking ust -y 2025 -c viking.conf --euer a.tsv --euer b.tsv
  ##   viking ust -y 2025 -c viking.conf --euer euer.tsv --dry-run

  let actualYear = if year == 0: now().year else: year
  log.verbose = verbose
  initLog(actualYear)
  defer: closeLog()

  if conf == "":
    err "Error: --conf is required for USt submission (viking.conf file)"
    return 1
  if euer.len == 0:
    err "Error: --euer is required for USt submission"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForUst)
  if not confOk: return 1
  let tp = vikingConf.taxpayer

  var agg: UstAggregation
  for euerFile in euer:
    if not fileExists(euerFile):
      err &"Error: EÜR file not found: {euerFile}"
      return 1
    let (fileAgg, ok) = loadAndAggregateForUst(euerFile)
    if not ok: return 1
    agg.income19 += fileAgg.income19
    agg.income7 += fileAgg.income7
    agg.income0 += fileAgg.income0
    agg.vorsteuer += fileAgg.vorsteuer
    agg.incomeCount += fileAgg.incomeCount
    agg.expenseCount += fileAgg.expenseCount
    agg.has19 = agg.has19 or fileAgg.has19
    agg.has7 = agg.has7 or fileAgg.has7
    agg.has0 = agg.has0 or fileAgg.has0

  let totalVat = agg.income19 * 0.19 + agg.income7 * 0.07
  let remaining = totalVat - agg.vorsteuer - vorauszahlungen

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let fullName = tp.firstname & " " & tp.lastname
  let xml = generateUst(UstInput(
    steuernummer: tp.taxnumber, jahr: actualYear,
    income19: agg.income19, income7: agg.income7, income0: agg.income0,
    has19: agg.has19, has7: agg.has7, has0: agg.has0,
    vorsteuer: agg.vorsteuer, vorauszahlungen: vorauszahlungen,
    besteuerungsart: tp.besteuerungsart,
    name: fullName, strasse: tp.street & " " & tp.housenumber,
    plz: tp.zip, ort: tp.city,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  let modeStr = if cfg.test: " (TEST)" else: ""
  let modeDesc = if validateOnly: "validate" else: "send"
  log &"USt {actualYear} vat={totalVat:.2f} vorsteuer={agg.vorsteuer:.2f} remaining={remaining:.2f} mode={modeDesc}{modeStr}"

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly, outputPdf)

  submitAndCheck(xml, &"USt_{actualYear}")
  return 0

proc fetch(file: string = "", check: bool = false, env: string = ".env"): int =
  ## Fetch ERiC library and test certificates
  ##
  ## Downloads ERiC from the ELSTER developer portal and sets up test
  ## certificates automatically. Use --file to install from a local archive.
  ##
  ## Cache location: ~/.cache/viking/ (or XDG_CACHE_HOME)
  ##
  ## Examples:
  ##   viking fetch                      # Auto-download ERiC + test certs
  ##   viking fetch --file=ERiC.jar      # Install from local archive
  ##   viking fetch --check              # Check existing installation

  # Load env file so VIKING_DATA_DIR is available
  let envPath = if env.isAbsolute: env else: getCurrentDir() / env
  if fileExists(envPath):
    load(envPath.parentDir, envPath.extractFilename)

  initLog()
  defer: closeLog()

  if check:
    # --check is a query: stdout for data, stderr for errors
    let existing = findExistingEric()
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
      printDownloadInstructions()
      return 1

  # Download test certificates
  let (certPath, certPin, certSuccess) = downloadTestCertificates()

  # Get ERiC installation
  var installation: EricInstallation
  if file != "":
    installation = setupEric(file)
  else:
    installation = findExistingEric()
    if installation.valid:
      log "Using existing ERiC installation."
    else:
      let (inst, success) = fetchEric()
      if success:
        installation = inst
      else:
        return 1

  if installation.valid:
    if certSuccess:
      updateEnvFile(installation, certPath, certPin)
    else:
      updateEnvFile(installation)
    return 0
  else:
    stderr.writeLine "ERiC setup incomplete. Use 'viking fetch --file=<path>' with a local archive."
    return 1

proc loadConfigAndEricForAbholung(conf: string, env: string): tuple[rc: int, cfg: Config, name: string] =
  ## Load config for Datenabholung commands. Personal data from viking.conf, technical from .env.
  if conf == "":
    err "Error: --conf is required"
    var cfg: Config
    return (1, cfg, "")

  let (confOk, vikingConf) = loadConf(conf, validateForAbholung)
  if not confOk:
    var cfg: Config
    return (1, cfg, "")

  let (techOk, cfg) = loadTechConfig(env, false, false)
  if not techOk: return (1, cfg, "")

  let name = vikingConf.taxpayer.firstname & " " & vikingConf.taxpayer.lastname

  if not loadEricLib(cfg.ericLibPath):
    err &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return (1, cfg, "")

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    err &"Error: ERiC initialization failed: {ericHoleFehlerText(initRc)}"
    unloadEricLib()
    return (1, cfg, "")

  return (0, cfg, name)

proc list(
  conf: string = "",
  verbose: bool = false,
  dry_run: bool = false,
  env: string = ".env",
): int =
  ## List available documents in the tax office Postfach
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking list -c viking.conf
  ##   viking list -c viking.conf --verbose

  log.verbose = verbose
  initLog()
  defer: closeLog()

  let (cfgRc, cfg, name) = loadConfigAndEricForAbholung(conf, env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, name, NimblePkgVersion, verbose)
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
  env: string = ".env",
): int =
  ## Download documents from the tax office Postfach
  ##
  ## Personal data from viking.conf, technical config from .env.
  ## Queries the ELSTER Postfach, downloads documents via OTTER,
  ## and confirms retrieval. Use 'viking list' first to see what's available.
  ## Specify filenames to download specific files.
  ##
  ## Examples:
  ##   viking download -c viking.conf
  ##   viking download -c viking.conf Steuerbescheid_Einkommsteuer_2024.pdf
  ##   viking download -c viking.conf --output_dir=./bescheide

  log.verbose = verbose
  initLog()
  defer: closeLog()

  let (cfgRc, cfg, name) = loadConfigAndEricForAbholung(conf, env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    echo generatePostfachAnfrageXml(name, cfg.test, NimblePkgVersion)
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, name, NimblePkgVersion, verbose)
  if rc != 0: return rc

  if bereitstellungen.len == 0:
    return 0

  let outDir = if output_dir.len > 0: output_dir else: "."
  if outDir != ".":
    createDir(outDir)

  let ottoLibPath = cfg.ericLibPath.parentDir / "libotto.so"
  if not loadOttoLib(ottoLibPath):
    err &"Error: Failed to load Otto library from {ottoLibPath}"
    return 1
  defer: unloadOttoLib()

  let (ottoRc, ottoInstanz) = ottoInstanzErzeugen(cfg.ericLogPath)
  if ottoRc != 0:
    err &"Error: Failed to create Otto instance: {ottoHoleFehlertext(ottoRc)}"
    return 1
  defer: discard ottoInstanzFreigeben(ottoInstanz)

  log "Downloading from OTTER..."

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

      log &"Downloading {filename}..."

      let (bufRc, ottoBuf) = ottoRueckgabepufferErzeugen(ottoInstanz)
      if bufRc != 0:
        err &"Error: Failed to create download buffer (code {bufRc})"
        allOk = false
        inc downloadErrors
        continue
      defer: discard ottoRueckgabepufferFreigeben(ottoBuf)

      let dlRc = ottoDatenAbholen(
        ottoInstanz, a.dateiReferenzId, a.dateiGroesse.uint32,
        cfg.certPath, cfg.certPin, HerstellerId, ottoBuf,
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
      log &"Saved: {filepath} ({dataSize} bytes)"

    if allOk and anySelected and allSelected:
      confirmedIds.add(b.id)

  if confirmedIds.len > 0:
    log "Confirming retrieval..."

    let (certRc, certHandle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      err &"Error: Failed to open certificate for confirmation: {ericHoleFehlerText(certRc)}"
      err "Documents were downloaded but not confirmed. Run 'viking download' again."
      return 1
    defer: discard ericCloseHandleToCertificate(certHandle)

    var cryptParam: EricVerschluesselungsParameterT
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring

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
    else:
      log &"Confirmed {confirmedIds.len} document(s)"

  if downloadErrors > 0:
    err &"Download complete with {downloadErrors} error(s)."
  else:
    log "Download complete."
  return 0

proc iban(
  new_iban: string = "",
  conf: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Change bank account (IBAN) at the Finanzamt
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking iban -c viking.conf --new-iban DE89370400440532013000
  ##   viking iban -c viking.conf --new-iban DE89370400440532013000 --dry-run

  log.verbose = verbose
  initLog()
  defer: closeLog()

  if new_iban == "":
    err "Error: --new-iban is required"
    return 1
  if conf == "":
    err "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForBankverbindung)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let xml = generateBankverbindungXml(
    steuernummer = tp.taxnumber, name = fullName,
    vorname = tp.firstname, nachname = tp.lastname,
    idnr = tp.idnr, geburtsdatum = tp.birthdate,
    iban = new_iban, test = cfg.test,
  )

  let modeDesc = if validateOnly: "validate" else: "send"
  let modeStr = if cfg.test: " (TEST)" else: ""
  log &"IBAN change new_iban={new_iban} mode={modeDesc}{modeStr}"

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly, outputPdf)

  submitAndCheck(xml, "AenderungBankverbindung_20")
  return 0

proc message(
  subject: string = "",
  text: string = "",
  text_file: string = "",
  conf: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  output_pdf: string = "",
  env: string = ".env",
): int =
  ## Send a message (Sonstige Nachricht) to the Finanzamt
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking message -c viking.conf --subject "Rückfrage" --text "Sehr geehrte Damen und Herren, ..."
  ##   viking message -c viking.conf --subject "Rückfrage" --text-file brief.txt

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

  if conf == "":
    err "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForNachricht)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let xml = generateNachrichtXml(NachrichtInput(
    steuernummer: tp.taxnumber, name: fullName,
    strasse: tp.street, hausnummer: tp.housenumber,
    plz: tp.zip, ort: tp.city,
    betreff: subject, text: messageText,
    test: cfg.test, produktVersion: NimblePkgVersion,
  ))

  let modeDesc = if validateOnly: "validate" else: "send"
  let modeStr = if cfg.test: " (TEST)" else: ""
  log &"Message subject=\"{subject}\" len={messageText.len} mode={modeDesc}{modeStr}"

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly, outputPdf)

  submitAndCheck(xml, "SonstigeNachrichten_21")
  return 0

const initConfTemplate = """[taxpayer]
firstname = ""
lastname = ""
birthdate = ""
idnr = ""
taxnumber = ""
income = 3
street = ""
housenumber = ""
zip = ""
city = ""
iban = ""
religion = 11
profession = ""
kv_art = privat
rechtsform = 120
besteuerungsart = 2

[kap]
guenstigerpruefung = 0
sparer_pauschbetrag = 1000

# Add one [kid] section per child (optional)
# [kid]
# firstname = ""
# birthdate = ""
# idnr = ""
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

const initKapTemplate =
  "gains\ttax\tsoli\tkirchensteuer\tdescription\n" &
  "0\t0\t0\t\tBroker Name\n"

const initEuerTemplate =
  "amount\trate\tdate\tid\tdescription\n" &
  "0\t19\t2025-01-01\tINV-001\tExample invoice\n" &
  "-0\t19\t2025-01-01\tEXP-001\tExample expense\n"

proc initFiles(
  dir: string = ".",
  force: bool = false,
): int =
  ## Create skeleton viking.conf, deductions.tsv, kap.tsv, and euer.tsv
  ##
  ## Generates template files with all known fields and codes set to
  ## placeholder values. Edit the generated files with your data.
  ##
  ## Examples:
  ##   viking init
  ##   viking init --dir myproject
  ##   viking init --force          # overwrite existing files

  let confPath = dir / "viking.conf"
  let deductionsPath = dir / "deductions.tsv"
  let kapPath = dir / "kap.tsv"
  let euerPath = dir / "euer.tsv"

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
  writeOrSkip(kapPath, initKapTemplate)
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
  dispatchMulti(
    [submit,
      help = {
        "amount19": "Net amount at 19% VAT rate (Kz81)",
        "amount7": "Net amount at 7% VAT rate (Kz86)",
        "amount0": "Non-taxable amount at 0% (Kz45)",
        "invoice_file": "CSV/TSV invoice file (- for stdin)",
        "period": "Period: 01-12 (monthly) or 41-44 (quarterly)",
        "year": "Tax year (default: current year)",
        "conf": "viking.conf file with taxpayer data",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "amount19": '1',
        "amount7": '7',
        "amount0": '0',
        "invoice_file": 'i',
        "period": 'p',
        "year": 'y',
        "conf": 'c',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [euer,
      help = {
        "year": "Tax year (default: current year)",
        "conf": "viking.conf file with taxpayer data",
        "euer": "TSV invoice file (repeatable for multiple income sources)",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "year": 'y',
        "conf": 'c',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [est,
      help = {
        "year": "Tax year (default: current year)",
        "conf": "viking.conf file (taxpayer data)",
        "euer": "EUeR income/expense TSV (repeatable, optional)",
        "deductions": "Deductions TSV with compound codes (optional)",
        "kapital": "Capital gains TSV (optional)",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "force": "Suppress warnings (e.g. no deductions)",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "year": 'y',
        "conf": 'c',
        "euer": 'i',
        "deductions": 'D',
        "kapital": 'K',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "force": 'f',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [ust,
      help = {
        "year": "Tax year (default: current year)",
        "conf": "viking.conf file (taxpayer data)",
        "euer": "EUeR income/expense TSV (repeatable, required)",
        "vorauszahlungen": "Total UStVA advance payments made during the year",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "year": 'y',
        "conf": 'c',
        "euer": 'i',
        "vorauszahlungen": 'a',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [iban,
      help = {
        "new_iban": "New IBAN for the Finanzamt",
        "conf": "Path to viking.conf (taxpayer data)",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "new_iban": 'i',
        "conf": 'c',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [message,
      help = {
        "subject": "Message subject (Betreff, max 99 chars)",
        "text": "Message text (max 15000 chars)",
        "text_file": "Read message text from file (- for stdin)",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "output_pdf": "Write PDF of submitted forms to file",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "subject": 's',
        "text": 't',
        "text_file": 'f',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "output_pdf": 'o',
        "env": 'e',
      }
    ],
    [list,
      help = {
        "conf": "viking.conf file with taxpayer data",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "conf": 'c',
        "dry_run": 'd',
        "verbose": 'v',
        "env": 'e',
      }
    ],
    [download,
      help = {
        "files": "Filenames to download (from 'viking list')",
        "conf": "viking.conf file with taxpayer data",
        "output_dir": "Output directory for downloaded files (default: current dir)",
        "force": "Overwrite existing files",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response and confirmation XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "conf": 'c',
        "output_dir": 'o',
        "force": 'f',
        "dry_run": 'd',
        "verbose": 'v',
        "env": 'e',
      }
    ],
    [fetch,
      help = {
        "file": "Path to local ERiC archive (JAR/ZIP/tar.gz)",
        "check": "Check existing ERiC installation in cache",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "file": 'f',
        "check": 'c',
        "env": 'e',
      }
    ],
    [initFiles, cmdName = "init",
      help = {
        "dir": "Directory to create files in (default: current dir)",
        "force": "Overwrite existing files",
      },
      short = {
        "dir": 'd',
        "force": 'f',
      }
    ]
  )
