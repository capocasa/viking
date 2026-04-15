## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os, xmltree, xmlparser, sequtils, tables]
import cligen, cligen/argcvt
import dotenv
import config, eric_ffi, otto_ffi, ustva_xml, euer_xml, est_xml, ust_xml, eric_setup, invoices, abholung_xml, nachricht_xml, bankverbindung_xml
import viking_conf, deductions, kap

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

proc submit(
  amount19: Option[float] = none(float),
  amount7: Option[float] = none(float),
  amount0: Option[float] = none(float),
  invoice_file: string = "",
  period: string = "",
  year: int = 0,
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Submit a German VAT advance return (Umsatzsteuervoranmeldung)
  ##
  ## Examples:
  ##   viking --amount19=1000.00 --period=01 --year=2025
  ##   viking --amount19=1000 --amount7=500 --period=41 --year=2025
  ##   viking --amount19=100 --period=01 --validate-only

  # Determine year
  let actualYear = if year == 0: now().year else: year

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

  # Load and validate configuration
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1
  # Dry-run validates everything to ensure setup is correct
  let errors = if validateOnly and not dryRun: cfg.validateForValidateOnly()
               else: cfg.validateForSubmission()

  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file. See .env.example for required settings."
    return 1

  # Extract amounts (default to 0 if provided but for XML generation)
  let amt19 = finalAmount19.get(0.0)
  let amt7 = finalAmount7.get(0.0)
  let amt0 = finalAmount0.get(0.0)

  # Generate XML
  let xml = generateUstva(
    steuernummer = cfg.steuernummer,
    jahr = actualYear,
    zeitraum = period,
    kz81 = finalAmount19,
    kz86 = finalAmount7,
    kz45 = finalAmount0,
    herstellerId = cfg.herstellerId,
    produktName = cfg.produktName,
    name = cfg.name,
    strasse = cfg.strasse,
    plz = cfg.plz,
    ort = cfg.ort,
    test = cfg.test,
  )

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  # Ensure log directory exists
  createDir(cfg.ericLogPath)

  # Initialize ERiC
  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  # Dry run mode - verify setup and show XML without submitting
  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  # Create return buffers
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  # Determine flags
  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  # Set up encryption parameters if sending
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    # Open certificate
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

  # Calculate VAT for display
  let vat19 = amt19 * 0.19
  let vat7 = amt7 * 0.07
  let totalVat = vat19 + vat7

  # Show summary
  echo &"=== Umsatzsteuervoranmeldung ==="
  echo &"Year:        {actualYear}"
  echo &"Period:      {period} ({periodDescription(period)})"
  echo &"Tax number:  {cfg.steuernummer}"
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
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    # Actionable hints for known error codes
    case rc
    of 610301202:
      echo ""
      echo "Hint: The demo HerstellerID (74931) is blocked."
      echo "  Register at https://www.elster.de/elsterweb/entwickler"
      echo "  and set HERSTELLER_ID in your .env file."
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
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

    return 1

proc euer(
  invoice_file: string = "",
  year: int = 0,
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Submit an EÜR (Einnahmenüberschussrechnung / profit-loss statement)
  ##
  ## Positive invoice amounts = income, negative = expenses.
  ##
  ## Examples:
  ##   viking euer -i invoices.csv -y 2025
  ##   viking euer -i invoices.csv -y 2025 --validate-only
  ##   viking euer -i invoices.csv --dry-run

  let actualYear = if year == 0: now().year else: year

  if invoiceFile == "":
    echo "Error: --invoice-file is required for EÜR submission"
    return 1

  # Load and aggregate invoices
  let (agg, ok) = loadAndAggregateForEuer(invoiceFile)
  if not ok:
    return 1

  echo &"=== Invoices ==="
  echo &"File:      {invoiceFile}"
  echo &"Income:    {agg.incomeCount} invoices, {agg.incomeNet:.2f} EUR net + {agg.incomeVat:.2f} EUR VAT"
  echo &"Expenses:  {agg.expenseCount} invoices, {agg.expenseNet:.2f} EUR net + {agg.expenseVorsteuer:.2f} EUR Vorsteuer"
  echo ""

  # Load and validate configuration
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let errors = if validateOnly and not dryRun: cfg.validateForEuerValidateOnly()
               else: cfg.validateForEuerSubmission()

  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file. EÜR requires RECHTSFORM and EINKUNFTSART."
    return 1

  let bundesland = bundeslandFromSteuernummer(cfg.steuernummer)

  # Generate XML
  let xml = generateEuer(
    steuernummer = cfg.steuernummer,
    jahr = actualYear,
    incomeNet = agg.incomeNet,
    incomeVat = agg.incomeVat,
    expenseNet = agg.expenseNet,
    expenseVorsteuer = agg.expenseVorsteuer,
    rechtsform = cfg.rechtsform,
    einkunftsart = cfg.einkunftsart,
    herstellerId = cfg.herstellerId,
    produktName = cfg.produktName,
    name = cfg.name,
    strasse = cfg.strasse,
    plz = cfg.plz,
    ort = cfg.ort,
    test = cfg.test,
  )

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  # Ensure log directory exists
  createDir(cfg.ericLogPath)

  # Initialize ERiC
  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  # Dry run mode
  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  # Create return buffers
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  # Determine flags
  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  # Set up encryption parameters if sending
  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

  # Compute totals for display
  let totalIncome = agg.incomeNet + agg.incomeVat
  let totalExpense = agg.expenseNet + agg.expenseVorsteuer
  let profit = totalIncome - totalExpense

  # Show summary
  echo &"=== Einnahmenüberschussrechnung ==="
  echo &"Year:        {actualYear}"
  echo &"Tax number:  {cfg.steuernummer}"
  echo &"Bundesland:  {bundesland}"
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

    return 0
  else:
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    case rc
    of 610301202:
      echo ""
      echo "Hint: The demo HerstellerID (74931) is blocked."
      echo "  Register at https://www.elster.de/elsterweb/entwickler"
      echo "  and set HERSTELLER_ID in your .env file."
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
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

    return 1

proc est(
  year: int = 0,
  conf: string = "",
  euer: string = "",
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
  ##
  ## Examples:
  ##   viking est -y 2025 -c viking.conf --euer euer.tsv --deductions deductions.tsv
  ##   viking est -y 2025 -c viking.conf --kapital kap.tsv
  ##   viking est -y 2025 -c viking.conf --euer euer.tsv --dry-run

  let actualYear = if year == 0: now().year else: year

  if conf == "":
    echo "Error: --conf is required for ESt submission (viking.conf file)"
    return 1

  # Load viking.conf
  var vikingConf: VikingConf
  try:
    vikingConf = loadVikingConf(conf)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1
  except ValueError as e:
    echo &"Error parsing {conf}: {e.msg}"
    return 1

  let confErrors = vikingConf.validateForEst()
  if confErrors.len > 0:
    echo "Configuration errors in " & conf & ":"
    for e in confErrors:
      echo &"  - {e}"
    return 1

  # Load EÜR invoices (optional — ESt without income is valid for KAP-only)
  var profit = 0.0
  if euer != "":
    if not fileExists(euer):
      echo &"Error: EÜR file not found: {euer}"
      return 1
    let (agg, ok) = loadAndAggregateForEuer(euer)
    if not ok:
      return 1
    let totalIncome = agg.incomeNet + agg.incomeVat
    let totalExpense = agg.expenseNet + agg.expenseVorsteuer
    profit = totalIncome - totalExpense

    echo &"=== EUeR ==="
    echo &"File:      {euer}"
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

  # Load technical .env config
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  # Validate technical config
  let techErrors = if validateOnly and not dryRun: cfg.validateForValidateOnly()
                   else: cfg.validate()
  if techErrors.len > 0:
    echo "Configuration errors in .env:"
    for e in techErrors:
      echo &"  - {e}"
    return 1

  let tp = vikingConf.taxpayer
  let bundesland = bundeslandFromSteuernummer(tp.taxnumber)

  # Build ESt input
  let estInput = EstInput(
    conf: vikingConf,
    year: actualYear,
    profit: profit,
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
  if euer != "":
    echo &"Anlage:      {anlageStr}"
    echo ""
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

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

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
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    case rc
    of 610301202:
      echo ""
      echo "Hint: The demo HerstellerID (74931) is blocked."
      echo "  Register at https://www.elster.de/elsterweb/entwickler"
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
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

    return 1

proc ust(
  year: int = 0,
  conf: string = "",
  euer: string = "",
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
  ##
  ## Examples:
  ##   viking ust -y 2025 -c viking.conf --euer euer.tsv --vorauszahlungen=1200
  ##   viking ust -y 2025 -c viking.conf --euer euer.tsv --validate-only
  ##   viking ust -y 2025 -c viking.conf --euer euer.tsv --dry-run

  let actualYear = if year == 0: now().year else: year

  if conf == "":
    echo "Error: --conf is required for USt submission (viking.conf file)"
    return 1

  if euer == "":
    echo "Error: --euer is required for USt submission"
    return 1

  # Load viking.conf
  var vikingConf: VikingConf
  try:
    vikingConf = loadVikingConf(conf)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1
  except ValueError as e:
    echo &"Error parsing {conf}: {e.msg}"
    return 1

  let tp = vikingConf.taxpayer
  if tp.taxnumber == "":
    echo "Error: taxpayer.taxnumber not set in viking.conf"
    return 1
  if tp.besteuerungsart != "1" and tp.besteuerungsart != "2" and tp.besteuerungsart != "3":
    echo "Error: taxpayer.besteuerungsart must be 1, 2 or 3 in viking.conf"
    return 1

  # Load and aggregate invoices
  if not fileExists(euer):
    echo &"Error: EÜR file not found: {euer}"
    return 1
  let (agg, ok) = loadAndAggregateForUst(euer)
  if not ok:
    return 1

  # Compute VAT amounts for display
  let vat19 = agg.income19 * 0.19
  let vat7 = agg.income7 * 0.07
  let totalVat = vat19 + vat7
  let remaining = totalVat - agg.vorsteuer - vorauszahlungen

  echo &"=== Invoices ==="
  echo &"File:      {euer}"
  echo &"Revenue:   {agg.incomeCount} invoices"
  if agg.has19:
    echo &"  19%:     {agg.income19:.2f} EUR net -> {vat19:.2f} EUR VAT"
  if agg.has7:
    echo &"  7%:      {agg.income7:.2f} EUR net -> {vat7:.2f} EUR VAT"
  if agg.has0:
    echo &"  0%:      {agg.income0:.2f} EUR (non-taxable)"
  if agg.expenseCount > 0:
    echo &"Expenses:  {agg.expenseCount} invoices, {agg.vorsteuer:.2f} EUR Vorsteuer"
  echo ""

  # Load technical .env config
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let techErrors = if validateOnly and not dryRun: cfg.validateForValidateOnly()
                   else: cfg.validate()
  if techErrors.len > 0:
    echo "Configuration errors in .env:"
    for e in techErrors:
      echo &"  - {e}"
    return 1

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
    herstellerId = HerstellerId,
    produktName = ProduktName,
    name = fullName,
    strasse = tp.street & " " & tp.housenumber,
    plz = tp.zip,
    ort = tp.city,
    test = cfg.test,
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

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

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
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    case rc
    of 610301202:
      echo ""
      echo "Hint: The demo HerstellerID (74931) is blocked."
      echo "  Register at https://www.elster.de/elsterweb/entwickler"
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
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
  cryptParam: ptr EricVerschluesselungsParameterT,
  einschraenkung: string,
  verbose: bool,
): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
  ## Send a single PostfachAnfrage with the given einschraenkung filter.
  let anfragXml = generatePostfachAnfrageXml(
    cfg.herstellerId, cfg.name, cfg.test, einschraenkung,
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

proc initEricAndQueryPostfach(cfg: Config, verbose: bool): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
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
  let (neueRc, neueBereitstellungen, _) = sendPostfachAnfrage(cfg, addr cryptParam, "neue", verbose)
  if neueRc != 0:
    return (neueRc, @[], "")

  var neueIds: seq[string] = @[]
  for b in neueBereitstellungen:
    neueIds.add(b.id)

  # Query "alle" (all) for the full listing
  let (alleRc, alleBereitstellungen, serverResponse) = sendPostfachAnfrage(cfg, addr cryptParam, "alle", verbose)
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

proc loadConfigAndEric(env: string): tuple[rc: int, cfg: Config] =
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return (1, cfg)

  let errors = cfg.validate()
  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file."
    return (1, cfg)

  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return (1, cfg)

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    unloadEricLib()
    return (1, cfg)

  return (0, cfg)

proc list(
  verbose: bool = false,
  dry_run: bool = false,
  env: string = ".env",
): int =
  ## List available documents in the tax office Postfach
  ##
  ## Queries the ELSTER Postfach without downloading or confirming anything.
  ##
  ## Examples:
  ##   viking list
  ##   viking list --verbose

  let (cfgRc, cfg) = loadConfigAndEric(env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    let anfragXml = generatePostfachAnfrageXml(
      cfg.herstellerId, cfg.name, cfg.test,
    )
    echo "=== PostfachAnfrage XML ==="
    echo anfragXml
    echo "==========================="
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, verbose)
  if rc != 0: return rc

  displayBereitstellungen(bereitstellungen)
  return 0

proc download(
  output_dir: string = "",
  verbose: bool = false,
  dry_run: bool = false,
  env: string = ".env",
): int =
  ## Download all documents from the tax office Postfach
  ##
  ## Queries the ELSTER Postfach, downloads all documents via OTTER,
  ## and confirms retrieval. Use 'viking list' first to see what's available.
  ##
  ## Examples:
  ##   viking download
  ##   viking download --output_dir=./bescheide
  ##   viking download --dry_run

  let (cfgRc, cfg) = loadConfigAndEric(env)
  if cfgRc != 0: return cfgRc
  defer:
    discard ericBeende()
    unloadEricLib()

  if dry_run:
    let anfragXml = generatePostfachAnfrageXml(
      cfg.herstellerId, cfg.name, cfg.test,
    )
    echo "=== PostfachAnfrage XML ==="
    echo anfragXml
    echo "==========================="
    return 0

  let (rc, bereitstellungen, _) = initEricAndQueryPostfach(cfg, verbose)
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
        cfg.certPath, cfg.certPin, cfg.herstellerId, ottoBuf,
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
      confirmedIds, cfg.herstellerId, cfg.name, cfg.test,
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
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Change bank account (IBAN) at the Finanzamt
  ##
  ## Examples:
  ##   viking iban --new-iban DE89370400440532013000
  ##   viking iban --new-iban DE89370400440532013000 --dry-run

  if new_iban == "":
    echo "Error: --new-iban is required"
    return 1

  # Load config
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let errors = if validateOnly and not dryRun: cfg.validateForEstValidateOnly()
               else: cfg.validateForEstSubmission()
  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file. See .env.example for required settings."
    return 1

  if cfg.idnr == "":
    echo "Error: IDNR not set (11-digit tax identification number)"
    echo "  Add IDNR=... to your .env file."
    return 1

  let xml = generateBankverbindungXml(
    steuernummer = cfg.steuernummer,
    herstellerId = cfg.herstellerId,
    name = cfg.name,
    vorname = cfg.vorname,
    nachname = cfg.nachname,
    idnr = cfg.idnr,
    geburtsdatum = cfg.geburtsdatum,
    iban = new_iban,
    test = cfg.test,
  )

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  # Create return buffers
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

  echo "=== IBAN-Änderung ==="
  echo &"Tax number: {cfg.steuernummer}"
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
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    case rc
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
      if fileExists(logFile):
        let logContent = readFile(logFile).strip
        if logContent.len > 0:
          echo ""
          echo "ERiC log:"
          echo logContent
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

    return 1

proc message(
  subject: string = "",
  text: string = "",
  text_file: string = "",
  validate_only: bool = false,
  dry_run: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Send a message (Sonstige Nachricht) to the Finanzamt
  ##
  ## Examples:
  ##   viking message --subject "Rückfrage" --text "Sehr geehrte Damen und Herren, ..."
  ##   viking message --subject "Rückfrage" --text-file brief.txt

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

  # Load config
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let errors = if validateOnly and not dryRun: cfg.validateForNachrichtValidateOnly()
               else: cfg.validateForNachrichtSubmission()
  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file. See .env.example for required settings."
    return 1

  let xml = generateNachrichtXml(
    steuernummer = cfg.steuernummer,
    herstellerId = cfg.herstellerId,
    name = cfg.name,
    strasse = cfg.strasse,
    hausnummer = cfg.hausnummer,
    plz = cfg.plz,
    ort = cfg.ort,
    betreff = subject,
    text = messageText,
    test = cfg.test,
  )

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

  createDir(cfg.ericLogPath)

  let initRc = ericInitialisiere(cfg.ericPluginPath, cfg.ericLogPath)
  if initRc != 0:
    echo &"Error: ERiC initialization failed with code {initRc}"
    echo &"  {ericHoleFehlerText(initRc)}"
    return 1
  defer: discard ericBeende()

  if dryRun:
    echo "ERiC library loaded and initialized successfully."
    echo ""
    echo "=== Generated XML ==="
    echo xml
    echo "====================="
    return 0

  # Create return buffers
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  var flags: uint32 = ERIC_VALIDIERE
  if not validateOnly:
    flags = flags or ERIC_SENDE

  var cryptParam: EricVerschluesselungsParameterT
  var cryptParamPtr: ptr EricVerschluesselungsParameterT = nil
  var certHandle: EricZertifikatHandle = 0

  if not validateOnly:
    let (certRc, handle) = ericGetHandleToCertificate(cfg.certPath)
    if certRc != 0:
      echo &"Error: Failed to open certificate with code {certRc}"
      echo &"  {ericHoleFehlerText(certRc)}"
      return 1
    certHandle = handle

    cryptParam.version = 3
    cryptParam.zertifikatHandle = certHandle
    cryptParam.pin = cfg.certPin.cstring
    cryptParamPtr = addr cryptParam

  defer:
    if certHandle != 0:
      discard ericCloseHandleToCertificate(certHandle)

  echo "=== Sonstige Nachricht ==="
  echo &"Tax number:  {cfg.steuernummer}"
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
    echo &"Error: Operation failed with code {rc}"
    echo &"  {ericHoleFehlerText(rc)}"

    case rc
    of 610301200:
      echo ""
      echo "Hint: XML schema validation failed."
      let logFile = cfg.ericLogPath / "eric.log"
      if fileExists(logFile):
        let logContent = readFile(logFile).strip
        if logContent.len > 0:
          echo ""
          echo "ERiC log:"
          echo logContent
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

    return 1

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
        "validate_only": 'n',
        "dry_run": 'd',
        "verbose": 'v',
        "env": 'e',
      }
    ],
    [euer,
      help = {
        "invoice_file": "CSV/TSV invoice file (positive=income, negative=expenses)",
        "year": "Tax year (default: current year)",
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "invoice_file": 'i',
        "year": 'y',
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
        "euer": "EUeR income/expense TSV (optional)",
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
        "euer": "EUeR income/expense TSV (required)",
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
        "validate_only": "Only validate, don't send",
        "dry_run": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "new_iban": 'i',
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
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "dry_run": 'd',
        "verbose": 'v',
        "env": 'e',
      }
    ],
    [download,
      help = {
        "output_dir": "Output directory for downloaded files (default: current dir)",
        "dry_run": "Show generated XML without sending",
        "verbose": "Show full server response and confirmation XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
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
    ]
  )
