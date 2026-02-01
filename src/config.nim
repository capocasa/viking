## Configuration module
## Loads configuration from .env file

import std/os
import dotenv

type
  Config* = object
    ericLibPath*: string
    ericPluginPath*: string
    ericLogPath*: string
    certPath*: string
    certPin*: string
    steuernummer*: string

proc loadConfig*(): Config =
  ## Load configuration from .env file

  # Try to load .env file from current directory
  let envPath = getCurrentDir() / ".env"
  if fileExists(envPath):
    load()

  result.ericLibPath = getEnv("ERIC_LIB_PATH", "")
  result.ericPluginPath = getEnv("ERIC_PLUGIN_PATH", "")
  result.ericLogPath = getEnv("ERIC_LOG_PATH", "/tmp/eric_logs")
  result.certPath = getEnv("CERT_PATH", "")
  result.certPin = getEnv("CERT_PIN", "")
  result.steuernummer = getEnv("STEUERNUMMER", "")

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

