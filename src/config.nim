## Configuration module
## Loads configuration from .env file

import std/[os, tables]
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

