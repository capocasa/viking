## taxmeklaus - German VAT advance return (Umsatzsteuervoranmeldung) CLI
## Submit UStVA via ERiC library

import std/[strutils, strformat, times, options]
import cligen, cligen/argcvt
import config, eric_ffi, ustva_xml

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
  ##   taxmeklaus --amount19=1000.00 --period=01 --year=2025
  ##   taxmeklaus --amount19=1000 --amount7=500 --period=41 --year=2025
  ##   taxmeklaus --amount19=100 --period=01 --validate-only

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
  )

  # Load ERiC library
  if not loadEricLib(cfg.ericLibPath):
    echo &"Error: Failed to load ERiC library from {cfg.ericLibPath}"
    return 1
  defer: unloadEricLib()

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
    let (certRc, handle) = ericCreateTH(cfg.certPath, cfg.certPin)
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
      discard ericCloseHandleTH(certHandle)

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
  let rc = ericBearbeiteVorgang(
    xml,
    "",  # datenartVersion - empty for auto-detection
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
  dispatch(submit,
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
  )
