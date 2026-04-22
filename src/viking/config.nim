## Technical configuration and arithmetic helpers.
##
## `Config` carries the resolved ERiC paths (derived from the data dir) plus
## the `--test` flag. Personal/business data lives in `vikingconf` instead;
## signing credentials in its `[auth]` section. Also exposes the
## German-locale money formatters (`roundCents`, `roundEuro`, `formatEurDE`)
## and the Steuernummer→Bundesland map used by every form generator.

import std/[os, strutils, tables, math]
import ericsetup

const HerstellerId* = "40036"
const ProduktName* = "Viking"

const
  StartYear = "2025"
  CurrentYear = CompileDate[0 .. 3]
  Copyright* =
    if CurrentYear == StartYear: "(c) " & StartYear & " viking contributors"
    else: "(c) " & StartYear & "-" & CurrentYear & " viking contributors"
    ## Rendered into the ELSTER `<Copyright>` field (which ERiC drops into
    ## the PDF footer). End year floats with the build date. ASCII only —
    ## ELSTER rejects `©` and non-ASCII dashes with `ZeichenNichtImZeichensatz`.

func roundCents*(val: float): float =
  ## Round to 2 decimal places (cents)
  round(val * 100) / 100

func roundEuro*(val: float): int =
  ## Round to nearest whole euro
  int(round(val))

func formatEurDE*(val: float): string =
  ## Format amount for ELSTER XML: German locale with comma decimal separator.
  let s = formatFloat(roundCents(val), ffDecimal, 2)
  s.replace('.', ',')

type
  Config* = object
    dataDir*: string
    ericLibPath*: string
    ericPluginPath*: string
    ericLogPath*: string
    test*: bool

proc loadConfig*(dataDir: string, test: bool): Config =
  ## Derive ERiC paths from the data dir; carry the --test flag through.
  result.dataDir = if dataDir != "": dataDir else: getAppDataDir()
  result.test = test
  result.ericLogPath = result.dataDir / "logs"
  let installation = findExistingEric(result.dataDir / "eric")
  if installation.valid:
    result.ericLibPath = installation.libPath / EricApiLib
    result.ericPluginPath = installation.pluginPath

proc validate*(cfg: Config): seq[string] =
  ## Verify ERiC is installed.
  if cfg.ericLibPath == "" or not fileExists(cfg.ericLibPath) or
     cfg.ericPluginPath == "" or not dirExists(cfg.ericPluginPath):
    result.add("ERiC not installed in " & (cfg.dataDir / "eric") &
               " — run 'viking fetch'")

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

func bundeslandFromSteuernummer*(stnr: string): string =
  ## Map the first 2 digits of a 13-digit Steuernummer to a Bundesland code.
  if stnr.len < 2:
    return ""
  let prefix = stnr[0..1]
  if prefix in BundeslandMap:
    return BundeslandMap[prefix]
  return ""
