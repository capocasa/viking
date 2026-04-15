## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os, tables, xmltree, xmlparser, sequtils]
import cligen, cligen/argcvt
import dotenv
import viking/[config, eric_ffi, otto_ffi, ustva_xml, euer_xml, est_xml, ust_xml, eric_setup, invoices, abholung_xml, nachricht_xml, bankverbindung_xml]
import viking/[viking_conf, deductions, kap]

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
  ## Load viking.conf and validate with the given validator. Prints errors on failure.
  var vikingConf: VikingConf
  try:
    vikingConf = loadVikingConf(conf)
  except IOError as e:
    echo &"Error: {e.msg}"
    return (false, vikingConf)
  except ValueError as e:
    echo &"Error parsing {conf}: {e.msg}"
    return (false, vikingConf)
  let errors = validate(vikingConf)
  if errors.len > 0:
    echo "Configuration errors in " & conf & ":"
    for e in errors:
      echo &"  - {e}"
    return (false, vikingConf)
  return (true, vikingConf)

proc loadTechConfig(env: string, validateOnly: bool, dryRun: bool): tuple[ok: bool, cfg: Config] =
  ## Load .env tech config and validate. Prints errors on failure.
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return (false, cfg)
  let errors = if validateOnly and not dryRun: cfg.validateForValidateOnly()
               else: cfg.validate()
  if errors.len > 0:
    echo "Configuration errors in .env:"
    for e in errors:
      echo &"  - {e}"
    return (false, cfg)
  return (true, cfg)

proc handleEricError(rc: int, response, serverResponse: string, ericLogPath: string) =
  ## Print error details for a failed ERiC operation.
  echo &"Error: Operation failed with code {rc}"
  echo &"  {ericHoleFehlerText(rc)}"
  case rc
  of 610301202:
    echo ""
    echo "Hint: The HerstellerID is blocked."
    echo "  Register at https://www.elster.de/elsterweb/entwickler"
  of 610301200:
    echo ""
    echo "Hint: XML schema validation failed."
    let logFile = ericLogPath / "eric.log"
    if fileExists(logFile):
      let logContent = readFile(logFile).strip
      if logContent.len > 0:
        echo ""
        echo "ERiC log:"
        echo logContent
  of 610001050:
    echo ""
    echo "Hint: Buffer instance mismatch - this is likely a bug in the FFI bindings."
  else:
    discard
  if response.len > 0:
    echo ""
    echo "Details:"
    echo response
  if serverResponse.len > 0:
    echo ""
    echo "Server response:"
    echo serverResponse

template initEric(cfg: Config, dryRun: bool, xml: string) =
  ## Load ERiC library, initialize, handle dry-run.
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()
  createDir(cfg.ericLogPath)
  block:
    let ericInitRc {.inject.} = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
    if ericInitRc != 0:
      echo &"Error: ERiC initialization failed with code {ericInitRc}"
      echo &"  {ericHoleFehlerText(ericInitRc)}"
      return 1
  defer: discard ericBeende()
  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

template initBuffersAndCert(cfg: Config, validateOnly: bool) =
  ## Create ERiC return buffers and open certificate. Injects responseBuf, serverBuf,
  ## flags, cryptParamPtr into caller scope.
  let responseBuf {.inject.} = ericRueckgabepufferErzeugen()
  let serverBuf {.inject.} = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)
  var flags {.inject.}: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr {.inject.}: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0
  if not validateOnly:
    block:
      let (ericCertRc {.inject.}, ericCertHandle {.inject.}) = ericGetHandleToCertificate(cfg.certPath)
      if ericCertRc != 0:
        echo &"Error: Failed to open certificate with code {ericCertRc}"
        echo &"  {ericHoleFehlerText(ericCertRc)}"
        return 1
      certHandle = ericCertHandle
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam
  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

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

  # Determine year
  let actualYear = if year == 0: now().year else: year

  if conf == "":
    echo "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForUstva)
  if not confOk: return 1

  # Validate period
  if period == "":
    echo "Error: --period is required (01-12 for monthly, 41-44 for quarterly)"
    return 1

  if not isValidPeriod(period):
    echo &"Error: Invalid period '{period}'. Use 01-12 for monthly or 41-44 for quarterly."
    return 1

  # Determine input mode: --invoices XOR --amount flags
  let hasAmounts = amount19.isSome or amount7.isSome or amount0.isSome
  let hasInvoices = invoiceFile != ""

  if hasAmounts and hasInvoices:
    echo "Error: --invoice-file and --amount19/--amount7/--amount0 are mutually exclusive"
    return 1

  if not hasAmounts and not hasInvoices:
    echo "Error: Specify --amount19/--amount7/--amount0 or --invoice-file"
    return 1

  # Resolve final amounts
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
    # If no invoices at all, all are none - that's a zero submission
    if finalAmount19.isNone and finalAmount7.isNone and finalAmount0.isNone:
      finalAmount19 = some(0.0)
    # Print invoice summary
    echo &"=== Invoices ==="
    echo &"File:     {invoiceFile}"
    if totalParsed != agg.count:
      echo &"Total:    {totalParsed} (filtered to {agg.count} for {periodDescription(period)} {actualYear})"
    else:
      echo &"Count:    {agg.count}"
    if agg.amount19.isSome:
      echo &"Sum 19%:  {agg.amount19.get:.2f} EUR"
    if agg.amount7.isSome:
      echo &"Sum 7%:   {agg.amount7.get:.2f} EUR"
    if agg.amount0.isSome:
      echo &"Sum 0%:   {agg.amount0.get:.2f} EUR"
    echo ""

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  # Extract amounts (default to 0 if provided but for XML generation)
  let amt19 = finalAmount19.get(0.0)
  let amt7 = finalAmount7.get(0.0)
  let amt0 = finalAmount0.get(0.0)

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let fullStreet = tp.street & " " & tp.housenumber

  # Generate XML
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
  initBuffersAndCert(cfg, validateOnly)

  # Calculate VAT for display
  let vat19 = amt19 * 0.19
  let vat7 = amt7 * 0.07
  let totalVat = vat19 + vat7

  # Show summary
  echo &"=== Umsatzsteuervoranmeldung ==="
  echo &"Year:        {actualYear}"
  echo &"Period:      {period} ({periodDescription(period)})"
  echo &"Tax number:  {tp.taxnumber}"
  echo ""
  if finalAmount0.isSome:
    echo &"Kz45 (0%):   {amt0:.2f} EUR (non-taxable)"
  if finalAmount19.isSome:
    echo &"Kz81 (19%):  {amt19:.2f} EUR (base) -> {vat19:.2f} EUR VAT"
  if finalAmount7.isSome:
    echo &"Kz86 (7%):   {amt7:.2f} EUR (base) -> {vat7:.2f} EUR VAT"
  echo &"Kz83 (total): {totalVat:.2f} EUR"
  echo ""

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  # Process
  var transferHandle: uint32 = 0
  let datenartVersion = &"UStVA_{actualYear}"
  let rc = ericBearbeiteVorgang(
    xml,
    datenartVersion,
    flags,
    nil,  # druckParam - no printing
    cryptParamPtr,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  # Get response content
  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc == 0:
    if validateOnly:
      echo "Validation successful!"
    else:
      echo "Submission successful!"
    if verbose and serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return 0
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

proc euer(
  year: int = 0,
  conf: string = "",
  euer: seq[string] = @[],
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
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

  if conf == "":
    echo "Error: --conf is required for EÜR submission (viking.conf file)"
    return 1

  if euer.len == 0:
    echo "Error: --euer is required for EÜR submission (invoice TSV file)"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForEuer)
  if not confOk: return 1

  # Load and aggregate invoices from all euer files
  var aggregations: seq[tuple[file: string, agg: EuerAggregation]] = @[]
  for euerFile in euer:
    if not fileExists(euerFile):
      echo &"Error: EÜR file not found: {euerFile}"
      return 1
    let (agg, ok) = loadAndAggregateForEuer(euerFile)
    if not ok:
      return 1
    aggregations.add((file: euerFile, agg: agg))

    echo &"=== Invoices ==="
    echo &"File:      {euerFile}"
    echo &"Income:    {agg.incomeCount} invoices, {agg.incomeNet:.2f} EUR net + {agg.incomeVat:.2f} EUR VAT"
    echo &"Expenses:  {agg.expenseCount} invoices, {agg.expenseNet:.2f} EUR net + {agg.expenseVorsteuer:.2f} EUR Vorsteuer"
    echo ""

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let bundesland = bundeslandFromSteuernummer(tp.taxnumber)
  let fullName = tp.firstname & " " & tp.lastname
  let fullStreet = tp.street & " " & tp.housenumber

  # Generate XML for each euer file
  var xmls: seq[string] = @[]
  for entry in aggregations:
    let xml = generateEuer(
      steuernummer = tp.taxnumber,
      jahr = actualYear,
      incomeNet = entry.agg.incomeNet,
      incomeVat = entry.agg.incomeVat,
      expenseNet = entry.agg.expenseNet,
      expenseVorsteuer = entry.agg.expenseVorsteuer,
      rechtsform = tp.rechtsform,
      einkunftsart = tp.income,
      name = fullName,
      strasse = fullStreet,
      plz = tp.zip,
      ort = tp.city,
      test = cfg.test,
      produktVersion = NimblePkgVersion,
    )
    xmls.add(xml)

  # Initialize ERiC (custom dry-run for multi-XML)
  initEric(cfg, false, "")  # never dry-run here, handle below
  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    for i, xml in xmls:
      if xmls.len > 1:
        echo ""
        echo &"=== Generated XML [{i+1}/{xmls.len}] ({aggregations[i].file}) ==="
      else:
        echo ""
        echo "=== Generated XML ==="
      echo xml
      echo "====================="
    return 0

  initBuffersAndCert(cfg, validateOnly)

  # Process each EÜR
  for i, xml in xmls:
    let entry = aggregations[i]
    let agg = entry.agg

    # Compute totals for display
    let totalIncome = agg.incomeNet + agg.incomeVat
    let totalExpense = agg.expenseNet + agg.expenseVorsteuer
    let profit = totalIncome - totalExpense

    # Show summary
    if xmls.len > 1:
      echo &"=== Einnahmenüberschussrechnung [{i+1}/{xmls.len}] ({entry.file}) ==="
    else:
      echo &"=== Einnahmenüberschussrechnung ==="
    echo &"Year:        {actualYear}"
    echo &"Tax number:  {tp.taxnumber}"
    echo &"Bundesland:  {bundesland}"
    echo &"Name:        {fullName}"
    echo ""
    echo &"Income:      {totalIncome:.2f} EUR ({agg.incomeNet:.2f} net + {agg.incomeVat:.2f} VAT)"
    echo &"Expenses:    {totalExpense:.2f} EUR ({agg.expenseNet:.2f} net + {agg.expenseVorsteuer:.2f} Vorsteuer)"
    echo &"Profit:      {profit:.2f} EUR"
    echo ""

    let modeStr = if cfg.test: " (TEST)" else: ""
    if validateOnly:
      echo &"Mode: Validate only{modeStr}"
    else:
      echo &"Mode: Send to ELSTER{modeStr}"
    echo ""

    # Process
    var transferHandle: uint32 = 0
    let datenartVersion = &"EUER_{actualYear}"
    let rc = ericBearbeiteVorgang(
      xml,
      datenartVersion,
      flags,
      nil,
      cryptParamPtr,
      addr transferHandle,
      responseBuf,
      serverBuf,
    )

    let response = ericRueckgabepufferInhalt(responseBuf)
    let serverResponse = ericRueckgabepufferInhalt(serverBuf)

    if rc == 0:
      if validateOnly:
        echo "Validation successful!"
      else:
        echo "Submission successful!"
      if verbose and serverResponse.len > 0:
        echo ""
        echo "Server response:"
        echo serverResponse
      if i < xmls.len - 1:
        echo ""
    else:
      handleEricError(rc, response, serverResponse, cfg.ericLogPath)
      return 1

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

  if conf == "":
    echo "Error: --conf is required for ESt submission (viking.conf file)"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForEst)
  if not confOk: return 1

  # Load EÜR invoices (optional — ESt without income is valid for KAP-only)
  var profits: seq[float] = @[]
  for euerFile in euer:
    if not fileExists(euerFile):
      echo &"Error: EÜR file not found: {euerFile}"
      return 1
    let (agg, ok) = loadAndAggregateForEuer(euerFile)
    if not ok:
      return 1
    let totalIncome = agg.incomeNet + agg.incomeVat
    let totalExpense = agg.expenseNet + agg.expenseVorsteuer
    let profit = totalIncome - totalExpense
    profits.add(profit)

    echo &"=== EUeR ==="
    echo &"File:      {euerFile}"
    echo &"Income:    {agg.incomeCount} invoices, {totalIncome:.2f} EUR"
    echo &"Expenses:  {agg.expenseCount} invoices, {totalExpense:.2f} EUR"
    echo &"Profit:    {profit:.2f} EUR"
    echo ""

  # Load deductions (optional)
  var ded: DeductionsByForm
  if deductions != "":
    if not fileExists(deductions):
      echo &"Error: Deductions file not found: {deductions}"
      return 1
    try:
      ded = loadDeductions(deductions, vikingConf.kidFirstnames)
    except ValueError as e:
      echo &"Error parsing deductions: {e.msg}"
      return 1
  elif not force:
    echo "Warning: no deductions file provided. Filing without deductions."
    echo "  Use --force to suppress this warning, or pass --deductions <file>"
    echo ""

  # Load KAP (optional)
  var kapTotals: KapTotals
  if kapital != "":
    if not fileExists(kapital):
      echo &"Error: KAP file not found: {kapital}"
      return 1
    try:
      kapTotals = loadKapTsv(kapital)
    except ValueError as e:
      echo &"Error parsing kap.tsv: {e.msg}"
      return 1

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let bundesland = bundeslandFromSteuernummer(tp.taxnumber)

  # Build ESt input
  let estInput = EstInput(
    conf: vikingConf,
    year: actualYear,
    profits: profits,
    deductions: ded,
    kapTotals: kapTotals,
    test: cfg.test,
    produktVersion: NimblePkgVersion,
  )

  let xml = generateEst(estInput)

  # Show summary
  let anlageStr = if tp.income == "2": "Anlage G (Gewerbebetrieb)"
                  else: "Anlage S (Selbstaendige Arbeit)"

  echo &"=== Einkommensteuererklarung ==="
  echo &"Year:        {actualYear}"
  echo &"Tax number:  {tp.taxnumber}"
  echo &"Bundesland:  {bundesland}"
  echo &"Name:        {tp.firstname} {tp.lastname}"
  if profits.len > 0:
    echo &"Anlage:      {anlageStr}"
    echo ""
    for i, profit in profits:
      if profits.len > 1:
        echo &"Profit [{i+1}]: {profit:.2f} EUR"
      else:
        echo &"Profit:      {profit:.2f} EUR"
  if ded.vor.len > 0:
    echo ""
    echo "Vorsorgeaufwand: " & $ded.vor.len & " entries"
  if ded.sa.len > 0:
    echo "Sonderausgaben: " & $ded.sa.len & " entries"
  if ded.agb.len > 0:
    echo "AgB: " & $ded.agb.len & " entries"
  if kapTotals.gains > 0 or kapTotals.tax > 0:
    echo ""
    echo "Anlage KAP:"
    if kapTotals.gains > 0:
      echo &"  Ertraege:       {kapTotals.gains:.2f} EUR"
    if kapTotals.tax > 0:
      echo &"  KapESt:         {kapTotals.tax:.2f} EUR"
    if kapTotals.soli > 0:
      echo &"  Soli:           {kapTotals.soli:.2f} EUR"
    if vikingConf.kap.guenstigerpruefung:
      echo "  Guenstigerpruefung: Ja"
  if vikingConf.kids.len > 0:
    echo ""
    echo &"Anlage Kind: {vikingConf.kids.len} Kinder"
    for kid in vikingConf.kids:
      echo &"  {kid.firstname} ({kid.birthdate})"
  echo ""

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly)

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  var transferHandle: uint32 = 0
  let datenartVersion = &"ESt_{actualYear}"
  let rc = ericBearbeiteVorgang(
    xml,
    datenartVersion,
    flags,
    nil,
    cryptParamPtr,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc == 0:
    if validateOnly:
      echo "Validation successful!"
    else:
      echo "Submission successful!"
    if verbose and serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return 0
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

proc ust(
  year: int = 0,
  conf: string = "",
  euer: seq[string] = @[],
  vorauszahlungen: float = 0.0,
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
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

  if conf == "":
    echo "Error: --conf is required for USt submission (viking.conf file)"
    return 1

  if euer.len == 0:
    echo "Error: --euer is required for USt submission"
    return 1

  let (confOk, vikingConf) = loadConf(conf, validateForUst)
  if not confOk: return 1

  let tp = vikingConf.taxpayer

  # Load and aggregate invoices from all euer files
  var agg: UstAggregation
  for euerFile in euer:
    if not fileExists(euerFile):
      echo &"Error: EÜR file not found: {euerFile}"
      return 1
    let (fileAgg, ok) = loadAndAggregateForUst(euerFile)
    if not ok:
      return 1
    agg.income19 += fileAgg.income19
    agg.income7 += fileAgg.income7
    agg.income0 += fileAgg.income0
    agg.vorsteuer += fileAgg.vorsteuer
    agg.incomeCount += fileAgg.incomeCount
    agg.expenseCount += fileAgg.expenseCount
    agg.has19 = agg.has19 or fileAgg.has19
    agg.has7 = agg.has7 or fileAgg.has7
    agg.has0 = agg.has0 or fileAgg.has0

    echo &"=== Invoices ==="
    echo &"File:      {euerFile}"
    echo &"Revenue:   {fileAgg.incomeCount} invoices"
    if fileAgg.has19:
      let v19 = fileAgg.income19 * 0.19
      echo &"  19%:     {fileAgg.income19:.2f} EUR net -> {v19:.2f} EUR VAT"
    if fileAgg.has7:
      let v7 = fileAgg.income7 * 0.07
      echo &"  7%:      {fileAgg.income7:.2f} EUR net -> {v7:.2f} EUR VAT"
    if fileAgg.has0:
      echo &"  0%:      {fileAgg.income0:.2f} EUR (non-taxable)"
    if fileAgg.expenseCount > 0:
      echo &"Expenses:  {fileAgg.expenseCount} invoices, {fileAgg.vorsteuer:.2f} EUR Vorsteuer"
    echo ""

  # Compute VAT amounts for display
  let vat19 = agg.income19 * 0.19
  let vat7 = agg.income7 * 0.07
  let totalVat = vat19 + vat7
  let remaining = totalVat - agg.vorsteuer - vorauszahlungen

  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let fullName = tp.lastname & " " & tp.firstname
  let bundesland = bundeslandFromSteuernummer(tp.taxnumber)

  # Generate XML
  let xml = generateUst(
    steuernummer = tp.taxnumber,
    jahr = actualYear,
    income19 = agg.income19,
    income7 = agg.income7,
    income0 = agg.income0,
    has19 = agg.has19,
    has7 = agg.has7,
    has0 = agg.has0,
    vorsteuer = agg.vorsteuer,
    vorauszahlungen = vorauszahlungen,
    besteuerungsart = tp.besteuerungsart,
    name = fullName,
    strasse = tp.street & " " & tp.housenumber,
    plz = tp.zip,
    ort = tp.city,
    test = cfg.test,
    produktVersion = NimblePkgVersion,
  )

  # Show summary
  echo &"=== Umsatzsteuererklaerung ==="
  echo &"Year:           {actualYear}"
  echo &"Tax number:     {tp.taxnumber}"
  echo ""
  echo &"VAT computed:   {totalVat:.2f} EUR"
  if agg.vorsteuer > 0:
    echo &"Vorsteuer:     -{agg.vorsteuer:.2f} EUR"
  if vorauszahlungen != 0:
    echo &"Advance paid:  -{vorauszahlungen:.2f} EUR"
  echo &"Remaining:      {remaining:.2f} EUR"
  echo ""

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly)

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  var transferHandle: uint32 = 0
  let datenartVersion = &"USt_{actualYear}"
  let rc = ericBearbeiteVorgang(
    xml,
    datenartVersion,
    flags,
    nil,
    cryptParamPtr,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc == 0:
    if validateOnly:
      echo "Validation successful!"
    else:
      echo "Submission successful!"
    if verbose and serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return 0
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

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

  # Load env file so VIKING_CACHE_DIR is available
  let envPath = if env.isAbsolute: env else: getCurrentDir() / env
  if fileExists(envPath):
    load(envPath.parentDir, envPath.extractFilename)

  echo &"Cache directory: {getAppCacheDir()}"
  echo ""

  if check:
    # Check existing installation
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
      echo "No ERiC installation found in cache."
      printDownloadInstructions()
      return 1

  # Download test certificates
  echo "=== Test Certificates ==="
  let (certPath, certPin, certSuccess) = downloadTestCertificates()
  echo ""

  # Get ERiC installation
  var installation: EricInstallation
  if file != "":
    # Install from local archive
    echo "=== ERiC Library ==="
    installation = setupEric(file)
    echo ""
  else:
    # Check for existing installation first
    installation = findExistingEric()
    if installation.valid:
      echo "=== ERiC Library ==="
      echo "Using existing installation."
      echo ""
    else:
      # Auto-download from portal
      let (inst, success) = fetchEric()
      if success:
        installation = inst
      else:
        return 1
      echo ""

  if installation.valid:
    # Update .env with all paths
    if certSuccess:
      updateEnvFile(installation, certPath, certPin)
    else:
      updateEnvFile(installation)

    echo ""
    echo "=== Summary ==="
    printStatus(installation)
    let years = listAvailableYears(installation)
    if years.len > 0:
      echo &"  UStVA years: {years.join(\", \")}"
    let euerYears = listAvailableEuerYears(installation)
    if euerYears.len > 0:
      echo &"  EUER years:  {euerYears.join(\", \")}"
    let estYears = listAvailableEstYears(installation)
    if estYears.len > 0:
      echo &"  ESt years:   {estYears.join(\", \")}"
    let ustYears = listAvailableUstYears(installation)
    if ustYears.len > 0:
      echo &"  USt years:   {ustYears.join(\", \")}"

    if certSuccess:
      echo ""
      echo &"Test certificate: {certPath}"
      echo &"Test PIN: {certPin}"

    echo ""
    echo "Setup complete! Run 'viking submit --help' for usage."
    return 0
  else:
    echo "ERiC setup incomplete. Use 'viking fetch --file=<path>' with a local archive."
    return 1

type
  AbholAnhang = object
    dateibezeichnung: string
    dateityp: string
    dateiReferenzId: string
    dateiGroesse: int

  AbholBereitstellung = object
    id: string
    datenart: string
    groesse: int
    veranlagungszeitraum: string
    steuernummer: string
    bescheiddatum: string
    anhaenge: seq[AbholAnhang]
    neue: bool  # true if unconfirmed (not yet retrieved)

proc findAll(node: XmlNode, tag: string): seq[XmlNode] =
  result = @[]
  if node.kind != xnElement: return
  if node.tag == tag: result.add(node)
  for child in node:
    result.add(findAll(child, tag))

proc mimeToExt(mime: string): string =
  case mime
  of "application/pdf": ".pdf"
  of "text/xml", "application/xml": ".xml"
  of "text/html": ".html"
  else: ".bin"

proc sanitizeFilename(s: string): string =
  result = s
  for c in [' ', '/', '\\', ':', '*', '?', '"', '<', '>', '|']:
    result = result.replace($c, "_")

proc parsePostfachAntwort(xmlDoc: XmlNode): seq[AbholBereitstellung] =
  result = @[]
  for dab in xmlDoc.findAll("DatenartBereitstellung"):
    let datenart = dab.attr("name")
    let anzahl = try: parseInt(dab.attr("anzahltreffer")) except: 0
    if anzahl == 0: continue

    for bs in dab.findAll("Bereitstellung"):
      var b = AbholBereitstellung(
        id: bs.attr("id"),
        datenart: datenart,
        groesse: try: parseInt(bs.attr("groesse")) except: 0,
      )

      # Extract meta information
      for meta in bs.findAll("Meta"):
        let name = meta.attr("name")
        let value = meta.innerText
        case name
        of "veranlagungszeitraum": b.veranlagungszeitraum = value
        of "steuernummer": b.steuernummer = value
        of "bescheiddatum": b.bescheiddatum = value

      # Extract attachments
      for anhang in bs.findAll("Anhang"):
        var a = AbholAnhang()
        for child in anhang:
          if child.kind != xnElement: continue
          case child.tag
          of "Dateibezeichnung": a.dateibezeichnung = child.innerText
          of "Dateityp": a.dateityp = child.innerText
          of "DateiReferenzId": a.dateiReferenzId = child.innerText
          of "DateiGroesse": a.dateiGroesse = try: parseInt(child.innerText) except: 0
        if a.dateiReferenzId.len > 0:
          b.anhaenge.add(a)

      result.add(b)

proc sendPostfachAnfrage(
  cfg: Config,
  name: string,
  cryptParam: ptr EricVerschluesselungsParameterT,
  einschraenkung: string,
  verbose: bool,
): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
  ## Send a single PostfachAnfrage with the given einschraenkung filter.
  let anfragXml = generatePostfachAnfrageXml(
    name, cfg.test, NimblePkgVersion, einschraenkung,
  )

  var transferHandle: uint32 = 0
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return (1, @[], "")
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  let rc = ericBearbeiteVorgang(
    anfragXml,
    "PostfachAnfrage_31",
    ERIC_VALIDIERE or ERIC_SENDE,
    nil,
    cryptParam,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc != 0:
    echo &"Error: Postfach request failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"
    if response.len > 0:
      echo ""
      echo "Details:"
      echo response
    if serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return (1, @[], "")

  if serverResponse.len == 0:
    return (0, @[], "")

  if verbose:
    echo ""
    echo &"=== Server Response ({einschraenkung}) ==="
    echo serverResponse
    echo "======================="

  var xmlDoc: XmlNode
  try:
    xmlDoc = parseXml(serverResponse)
  except:
    echo "Error: Failed to parse server response XML"
    echo serverResponse
    return (1, @[], "")

  let bereitstellungen = parsePostfachAntwort(xmlDoc)
  return (0, bereitstellungen, serverResponse)

proc initEricAndQueryPostfach(cfg: Config, name: string, verbose: bool): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
  ## Shared helper: initialize ERiC, send PostfachAnfrage, parse response.
  ## Queries "neue" first to identify unread items, then "alle" for full list.
  ## Returns rc=0 on success with parsed bereitstellungen, or rc>0 on error.
  ## Caller must have loaded ERiC lib and called ericInitialisiere already.

  let (certRc, certHandle) = ericGetHandleToCertificate(cfg.certPath)
  if certRc != 0:
    echo &"Error: Failed to open certificate with code {certRc}"
    echo &"  {ericHoleFehlerText(certRc)}"
    return (1, @[], "")
  defer: discard ericCloseHandleToCertificate(certHandle)

  var cryptParam: EricVerschluesselungsParameterT
  cryptParam.version = 3
  cryptParam.zertifikatHandle = certHandle
  cryptParam.pin = cfg.certPin.cstring

  let modeStr = if cfg.test: " (TEST)" else: ""
  echo &"=== Postfach{modeStr} ==="
  echo ""
  echo "Fetching Postfach..."

  # Query "neue" (unconfirmed) first to identify unread items
  let (neueRc, neueBereitstellungen, _) = sendPostfachAnfrage(cfg, name, addr cryptParam, "neue", verbose)
  if neueRc != 0:
    return (neueRc, @[], "")

  var neueIds: seq[string] = @[]
  for b in neueBereitstellungen:
    neueIds.add(b.id)

  # Query "alle" (all) for the full listing
  let (alleRc, alleBereitstellungen, serverResponse) = sendPostfachAnfrage(cfg, name, addr cryptParam, "alle", verbose)
  if alleRc != 0:
    return (alleRc, @[], "")

  echo "  OK"

  if alleBereitstellungen.len == 0 and serverResponse.len == 0:
    echo ""
    echo "No data returned from server."
    return (0, @[], "")

  # Mark items that are in the "neue" set as unread
  var bereitstellungen = alleBereitstellungen
  for i in 0..<bereitstellungen.len:
    bereitstellungen[i].neue = bereitstellungen[i].id in neueIds

  return (0, bereitstellungen, serverResponse)

proc displayBereitstellungen(bereitstellungen: seq[AbholBereitstellung]) =
  echo ""
  if bereitstellungen.len == 0:
    echo "No documents available."
    return

  let neueCount = bereitstellungen.filterIt(it.neue).len
  echo &"Found {bereitstellungen.len} document(s) ({neueCount} new):"
  for b in bereitstellungen:
    let vz = if b.veranlagungszeitraum.len > 0: " " & b.veranlagungszeitraum else: ""
    let bd = if b.bescheiddatum.len > 0:
      let d = b.bescheiddatum
      if d.len == 8: " vom " & d[6..7] & "." & d[4..5] & "." & d[0..3]
      else: " vom " & d
    else: ""
    let status = if b.neue: " [NEW]" else: ""
    echo &"  {b.datenart}{vz}{bd}{status}"
    for a in b.anhaenge:
      echo &"    - {a.dateibezeichnung} ({a.dateityp}, {a.dateiGroesse} bytes)"

proc loadConfigAndEricForAbholung(conf: string, env: string): tuple[rc: int, cfg: Config, name: string] =
  ## Load config for Datenabholung commands. Personal data from viking.conf, technical from .env.
  if conf == "":
    echo "Error: --conf is required"
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
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return (1, cfg, "")

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
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

  let (cfgRc, cfg, name) = loadConfigAndEricForAbholung(conf, env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    let anfragXml = generatePostfachAnfrageXml(
      name, cfg.test, NimblePkgVersion,
    )
    echo "=== PostfachAnfrage XML ==="
    echo anfragXml
    echo "==========================="
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, name, verbose)
  if rc != 0: return rc

  displayBereitstellungen(bereitstellungen)
  return 0

proc download(
  conf: string = "",
  output_dir: string = "",
  verbose: bool = false,
  dry_run: bool = false,
  env: string = ".env",
): int =
  ## Download all documents from the tax office Postfach
  ##
  ## Personal data from viking.conf, technical config from .env.
  ## Queries the ELSTER Postfach, downloads all documents via OTTER,
  ## and confirms retrieval. Use 'viking list' first to see what's available.
  ##
  ## Examples:
  ##   viking download -c viking.conf
  ##   viking download -c viking.conf --output_dir=./bescheide
  ##   viking download -c viking.conf --dry_run

  let (cfgRc, cfg, name) = loadConfigAndEricForAbholung(conf, env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    let anfragXml = generatePostfachAnfrageXml(
      name, cfg.test, NimblePkgVersion,
    )
    echo "=== PostfachAnfrage XML ==="
    echo anfragXml
    echo "==========================="
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, name, verbose)
  if rc != 0: return rc

  displayBereitstellungen(bereitstellungen)

  if bereitstellungen.len == 0:
    return 0

  # Determine output directory
  let outDir = if output_dir.len > 0: output_dir else: "."
  if outDir != ".":
    createDir(outDir)

  # Load Otto library for OTTER download
  let ottoLibPath = cfg.ericLibPath.parentDir / "libotto.so"
  if not loadOttoLib(ottoLibPath):
    echo &""
    echo &"Error: Failed to load Otto library from {ottoLibPath}"
    echo "Cannot download documents without libotto.so."
    return 1
  defer: unloadOttoLib()

  let (ottoRc, ottoInstanz) = ottoInstanzErzeugen(cfg.ericLogPath)
  if ottoRc != 0:
    echo &"Error: Failed to create Otto instance (code {ottoRc})"
    echo &"  {ottoHoleFehlertext(ottoRc)}"
    return 1
  defer: discard ottoInstanzFreigeben(ottoInstanz)

  echo ""
  echo "Downloading from OTTER..."

  var confirmedIds: seq[string] = @[]
  var downloadErrors = 0

  for b in bereitstellungen:
    var allOk = true

    for a in b.anhaenge:
      let ext = mimeToExt(a.dateityp)
      let vz = if b.veranlagungszeitraum.len > 0: "_" & b.veranlagungszeitraum else: ""
      let filename = sanitizeFilename(a.dateibezeichnung) & vz & ext
      let filepath = outDir / filename

      echo &"  Downloading {a.dateibezeichnung}{vz}..."

      let (bufRc, ottoBuf) = ottoRueckgabepufferErzeugen(ottoInstanz)
      if bufRc != 0:
        echo &"    Error: Failed to create download buffer (code {bufRc})"
        allOk = false
        inc downloadErrors
        continue
      defer: discard ottoRueckgabepufferFreigeben(ottoBuf)

      let dlRc = ottoDatenAbholen(
        ottoInstanz, a.dateiReferenzId, a.dateiGroesse.uint32,
        cfg.certPath, cfg.certPin, HerstellerId, ottoBuf,
      )

      if dlRc != 0:
        echo &"    Error: Download failed (code {dlRc})"
        echo &"    {ottoHoleFehlertext(dlRc)}"
        allOk = false
        inc downloadErrors
        continue

      let dataPtr = ottoRueckgabepufferInhalt(ottoBuf)
      let dataSize = ottoRueckgabepufferGroesse(ottoBuf)

      if dataPtr == nil or dataSize == 0:
        echo &"    Error: Downloaded empty data"
        allOk = false
        inc downloadErrors
        continue

      # Write binary data to file
      var data = newString(dataSize.int)
      copyMem(addr data[0], dataPtr, dataSize.int)
      writeFile(filepath, data)
      echo &"    Saved: {filepath} ({dataSize} bytes)"

    if allOk:
      confirmedIds.add(b.id)

  # Send PostfachBestaetigung for successfully downloaded documents
  if confirmedIds.len > 0:
    echo ""
    echo "Confirming retrieval..."

    # Re-open certificate for confirmation
    let (certRc, certHandle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"  Warning: Failed to open certificate for confirmation (code {certRc})"
      echo "  Documents were downloaded but not confirmed."
      echo "  Run 'viking download' again to retry confirmation."
      return 1
    defer: discard ericCloseHandleToCertificate(certHandle)

    var cryptParam: EricVerschluesselungsParameterT
    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring

    let bestXml = generatePostfachBestaetigungXml(
      confirmedIds, name, cfg.test, NimblePkgVersion,
    )

    if verbose:
      echo ""
      echo "=== PostfachBestaetigung XML ==="
      echo bestXml
      echo "================================"

    var bestTransferHandle: uint32 = 0
    let bestResponseBuf = ericRueckgabepufferErzeugen()
    let bestServerBuf = ericRueckgabepufferErzeugen()
    if bestResponseBuf == nil or bestServerBuf == nil:
      echo "Error: Failed to create return buffers for confirmation"
      return 1
    defer:
      discard ericRueckgabepufferFreigabe(bestResponseBuf)
      discard ericRueckgabepufferFreigabe(bestServerBuf)

    let bestRc = ericBearbeiteVorgang(
      bestXml,
      "PostfachBestaetigung_31",
      ERIC_VALIDIERE or ERIC_SENDE,
      nil,
      addr cryptParam,
      addr bestTransferHandle,
      bestResponseBuf,
      bestServerBuf,
    )

    if bestRc != 0:
      let bestResponse = ericRueckgabepufferInhalt(bestResponseBuf)
      let bestServerResponse = ericRueckgabepufferInhalt(bestServerBuf)
      echo &"  Warning: Confirmation failed with code {bestRc}"
      echo &"  {ericHoleFehlerText(bestRc)}"
      if bestResponse.len > 0:
        echo &"  {bestResponse}"
      if bestServerResponse.len > 0:
        echo &"  {bestServerResponse}"
      echo ""
      echo "  Documents were downloaded but not confirmed."
      echo "  You must confirm within 24 hours to avoid HerstellerID suspension."
      echo "  Run 'viking download' again to retry confirmation."
    else:
      echo &"  OK - confirmed {confirmedIds.len} document(s)"

  echo ""
  if downloadErrors > 0:
    echo &"Download complete with {downloadErrors} error(s)."
  else:
    echo "Download complete."
  return 0

proc iban(
  new_iban: string = "",
  conf: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Change bank account (IBAN) at the Finanzamt
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking iban -c viking.conf --new-iban DE89370400440532013000
  ##   viking iban -c viking.conf --new-iban DE89370400440532013000 --dry-run

  if new_iban == "":
    echo "Error: --new-iban is required"
    return 1

  if conf == "":
    echo "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForBankverbindung)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let xml = generateBankverbindungXml(
    steuernummer = tp.taxnumber,
    name = fullName,
    vorname = tp.firstname,
    nachname = tp.lastname,
    idnr = tp.idnr,
    geburtsdatum = tp.birthdate,
    iban = new_iban,
    test = cfg.test,
  )

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly)

  echo "=== IBAN-Änderung ==="
  echo &"Tax number: {tp.taxnumber}"
  echo &"New IBAN:   {new_iban}"
  echo ""

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  var transferHandle: uint32 = 0
  let rc = ericBearbeiteVorgang(
    xml,
    "AenderungBankverbindung_20",
    flags,
    nil,
    cryptParamPtr,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc == 0:
    if validateOnly:
      echo "Validation successful!"
    else:
      echo "IBAN change submitted successfully!"
    if verbose and serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return 0
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

proc message(
  subject: string = "",
  text: string = "",
  text_file: string = "",
  conf: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Send a message (Sonstige Nachricht) to the Finanzamt
  ##
  ## Personal data from viking.conf, technical config from .env.
  ##
  ## Examples:
  ##   viking message -c viking.conf --subject "Rückfrage" --text "Sehr geehrte Damen und Herren, ..."
  ##   viking message -c viking.conf --subject "Rückfrage" --text-file brief.txt

  if subject == "":
    echo "Error: --subject is required"
    return 1

  if subject.len > 99:
    echo "Error: --subject must be at most 99 characters"
    return 1

  # Resolve message text
  var messageText = text
  if text_file != "" and text != "":
    echo "Error: --text and --text-file are mutually exclusive"
    return 1
  elif text_file != "":
    if text_file == "-":
      messageText = stdin.readAll().strip
    elif not fileExists(text_file):
      echo &"Error: File not found: {text_file}"
      return 1
    else:
      messageText = readFile(text_file).strip

  if messageText == "":
    echo "Error: --text or --text-file is required"
    return 1

  if messageText.len > 15000:
    echo &"Error: Message text exceeds 15000 characters ({messageText.len})"
    return 1

  if conf == "":
    echo "Error: --conf is required (viking.conf file)"
    return 1
  let (confOk, vikingConf) = loadConf(conf, validateForNachricht)
  if not confOk: return 1
  let (techOk, cfg) = loadTechConfig(env, validateOnly, dryRun)
  if not techOk: return 1

  let tp = vikingConf.taxpayer
  let fullName = tp.firstname & " " & tp.lastname
  let xml = generateNachrichtXml(
    steuernummer = tp.taxnumber,
    name = fullName,
    strasse = tp.street,
    hausnummer = tp.housenumber,
    plz = tp.zip,
    ort = tp.city,
    betreff = subject,
    text = messageText,
    test = cfg.test,
    produktVersion = NimblePkgVersion,
  )

  initEric(cfg, dryRun, xml)
  initBuffersAndCert(cfg, validateOnly)

  echo "=== Sonstige Nachricht ==="
  echo &"Tax number:  {tp.taxnumber}"
  echo &"Subject:     {subject}"
  echo &"Text length: {messageText.len} characters"
  echo ""

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  var transferHandle: uint32 = 0
  let rc = ericBearbeiteVorgang(
    xml,
    "SonstigeNachrichten_21",
    flags,
    nil,
    cryptParamPtr,
    addr transferHandle,
    responseBuf,
    serverBuf,
  )

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc == 0:
    if validateOnly:
      echo "Validation successful!"
    else:
      echo "Message sent successfully!"
    if verbose and serverResponse.len > 0:
      echo ""
      echo "Server response:"
      echo serverResponse
    return 0
  else:
    handleEricError(rc, response, serverResponse, cfg.ericLogPath)
    return 1

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
    echo &"Error: directory '{dir}' does not exist"
    return 1

  var created: seq[string]
  var skipped: seq[string]

  # viking.conf
  if not force and fileExists(confPath):
    skipped.add(confPath)
  else:
    writeFile(confPath, """[taxpayer]
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
""")
    created.add(confPath)

  # deductions.tsv
  if not force and fileExists(deductionsPath):
    skipped.add(deductionsPath)
  else:
    writeFile(deductionsPath, "code\tamount\tdescription\n" &
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
      "agb187\t0\tKrankheitskosten\n")
    created.add(deductionsPath)

  # kap.tsv
  if not force and fileExists(kapPath):
    skipped.add(kapPath)
  else:
    writeFile(kapPath, "gains\ttax\tsoli\tkirchensteuer\tdescription\n" &
      "0\t0\t0\t\tBroker Name\n")
    created.add(kapPath)

  # euer.tsv
  if not force and fileExists(euerPath):
    skipped.add(euerPath)
  else:
    writeFile(euerPath, "amount\trate\tdate\tid\tdescription\n" &
      "0\t19\t2025-01-01\tINV-001\tExample invoice\n" &
      "-0\t19\t2025-01-01\tEXP-001\tExample expense\n")
    created.add(euerPath)

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
        "env": "Path to env file (default: .env)",
      },
      short = {
        "year": 'y',
        "conf": 'c',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
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
        "env": "Path to env file (default: .env)",
      },
      short = {
        "new_iban": 'i',
        "conf": 'c',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
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
        "env": "Path to env file (default: .env)",
      },
      short = {
        "subject": 's',
        "text": 't',
        "text_file": 'f',
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
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
        "conf": "viking.conf file with taxpayer data",
        "output_dir": "Output directory for downloaded files (default: current dir)",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response and confirmation XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "conf": 'c',
        "output_dir": 'o',
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
