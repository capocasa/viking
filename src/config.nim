## Configuration module
## Loads configuration from .env file

import std/[os, osproc, strutils, tables, math]
import dotenv

const HerstellerId* = "40036"
const ProduktName* = "Viking"

proc roundCents*(val: float): float =
  ## Round to 2 decimal places (cents)
  round(val * 100) / 100

proc roundEuro*(val: float): int =
  ## Round to nearest whole euro
  int(round(val))

proc formatEurDE*(val: float): string =
  ## Format amount for ELSTER XML: German locale with comma decimal separator.
  let s = formatFloat(roundCents(val), ffDecimal, 2)
  s.replace('.', ',')

type
  Config* = object
    ericLibPath*: string
    ericPluginPath*: string
    ericLogPath*: string
    certPath*: string
    certPin*: string
    test*: bool

proc loadConfig*(envFile: string = ".env"): Config =
  ## Load configuration from env file

  let path = if envFile.isAbsolute: envFile
             else: getCurrentDir() / envFile
  if fileExists(path):
    load(path.parentDir, path.extractFilename)
  else:
    if envFile != ".env":
      raise newException(IOError, "Config file not found: " & path)

  # XDG defaults for ERiC paths
  let xdgDataDir = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
  let defaultEricBase = xdgDataDir / "viking" / "eric"
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
  result.test = getEnv("TEST", "0") == "1"

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


