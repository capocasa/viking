## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os]
import cligen, cligen/argcvt
import dotenv
import config, eric_ffi, ustva_xml, euer_xml, eric_setup, invoices

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
  invoiceFile: string = "",
  period: string = "",
  year: int = 0,
  validateOnly: bool = false,
  dryRun: bool = false,
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
  invoiceFile: string = "",
  year: int = 0,
  validateOnly: bool = false,
  dryRun: bool = false,
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

when isMainModule:
  import cligen
  dispatchMulti(
    [submit,
      help = {
        "amount19": "Net amount at 19% VAT rate (Kz81)",
        "amount7": "Net amount at 7% VAT rate (Kz86)",
        "amount0": "Non-taxable amount at 0% (Kz45)",
        "invoiceFile": "CSV/TSV invoice file (- for stdin)",
        "period": "Period: 01-12 (monthly) or 41-44 (quarterly)",
        "year": "Tax year (default: current year)",
        "validateOnly": "Only validate, don't send",
        "dryRun": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "amount19": '1',
        "amount7": '7',
        "amount0": '0',
        "invoiceFile": 'i',
        "period": 'p',
        "year": 'y',
        "validateOnly": 'v',
        "dryRun": 'd',
        "verbose": 'V',
        "env": 'e',
      }
    ],
    [euer,
      help = {
        "invoiceFile": "CSV/TSV invoice file (positive=income, negative=expenses)",
        "year": "Tax year (default: current year)",
        "validateOnly": "Only validate, don't send",
        "dryRun": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "invoiceFile": 'i',
        "year": 'y',
        "validateOnly": 'v',
        "dryRun": 'd',
        "verbose": 'V',
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
