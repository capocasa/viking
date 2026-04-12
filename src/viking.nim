## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os, xmltree, xmlparser]
import cligen, cligen/argcvt
import dotenv
import config, eric_ffi, otto_ffi, ustva_xml, euer_xml, est_xml, ust_xml, eric_setup, invoices, abholung_xml

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

proc est(
  invoiceFile: string = "",
  year: int = 0,
  validateOnly: bool = false,
  dryRun: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Submit an ESt (Einkommensteuererklarung / income tax return)
  ##
  ## Uses the same invoice file as EUeR to compute profit from self-employment.
  ## Positive amounts = income, negative = expenses.
  ##
  ## Requires: VORNAME, NACHNAME, GEBURTSDATUM, IBAN, EINKUNFTSART in .env
  ##
  ## Examples:
  ##   viking est -i invoices.csv -y 2025
  ##   viking est -i invoices.csv -y 2025 --validate-only
  ##   viking est -i invoices.csv --dry-run

  let actualYear = if year == 0: now().year else: year

  if invoiceFile == "":
    echo "Error: --invoice-file is required for ESt submission"
    return 1

  # Load and aggregate invoices (same as EUeR)
  let (agg, ok) = loadAndAggregateForEuer(invoiceFile)
  if not ok:
    return 1

  let totalIncome = agg.incomeNet + agg.incomeVat
  let totalExpense = agg.expenseNet + agg.expenseVorsteuer
  let profit = totalIncome - totalExpense

  echo &"=== Invoices ==="
  echo &"File:      {invoiceFile}"
  echo &"Income:    {agg.incomeCount} invoices, {totalIncome:.2f} EUR"
  echo &"Expenses:  {agg.expenseCount} invoices, {totalExpense:.2f} EUR"
  echo &"Profit:    {profit:.2f} EUR"
  echo ""

  # Load and validate configuration
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
    echo "Please check your .env file. ESt requires VORNAME, NACHNAME, GEBURTSDATUM, IBAN, EINKUNFTSART."
    return 1

  let bundesland = bundeslandFromSteuernummer(cfg.steuernummer)

  # Generate XML
  let xml = generateEst(
    steuernummer = cfg.steuernummer,
    jahr = actualYear,
    profit = profit,
    einkunftsart = cfg.einkunftsart,
    herstellerId = cfg.herstellerId,
    produktName = cfg.produktName,
    vorname = cfg.vorname,
    nachname = cfg.nachname,
    geburtsdatum = cfg.geburtsdatum,
    strasse = cfg.strasse,
    hausnummer = cfg.hausnummer,
    plz = cfg.plz,
    ort = cfg.ort,
    iban = cfg.iban,
    religion = cfg.religion,
    beruf = cfg.beruf,
    krankenversicherung = cfg.krankenversicherung,
    pflegeversicherung = cfg.pflegeversicherung,
    rentenversicherung = cfg.rentenversicherung,
    kvArt = cfg.kvArt,
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

  # Determine Anlage type for display
  let anlageStr = if cfg.einkunftsart == "2": "Anlage G (Gewerbebetrieb)"
                  else: "Anlage S (Selbstaendige Arbeit)"

  # Show summary
  echo &"=== Einkommensteuererklarung ==="
  echo &"Year:        {actualYear}"
  echo &"Tax number:  {cfg.steuernummer}"
  echo &"Bundesland:  {bundesland}"
  echo &"Name:        {cfg.vorname} {cfg.nachname}"
  echo &"Anlage:      {anlageStr}"
  echo ""
  echo &"Profit:      {profit:.2f} EUR"
  if cfg.krankenversicherung > 0 or cfg.pflegeversicherung > 0 or cfg.rentenversicherung > 0:
    echo ""
    echo "Vorsorgeaufwand:"
    if cfg.krankenversicherung > 0:
      echo &"  KV ({cfg.kvArt}): {cfg.krankenversicherung:.2f} EUR"
    if cfg.pflegeversicherung > 0:
      echo &"  PV:          {cfg.pflegeversicherung:.2f} EUR"
    if cfg.rentenversicherung > 0:
      echo &"  RV:          {cfg.rentenversicherung:.2f} EUR"
  echo ""

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  # Process
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

proc ust(
  invoiceFile: string = "",
  vorauszahlungen: float = 0.0,
  year: int = 0,
  validateOnly: bool = false,
  dryRun: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Submit an annual VAT return (Umsatzsteuererklaerung)
  ##
  ## Uses the same invoice file format as other commands.
  ## Positive amounts = revenue, negative = expenses (for Vorsteuer).
  ## Provide --vorauszahlungen with the total UStVA advance payments made.
  ##
  ## Examples:
  ##   viking ust -i invoices.csv -y 2025 --vorauszahlungen=1200
  ##   viking ust -i invoices.csv -y 2025 --validate-only
  ##   viking ust -i invoices.csv --dry-run

  let actualYear = if year == 0: now().year else: year

  if invoiceFile == "":
    echo "Error: --invoice-file is required for USt submission"
    return 1

  # Load and aggregate invoices
  let (agg, ok) = loadAndAggregateForUst(invoiceFile)
  if not ok:
    return 1

  # Compute VAT amounts for display
  let vat19 = agg.income19 * 0.19
  let vat7 = agg.income7 * 0.07
  let totalVat = vat19 + vat7
  let remaining = totalVat - agg.vorsteuer - vorauszahlungen

  echo &"=== Invoices ==="
  echo &"File:      {invoiceFile}"
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

  # Load and validate configuration
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let errors = if validateOnly and not dryRun: cfg.validateForUstValidateOnly()
               else: cfg.validateForUstSubmission()

  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file."
    return 1

  let bundesland = bundeslandFromSteuernummer(cfg.steuernummer)

  # Generate XML
  let xml = generateUst(
    steuernummer = cfg.steuernummer,
    jahr = actualYear,
    income19 = agg.income19,
    income7 = agg.income7,
    income0 = agg.income0,
    has19 = agg.has19,
    has7 = agg.has7,
    has0 = agg.has0,
    vorsteuer = agg.vorsteuer,
    vorauszahlungen = vorauszahlungen,
    besteuerungsart = cfg.besteuerungsart,
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

  # Show summary
  echo &"=== Umsatzsteuererklaerung ==="
  echo &"Year:           {actualYear}"
  echo &"Tax number:     {cfg.steuernummer}"
  echo ""
  echo &"VAT computed:   {totalVat:.2f} EUR"
  if agg.vorsteuer > 0:
    echo &"Vorsteuer:     -{agg.vorsteuer:.2f} EUR"
  if vorauszahlungen != 0:
    echo &"Advance paid:  -{vorauszahlungen:.2f} EUR"
  echo &"Remaining:      {remaining:.2f} EUR"
  echo ""

  let modeStr = if cfg.test: " (TEST)" else: ""
  if validateOnly:
    echo &"Mode: Validate only{modeStr}"
  else:
    echo &"Mode: Send to ELSTER{modeStr}"
  echo ""

  # Process
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

proc retrieve(
  output: string = "",
  dryRun: bool = false,
  verbose: bool = false,
  env: string = ".env",
): int =
  ## Retrieve documents from the tax office (Datenabholung)
  ##
  ## Queries the ELSTER Postfach, downloads documents via OTTER,
  ## and confirms retrieval. Downloaded files are saved to the
  ## output directory.
  ##
  ## Examples:
  ##   viking retrieve
  ##   viking retrieve --output=./bescheide
  ##   viking retrieve --dry-run

  # Load and validate configuration
  var cfg: Config
  try:
    cfg = loadConfig(env)
  except IOError as e:
    echo &"Error: {e.msg}"
    return 1

  let errors = cfg.validate()
  if errors.len > 0:
    echo "Configuration errors:"
    for e in errors:
      echo &"  - {e}"
    echo ""
    echo "Please check your .env file."
    return 1

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

  # Build full XML for PostfachAnfrage
  let anfragXml = generatePostfachAnfrageXml(
    cfg.herstellerId, cfg.name, cfg.test,
  )

  if dryRun:
    echo "=== PostfachAnfrage XML ==="
    echo anfragXml
    echo "==========================="
    return 0

  # Open certificate
  let (certRc, certHandle) = ericGetHandleToCertificate(cfg.certPath)
  if certRc != 0:
    echo &"Error: Failed to open certificate with code {certRc}"
    echo &"  {ericHoleFehlerText(certRc)}"
    return 1
  defer: discard ericCloseHandleToCertificate(certHandle)

  var cryptParam: EricVerschluesselungsParameterT
  cryptParam.version = 3
  cryptParam.zertifikatHandle = certHandle
  cryptParam.pin = cfg.certPin.cstring

  let modeStr = if cfg.test: " (TEST)" else: ""
  echo &"=== Datenabholung{modeStr} ==="
  echo ""

  echo "Fetching Postfach..."

  var transferHandle: uint32 = 0

  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    echo "Error: Failed to create return buffers"
    return 1
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  let rc = ericBearbeiteVorgang(
    anfragXml,
    "PostfachAnfrage_31",
    ERIC_VALIDIERE or ERIC_SENDE,
    nil,
    addr cryptParam,
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
    return 1

  echo "  OK"

  if serverResponse.len == 0:
    echo ""
    echo "No data returned from server."
    return 0

  if verbose:
    echo ""
    echo "=== Server Response ==="
    echo serverResponse
    echo "======================="

  # Parse PostfachAnfrage response
  var xmlDoc: XmlNode
  try:
    xmlDoc = parseXml(serverResponse)
  except:
    echo "Error: Failed to parse server response XML"
    echo serverResponse
    return 1

  let bereitstellungen = parsePostfachAntwort(xmlDoc)

  # Display summary
  echo ""
  if bereitstellungen.len == 0:
    echo "No documents available for download."
    return 0

  echo &"Found {bereitstellungen.len} document(s):"
  for b in bereitstellungen:
    let vz = if b.veranlagungszeitraum.len > 0: " " & b.veranlagungszeitraum else: ""
    let bd = if b.bescheiddatum.len > 0:
      let d = b.bescheiddatum
      if d.len == 8: " vom " & d[6..7] & "." & d[4..5] & "." & d[0..3]
      else: " vom " & d
    else: ""
    echo &"  {b.datenart}{vz}{bd}"
    for a in b.anhaenge:
      echo &"    - {a.dateibezeichnung} ({a.dateityp}, {a.dateiGroesse} bytes)"
      echo &"      OTTER ID: {a.dateiReferenzId}"

  # Determine output directory
  let outDir = if output.len > 0: output else: "."
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
      echo "  Run 'viking retrieve' again to retry confirmation."
    else:
      echo &"  OK - confirmed {confirmedIds.len} document(s)"

  echo ""
  if downloadErrors > 0:
    echo &"Retrieval complete with {downloadErrors} error(s)."
  else:
    echo "Retrieval complete."
  return 0

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
    [est,
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
    [ust,
      help = {
        "invoiceFile": "CSV/TSV invoice file (positive=revenue, negative=expenses)",
        "vorauszahlungen": "Total UStVA advance payments made during the year",
        "year": "Tax year (default: current year)",
        "validateOnly": "Only validate, don't send",
        "dryRun": "Show generated XML without processing",
        "verbose": "Show full server response XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "invoiceFile": 'i',
        "vorauszahlungen": 'a',
        "year": 'y',
        "validateOnly": 'v',
        "dryRun": 'd',
        "verbose": 'V',
        "env": 'e',
      }
    ],
    [retrieve,
      help = {
        "output": "Output directory for downloaded files (default: current dir)",
        "dryRun": "Show generated XML without sending",
        "verbose": "Show full server response and confirmation XML",
        "env": "Path to env file (default: .env)",
      },
      short = {
        "output": 'o',
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
