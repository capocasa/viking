## Logging module
## Logs to ~/.local/share/viking/YEAR.log and optionally to stdout.

import std/[os, strformat, times]

var logFile: File
var logPath*: string
var verbose*: bool = false

proc initLog*(year: int = now().year) =
  ## Open log file for the given year. Creates data dir if needed.
  let dataDir = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "viking"
  createDir(dataDir)
  logPath = dataDir / &"{year}.log"
  logFile = open(logPath, fmAppend)
  let ts = now().format("yyyy-MM-dd HH:mm:ss")
  logFile.writeLine(&"--- {ts} ---")
  logFile.flushFile()

proc closeLog*() =
  if logFile != nil:
    logFile.close()

proc log*(msg: string) =
  ## Write to log file. Also to stdout if verbose.
  if logFile != nil:
    logFile.writeLine(msg)
    logFile.flushFile()
  if verbose:
    echo msg

proc err*(msg: string) =
  ## Write to log file and stderr.
  if logFile != nil:
    logFile.writeLine("ERROR: " & msg)
    logFile.flushFile()
  stderr.writeLine(msg)
