## viking - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options, os]
import cligen, cligen/argcvt
import dotenv
import config, eric_ffi, ustva_xml, eric_setup

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
  period: string = "",
  year: int = 0,
  validateOnly: bool = false,
  dryRun: bool = false,
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

  # At least one amount should be specified
  if amount19.isNone and amount7.isNone:
    echo "Error: At least one of --amount19 or --amount7 must be specified"
    return 1

  # Load and validate configuration
  let cfg = loadConfig()
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
  let amt19 = amount19.get(0.0)
  let amt7 = amount7.get(0.0)

  # Generate XML
  let xml = generateUstva(
    steuernummer = cfg.steuernummer,
    jahr = actualYear,
    zeitraum = period,
    kz81 = amount19,
    kz86 = amount7,
    herstellerId = cfg.herstellerId,
    produktName = cfg.produktName,
    name = cfg.name,
    strasse = cfg.strasse,
    plz = cfg.plz,
    ort = cfg.ort,
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
  if amount19.isSome:
    echo &"Kz81 (19%):  {amt19:.2f} EUR (base) -> {vat19:.2f} EUR VAT"
  if amount7.isSome:
    echo &"Kz86 (7%):   {amt7:.2f} EUR (base) -> {vat7:.2f} EUR VAT"
  echo &"Kz83 (total): {totalVat:.2f} EUR"
  echo ""

  if validateOnly:
    echo "Mode: Validate only"
  else:
    echo "Mode: Send to ELSTER"
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
      echo &"Transfer handle: {transferHandle}"

    if serverResponse.len > 0:
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
      echo "Hint: XML schema validation failed. Check /tmp/eric_logs/eric.log for details."
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

proc fetch(file: string = "", check: bool = false): int =
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

  # Load .env so VIKING_CACHE_DIR is available
  if fileExists(getCurrentDir() / ".env"):
    load()

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
        "period": "Period: 01-12 (monthly) or 41-44 (quarterly)",
        "year": "Tax year (default: current year)",
        "validateOnly": "Only validate, don't send",
        "dryRun": "Show generated XML without processing",
      },
      short = {
        "amount19": '1',
        "amount7": '7',
        "period": 'p',
        "year": 'y',
        "validateOnly": 'v',
        "dryRun": 'd',
      }
    ],
    [fetch,
      help = {
        "file": "Path to local ERiC archive (JAR/ZIP/tar.gz)",
        "check": "Check existing ERiC installation in cache",
      },
      short = {
        "file": 'f',
        "check": 'c',
      }
    ]
  )
