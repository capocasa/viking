## Configuration module
## Loads configuration from .env file

import std/[os, osproc, strutils, tables]
import dotenv

type
  Config* = object
    ericLibPath*: string
    ericPluginPath*: string
    ericLogPath*: string
    certPath*: string
    certPin*: string
    steuernummer*: string
    herstellerId*: string
    produktName*: string
    name*: string
    strasse*: string
    plz*: string
    ort*: string
    test*: bool
    rechtsform*: string
    einkunftsart*: string
    vorname*: string
    nachname*: string
    geburtsdatum*: string
    hausnummer*: string
    iban*: string
    idnr*: string
    religion*: string
    beruf*: string
    krankenversicherung*: float
    pflegeversicherung*: float
    rentenversicherung*: float
    kvArt*: string
    besteuerungsart*: string
    # Additional Vorsorgeaufwand
    zusatzKv*: float
    kfzHaftpflicht*: float
    unfallversicherung*: float
    # Sonderausgaben
    kirchensteuerGezahlt*: float
    kirchensteuerErstattet*: float
    spenden*: float
    # Außergewöhnliche Belastungen
    agbKrankheit*: float
    # Anlage KAP
    kapitalertraege*: float
    kapitalertragsteuer*: float
    kapSoli*: float
    sparerPauschbetrag*: float
    guenstigerpruefung*: bool
    # ESt-specific Steuernummer
    estSteuernummer*: string

proc loadConfig*(envFile: string = ".env"): Config =
  ## Load configuration from env file

  let path = if envFile.isAbsolute: envFile
             else: getCurrentDir() / envFile
  if fileExists(path):
    load(path.parentDir, path.extractFilename)
  else:
    if envFile != ".env":
      raise newException(IOError, "Config file not found: " & path)

  result.ericLibPath = getEnv("ERIC_LIB_PATH", "")
  result.ericPluginPath = getEnv("ERIC_PLUGIN_PATH", "")
  result.ericLogPath = getEnv("ERIC_LOG_PATH", "/tmp/eric_logs")
  result.certPath = getEnv("CERT_PATH", "")
  let certPinCmd = getEnv("CERT_PIN_CMD", "")
  if certPinCmd != "":
    let (output, exitCode) = execCmdEx(certPinCmd)
    if exitCode != 0:
      raise newException(IOError, "CERT_PIN_CMD failed (exit " & $exitCode & "): " & output.strip)
    result.certPin = output.strip
  else:
    result.certPin = getEnv("CERT_PIN", "")
  result.steuernummer = getEnv("STEUERNUMMER", "")
  result.herstellerId = getEnv("HERSTELLER_ID", "40036")
  result.produktName = getEnv("PRODUKT_NAME", "Viking")
  result.name = getEnv("DATENLIEFERANT_NAME", "")
  result.strasse = getEnv("DATENLIEFERANT_STRASSE", "")
  result.plz = getEnv("DATENLIEFERANT_PLZ", "")
  result.ort = getEnv("DATENLIEFERANT_ORT", "")
  result.test = getEnv("TEST", "0") == "1"
  result.rechtsform = getEnv("RECHTSFORM", "")
  result.einkunftsart = getEnv("EINKUNFTSART", "")
  result.vorname = getEnv("VORNAME", "")
  result.nachname = getEnv("NACHNAME", "")
  result.geburtsdatum = getEnv("GEBURTSDATUM", "")
  result.hausnummer = getEnv("HAUSNUMMER", "")
  result.iban = getEnv("IBAN", "")
  result.idnr = getEnv("IDNR", "")
  result.religion = getEnv("RELIGION", "11")
  result.beruf = getEnv("BERUF", "")
  let kvStr = getEnv("KRANKENVERSICHERUNG", "0")
  try: result.krankenversicherung = parseFloat(kvStr)
  except ValueError: discard
  let pvStr = getEnv("PFLEGEVERSICHERUNG", "0")
  try: result.pflegeversicherung = parseFloat(pvStr)
  except ValueError: discard
  let rvStr = getEnv("RENTENVERSICHERUNG", "0")
  try: result.rentenversicherung = parseFloat(rvStr)
  except ValueError: discard
  result.kvArt = getEnv("KV_ART", "privat")
  result.besteuerungsart = getEnv("BESTEUERUNGSART", "2")
  # Additional Vorsorgeaufwand
  let zkStr = getEnv("ZUSATZ_KV", "0")
  try: result.zusatzKv = parseFloat(zkStr)
  except ValueError: discard
  let kfzStr = getEnv("KFZ_HAFTPFLICHT", "0")
  try: result.kfzHaftpflicht = parseFloat(kfzStr)
  except ValueError: discard
  let uvStr = getEnv("UNFALLVERSICHERUNG", "0")
  try: result.unfallversicherung = parseFloat(uvStr)
  except ValueError: discard
  # Sonderausgaben
  let kstGStr = getEnv("KIRCHENSTEUER_GEZAHLT", "0")
  try: result.kirchensteuerGezahlt = parseFloat(kstGStr)
  except ValueError: discard
  let kstEStr = getEnv("KIRCHENSTEUER_ERSTATTET", "0")
  try: result.kirchensteuerErstattet = parseFloat(kstEStr)
  except ValueError: discard
  let spStr = getEnv("SPENDEN", "0")
  try: result.spenden = parseFloat(spStr)
  except ValueError: discard
  # Außergewöhnliche Belastungen
  let agbStr = getEnv("AGB_KRANKHEITSKOSTEN", "0")
  try: result.agbKrankheit = parseFloat(agbStr)
  except ValueError: discard
  # Anlage KAP
  let keStr = getEnv("KAPITALERTRAEGE", "0")
  try: result.kapitalertraege = parseFloat(keStr)
  except ValueError: discard
  let kestStr = getEnv("KAPITALERTRAGSTEUER", "0")
  try: result.kapitalertragsteuer = parseFloat(kestStr)
  except ValueError: discard
  let soliStr = getEnv("KAP_SOLI", "0")
  try: result.kapSoli = parseFloat(soliStr)
  except ValueError: discard
  let spPbStr = getEnv("SPARER_PAUSCHBETRAG", "0")
  try: result.sparerPauschbetrag = parseFloat(spPbStr)
  except ValueError: discard
  result.guenstigerpruefung = getEnv("GUENSTIGERPRUEFUNG", "0") == "1"
  # ESt-specific Steuernummer
  result.estSteuernummer = getEnv("EST_STEUERNUMMER", "")

proc validate*(cfg: Config): seq[string] =
  ## Validate configuration and return list of errors
  result = @[]

  if cfg.ericLibPath == "":
    result.add("ERIC_LIB_PATH not set")
  elif not fileExists(cfg.ericLibPath):
    result.add("ERIC_LIB_PATH does not exist: " & cfg.ericLibPath)

  if cfg.ericPluginPath == "":
    result.add("ERIC_PLUGIN_PATH not set")
  elif not dirExists(cfg.ericPluginPath):
    result.add("ERIC_PLUGIN_PATH directory does not exist: " & cfg.ericPluginPath)

  if cfg.certPath == "":
    result.add("CERT_PATH not set")
  elif not fileExists(cfg.certPath):
    result.add("CERT_PATH does not exist: " & cfg.certPath)

  if cfg.certPin == "":
    result.add("CERT_PIN not set")

  if cfg.steuernummer == "":
    result.add("STEUERNUMMER not set")

proc validateForSubmission*(cfg: Config): seq[string] =
  ## Full validation for actual submission
  result = cfg.validate()

  if cfg.name == "":
    result.add("DATENLIEFERANT_NAME not set (sender name)")
  if cfg.strasse == "":
    result.add("DATENLIEFERANT_STRASSE not set (sender street)")
  if cfg.plz == "":
    result.add("DATENLIEFERANT_PLZ not set (sender postal code)")
  if cfg.ort == "":
    result.add("DATENLIEFERANT_ORT not set (sender city)")

proc validateForValidateOnly*(cfg: Config): seq[string] =
  ## Minimal validation for validate-only mode (no cert needed)
  result = @[]

  if cfg.ericLibPath == "":
    result.add("ERIC_LIB_PATH not set")
  elif not fileExists(cfg.ericLibPath):
    result.add("ERIC_LIB_PATH does not exist: " & cfg.ericLibPath)

  if cfg.ericPluginPath == "":
    result.add("ERIC_PLUGIN_PATH not set")
  elif not dirExists(cfg.ericPluginPath):
    result.add("ERIC_PLUGIN_PATH directory does not exist: " & cfg.ericPluginPath)

  if cfg.steuernummer == "":
    result.add("STEUERNUMMER not set")

const BundeslandMap = {
  "10": "BE", "11": "BB",
  "21": "NI", "22": "SH", "23": "HH", "24": "HB",
  "26": "MV", "27": "MV", "28": "ST",
  "30": "SN", "31": "TH",
  "32": "NW", "33": "NW",
  "40": "HE", "41": "HE",
  "42": "RP", "43": "RP", "44": "RP",
  "45": "SL", "46": "SL",
  "50": "BW", "51": "BW", "52": "BW", "53": "BW", "54": "BW", "55": "BW",
  "91": "BY", "92": "BY",
}.toTable

proc bundeslandFromSteuernummer*(stnr: string): string =
  ## Map the first 2 digits of a 13-digit Steuernummer to a Bundesland code.
  if stnr.len < 2:
    return ""
  let prefix = stnr[0..1]
  if prefix in BundeslandMap:
    return BundeslandMap[prefix]
  return ""

proc validateForEuerSubmission*(cfg: Config): seq[string] =
  ## Full validation for EÜR submission
  result = cfg.validateForSubmission()

  if cfg.rechtsform == "":
    result.add("RECHTSFORM not set (legal form, e.g. 1=Einzelunternehmen)")
  if cfg.einkunftsart == "":
    result.add("EINKUNFTSART not set (income type, e.g. 1=Gewerbebetrieb)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])

proc validateForEuerValidateOnly*(cfg: Config): seq[string] =
  ## Minimal validation for EÜR validate-only mode
  result = cfg.validateForValidateOnly()

  if cfg.rechtsform == "":
    result.add("RECHTSFORM not set (legal form, e.g. 1=Einzelunternehmen)")
  if cfg.einkunftsart == "":
    result.add("EINKUNFTSART not set (income type, e.g. 1=Gewerbebetrieb)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])

proc validateForEstSubmission*(cfg: Config): seq[string] =
  ## Full validation for ESt submission
  result = cfg.validateForSubmission()

  if cfg.vorname == "":
    result.add("VORNAME not set (first name)")
  if cfg.nachname == "":
    result.add("NACHNAME not set (last name)")
  if cfg.geburtsdatum == "":
    result.add("GEBURTSDATUM not set (date of birth, DD.MM.YYYY)")
  if cfg.iban == "":
    result.add("IBAN not set (bank account for refund/payment)")
  if cfg.einkunftsart == "":
    result.add("EINKUNFTSART not set (2=Gewerbebetrieb, 3=Selbstaendige Arbeit)")
  elif cfg.einkunftsart != "2" and cfg.einkunftsart != "3":
    result.add("EINKUNFTSART must be 2 (Gewerbebetrieb) or 3 (Selbstaendige Arbeit)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])
  if cfg.kvArt != "privat" and cfg.kvArt != "gesetzlich":
    result.add("KV_ART must be 'privat' or 'gesetzlich'")

proc validateForUstSubmission*(cfg: Config): seq[string] =
  ## Full validation for annual USt submission
  result = cfg.validateForSubmission()
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])
  if cfg.besteuerungsart != "1" and cfg.besteuerungsart != "2" and cfg.besteuerungsart != "3":
    result.add("BESTEUERUNGSART must be 1, 2 or 3 (1=vereinbart, 2=vereinnahmt, 3=mixed)")

proc validateForUstValidateOnly*(cfg: Config): seq[string] =
  ## Minimal validation for annual USt validate-only mode
  result = cfg.validateForValidateOnly()
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])
  if cfg.besteuerungsart != "1" and cfg.besteuerungsart != "2" and cfg.besteuerungsart != "3":
    result.add("BESTEUERUNGSART must be 1, 2 or 3 (1=vereinbart, 2=vereinnahmt, 3=mixed)")

proc validateForNachrichtSubmission*(cfg: Config): seq[string] =
  ## Full validation for SonstigeNachricht submission
  result = cfg.validateForSubmission()
  if cfg.hausnummer == "":
    result.add("HAUSNUMMER not set (house number)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])

proc validateForNachrichtValidateOnly*(cfg: Config): seq[string] =
  ## Minimal validation for SonstigeNachricht validate-only mode
  result = cfg.validateForValidateOnly()
  if cfg.name == "":
    result.add("DATENLIEFERANT_NAME not set (sender name)")
  if cfg.strasse == "":
    result.add("DATENLIEFERANT_STRASSE not set (sender street)")
  if cfg.plz == "":
    result.add("DATENLIEFERANT_PLZ not set (sender postal code)")
  if cfg.ort == "":
    result.add("DATENLIEFERANT_ORT not set (sender city)")
  if cfg.hausnummer == "":
    result.add("HAUSNUMMER not set (house number)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])

proc validateForEstValidateOnly*(cfg: Config): seq[string] =
  ## Minimal validation for ESt validate-only mode
  result = cfg.validateForValidateOnly()

  if cfg.vorname == "":
    result.add("VORNAME not set (first name)")
  if cfg.nachname == "":
    result.add("NACHNAME not set (last name)")
  if cfg.geburtsdatum == "":
    result.add("GEBURTSDATUM not set (date of birth, DD.MM.YYYY)")
  if cfg.iban == "":
    result.add("IBAN not set (bank account for refund/payment)")
  if cfg.einkunftsart == "":
    result.add("EINKUNFTSART not set (2=Gewerbebetrieb, 3=Selbstaendige Arbeit)")
  elif cfg.einkunftsart != "2" and cfg.einkunftsart != "3":
    result.add("EINKUNFTSART must be 2 (Gewerbebetrieb) or 3 (Selbstaendige Arbeit)")
  if cfg.steuernummer.len >= 2 and bundeslandFromSteuernummer(cfg.steuernummer) == "":
    result.add("Cannot determine Bundesland from STEUERNUMMER prefix: " & cfg.steuernummer[0..1])

