## End-to-end sandbox tests for viking
## Requires: ERiC library + test certificates in test/cache (run `viking fetch` first)

import std/[osproc, strutils, os, algorithm]
import viking/ericsetup

when defined(windows):
  const Viking = "viking.exe"
else:
  const Viking = "./viking"

var failures = 0
var passes = 0

proc check(name: string, ok: bool, detail: string = "") =
  if ok:
    inc passes
    echo "  PASS: ", name
  else:
    inc failures
    echo "  FAIL: ", name
    if detail.len > 0:
      echo "        ", detail

proc run(cmd: string): tuple[output: string, code: int] =
  let (output, code) = execCmdEx(cmd)
  (output.strip, code)


# Ensure we're in the project root
let projectRoot = currentSourcePath().parentDir.parentDir
setCurrentDir(projectRoot)

echo "=== viking end-to-end tests ==="
echo "Working directory: ", getCurrentDir()
echo ""

# Isolate tests from user's global config: point XDG_CONFIG_HOME elsewhere
let testXdgHome = projectRoot / "tests" / "tmp_xdg"
createDir(testXdgHome)
putEnv("XDG_CONFIG_HOME", testXdgHome)

# Test cert fixture — install with:
#   wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
#   unzip -d <data-dir>/certificates Test_Zertifikate.zip
let testCertPath = getAppDataDir() / "certificates" / "test-softorg-pse.pfx"
let testCertAvailable = fileExists(testCertPath)

# Shared pin file used by every test viking.conf via [auth] pin=.
let testPinPath = projectRoot / "tests" / "tmp_viking.pin"
writeFile(testPinPath, "123456")

proc authBlock(): string =
  ## Append this to test viking.conf content to wire up cert+pin.
  "\n[auth]\ncert = " & testCertPath & "\npin = " & testPinPath & "\n"

proc writeConf(path, body: string) =
  ## writeFile + append [auth] section.
  writeFile(path, body & authBlock())

# --- Prerequisite check ---
echo "--- Prerequisites ---"

let binaryExists = fileExists(Viking)
check("viking binary exists", binaryExists)
if not binaryExists:
  echo "Build with `nimble build` first."
  quit(1)

var (fetchCheck, fetchCheckRc) = run(Viking & " fetch --check")
var ericInstalled = fetchCheckRc == 0
if not ericInstalled:
  echo "  ERiC not found, downloading..."
  let (_, fetchRc) = run(Viking & " fetch")
  if fetchRc == 0:
    (fetchCheck, fetchCheckRc) = run(Viking & " fetch --check")
    ericInstalled = fetchCheckRc == 0
check("ERiC installation found", ericInstalled)
if not ericInstalled:
  echo "  Could not set up ERiC automatically."
  echo "  Run `viking fetch` for details."
  quit(1)
echo ""

# --- Fetch command ---
echo "--- fetch ---"
check("fetch --check succeeds", fetchCheckRc == 0)
check("fetch --check shows version", fetchCheck.contains("ERiC"))
echo ""

# Shared template fragments used across tests
const personalBlock = """[Hans Maier]
geburtsdatum = 05.05.1955
idnr         = 04452397687
steuernr     = 9198011310010
strasse      = Musterstr.
nr           = 1
plz          = 10115
ort          = Berlin
iban         = DE91100000000123456789
religion     = 11
beruf        = Software-Entwickler
"""

# viking.conf for submit tests (single freiberuf source)
let submitConf = projectRoot / "tests" / "tmp_submit_viking.conf"
writeConf(submitConf, personalBlock & """
[freiberuf]
versteuerung = 2
""")

# --- Submit: dry-run ---
echo "--- submit --dry-run ---"
let (dryOut, dryRc) = run(Viking & " submit --test -c " & submitConf & " --p 41 --amount19 1000 --dry-run")
check("dry-run exits 0", dryRc == 0, "exit code: " & $dryRc & "\n        " & dryOut)
check("dry-run has XML output", dryOut.contains("<?xml"))
check("dry-run shows XML", dryOut.contains("<Elster"))
check("dry-run XML has TransferHeader", dryOut.contains("<TransferHeader"))
check("dry-run XML has UStVA", dryOut.contains("<Umsatzsteuervoranmeldung>"))
check("dry-run XML has Kz81", dryOut.contains("<Kz81>1000</Kz81>"))
check("dry-run XML has Kz83 (VAT)", dryOut.contains("<Kz83>190.00</Kz83>"))
check("dry-run XML has Testmerker 700000004", dryOut.contains("<Testmerker>700000004</Testmerker>"))
check("dry-run XML has Empfaenger", dryOut.contains("""<Empfaenger id="F">9198</Empfaenger>"""))
echo ""

# --- Testmerker presence based on --test flag ---
echo "--- --test flag ---"
let (prodOut, prodRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 0 --dry-run")
check("production dry-run exits 0", prodRc == 0, prodOut)
check("production no Testmerker", not prodOut.contains("Testmerker"), prodOut)

let (testOut, testRc) = run(Viking & " submit --test -c " & submitConf & " --p 41 --amount19 0 --dry-run")
check("--test dry-run exits 0", testRc == 0, testOut)
check("--test has Testmerker", testOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

# --- Submit: dry-run with both rates ---
echo "--- submit --dry-run (19% + 7%) ---"
let (dryBoth, dryBothRc) = run(Viking & " submit -c " & submitConf & " --p 01 --amount19 500 --amount7 200 --dry-run")
check("dual-rate dry-run exits 0", dryBothRc == 0)
check("dual-rate has Kz81", dryBoth.contains("<Kz81>500</Kz81>"))
check("dual-rate has Kz86", dryBoth.contains("<Kz86>200</Kz86>"))
check("dual-rate has Kz83", dryBoth.contains("<Kz83>109.00</Kz83>"))
check("Kz83 before Kz86", dryBoth.find("<Kz83>") < dryBoth.find("<Kz86>"))
echo ""

# --- Submit: validate-only ---
echo "--- submit --validate-only ---"
let (valOut, valRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 0 --validate-only")
let schemaOk = not valOut.contains("610301200")
let certOk = not valOut.contains("610001050")
check("no XML schema errors", schemaOk, valOut)
check("no certificate errors", certOk, valOut)
let herstellerIdBlocked = valOut.contains("610301202")
if valRc == 0:
  check("validate-only succeeds", true)
elif herstellerIdBlocked:
  check("validate-only: only HerstellerID issue (expected with demo ID)", true)
else:
  check("validate-only: unexpected error", false, valOut)
echo ""

# --- Submit: full send path ---
echo "--- submit (send) ---"
let (sendOut, sendRc) = run(Viking & " submit --test -c " & submitConf & " --p 41 --amount19 0")
let sendSchemaOk = not sendOut.contains("610301200")
let sendCertOk = not sendOut.contains("610001050")
check("send: no XML schema errors", sendSchemaOk, sendOut)
check("send: no certificate errors", sendCertOk, sendOut)
let sendHidBlocked = sendOut.contains("610301202")
if sendRc == 0:
  check("send: succeeds", true)
elif sendHidBlocked:
  check("send: only HerstellerID issue (expected with demo ID)", true)
  check("send: shows actionable hint", sendOut.contains("HerstellerID"))
else:
  check("send: unexpected error", false, sendOut)
echo ""

# --- Per-year validation ---
echo "--- per-year validation (2025+) ---"
let installation = findExistingEric(getEricDataDir())
let pluginPath = installation.pluginPath
var years: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let uStVAPrefix = PluginPrefix & "UStVA_"
    if name.startsWith(uStVAPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[uStVAPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2025:
          years.add(y)
      except ValueError:
        discard
years.sort()

check("found UStVA plugins for 2025+", years.len > 0, "plugins in: " & pluginPath)

type RateCombo = object
  label: string
  args: string

let combos = @[
  RateCombo(label: "19% only", args: "--amount19 1000"),
  RateCombo(label: "7% only", args: "--amount7 500"),
  RateCombo(label: "0% only", args: "--amount0 800"),
  RateCombo(label: "19%+7%", args: "--amount19 1000 --amount7 500"),
  RateCombo(label: "19%+0%", args: "--amount19 1000 --amount0 800"),
  RateCombo(label: "all rates", args: "--amount19 1000 --amount7 500 --amount0 800"),
]

for year in years:
  for combo in combos:
    let cmd = Viking & " submit -c " & submitConf & " --p 41 " & combo.args & " --year " & $year & " --validate-only"
    let (comboOut, comboRc) = run(cmd)
    let schemaOk = not comboOut.contains("610301200")
    let hidBlocked = comboOut.contains("610301202")
    let comboOk = comboRc == 0 or hidBlocked
    let tag = $year & " " & combo.label
    check(tag & " schema valid", schemaOk, comboOut)
    if not comboOk:
      check(tag & " passes validation", false, comboOut)
echo ""

# --- Submit: input validation ---
echo "--- input validation ---"
let (noperiod, noperiodRc) = run(Viking & " submit -c " & submitConf & " --amount19 100")
check("missing --period is rejected", noperiodRc != 0)
check("missing --period shows error", noperiod.contains("--period is required"))

let (badperiod, badperiodRc) = run(Viking & " submit -c " & submitConf & " --p 99 --amount19 100")
check("invalid period is rejected", badperiodRc != 0)
check("invalid period shows error", badperiod.contains("Invalid period"))
check("invalid period lists words", badperiod.contains("jan") and badperiod.contains("q1"))
echo ""

# --- Alphanumeric aliases for period, income, rechtsform, besteuerungsart, religion ---
echo "--- alphanumeric aliases ---"
let (aliasQ1Out, aliasQ1Rc) = run(Viking & " submit -c " & submitConf & " --p q1 --amount19 100 --dry-run")
check("period q1 exits 0", aliasQ1Rc == 0, aliasQ1Out)
check("period q1 -> 41", aliasQ1Out.contains("<Zeitraum>41</Zeitraum>"))

let (aliasMarOut, aliasMarRc) = run(Viking & " submit -c " & submitConf & " --p mar --amount19 100 --dry-run")
check("period mar exits 0", aliasMarRc == 0, aliasMarOut)
check("period mar -> 03", aliasMarOut.contains("<Zeitraum>03</Zeitraum>"))

let (aliasPadOut, aliasPadRc) = run(Viking & " submit -c " & submitConf & " --p 3 --amount19 100 --dry-run")
check("unpadded period 3 exits 0", aliasPadRc == 0, aliasPadOut)
check("unpadded period 3 -> 03", aliasPadOut.contains("<Zeitraum>03</Zeitraum>"))

let wordConf = projectRoot / "tests" / "tmp_words.conf"
writeConf(wordConf, personalBlock.replace("religion     = 11", "religion     = rk") & """
[freelance]
rechtsform = einzel
versteuerung = ist
""")

# UStVA via words in conf
let (wordUstvaOut, wordUstvaRc) = run(Viking & " submit -c " & wordConf & " --p jan --amount19 100 --dry-run")
check("word-form conf accepted (submit)", wordUstvaRc == 0, wordUstvaOut)
check("word-form conf -> Zeitraum 01", wordUstvaOut.contains("<Zeitraum>01</Zeitraum>"))

# EÜR maps rechtsform=einzel -> 120 in XML
writeFile(projectRoot / "2025-freelance.tsv", "amount\trate\n1000\t19\n")
let (wordEuerOut, wordEuerRc) = run(Viking & " euer freelance -c " & wordConf & " --year 2025 --dry-run")
check("word-form euer exits 0", wordEuerRc == 0, wordEuerOut)
check("rechtsform einzel -> 120", wordEuerOut.contains("<E6000602>120</E6000602>"))

# USt maps besteuerungsart=ist -> 2 in XML
let (wordUstOut, wordUstRc) = run(Viking & " ust freelance -c " & wordConf & " --year 2025 --dry-run")
check("word-form ust exits 0", wordUstRc == 0, wordUstOut)
check("besteuerungsart ist -> 2", wordUstOut.contains("<E3002203>2</E3002203>"))

# ESt maps religion=rk -> 03 in XML
let (wordEstOut, wordEstRc) = run(Viking & " est -c " & wordConf & " --year 2025 --force --dry-run")
check("word-form est exits 0", wordEstRc == 0, wordEstOut)
check("religion rk -> 03", wordEstOut.contains("<E0100402>03</E0100402>"))

# Bad values mention the listing
let badConf = projectRoot / "tests" / "tmp_bad_codes.conf"
writeConf(badConf, personalBlock & """
[freelance]
rechtsform = zzz
versteuerung = ist
""")
let (badRfOut, badRfRc) = run(Viking & " submit -c " & badConf & " --p q1 --amount19 100 --dry-run")
check("bad rechtsform rejected", badRfRc != 0)
check("bad rechtsform lists words", badRfOut.contains("einzel") and badRfOut.contains("gmbh"))

# VAT rate accepts trailing %
writeFile(projectRoot / "tests" / "tmp_pct.tsv", "amount\trate\n1000\t19%\n500\t7%\n")
let (pctOut, pctRc) = run(Viking & " submit -c " & submitConf & " -i " &
  (projectRoot / "tests" / "tmp_pct.tsv") & " --p 01 --dry-run")
check("VAT rate 19% / 7% accepted", pctRc == 0, pctOut)
check("VAT 19% aggregated into Kz81", pctOut.contains("<Kz81>1000</Kz81>"))
check("VAT 7% aggregated into Kz86", pctOut.contains("<Kz86>500</Kz86>"))

removeFile(projectRoot / "2025-freelance.tsv")
removeFile(projectRoot / "tests" / "tmp_pct.tsv")
removeFile(wordConf)
removeFile(badConf)
echo ""

# --- Source auto-selection with multiple sources ---
echo "--- source selection ---"
let multiConf = projectRoot / "tests" / "tmp_multi.conf"
writeConf(multiConf, personalBlock & """
[freiberuf]
versteuerung = 2

[mygewerbe]
steuernr = 9198011310020
versteuerung = 2
""")

let (ambigOut, ambigRc) = run(Viking & " submit -c " & multiConf & " --p 41 --amount19 100 --dry-run")
check("multi-source without name rejected", ambigRc != 0)
check("multi-source error lists names", ambigOut.contains("freiberuf") and ambigOut.contains("mygewerbe"))

let (gewOut, gewRc) = run(Viking & " submit mygewerbe -c " & multiConf & " --p 41 --amount19 100 --dry-run")
check("explicit source exits 0", gewRc == 0, gewOut)
check("source override taxnumber used", gewOut.contains("<Steuernummer>9198011310020</Steuernummer>"))

let (freeOut, freeRc) = run(Viking & " submit freiberuf -c " & multiConf & " --p 41 --amount19 100 --dry-run")
check("other source uses personal taxnumber", freeOut.contains("<Steuernummer>9198011310010</Steuernummer>"))

let (unkOut, unkRc) = run(Viking & " submit bogus -c " & multiConf & " --p 41 --amount19 100 --dry-run")
check("unknown source rejected", unkRc != 0)
check("unknown source error", unkOut.contains("not found"))

removeFile(multiConf)
echo ""

# --- Invoice input ---
echo "--- invoice input (CSV) ---"
let invCsv = projectRoot / "tests" / "tmp_invoices.csv"

# Test 1: CSV with header + mixed rates + negative amount
writeFile(invCsv, "amount,rate,date,invoice-id,description\n1000,19,2026-01-15,INV-001,January sales\n500,7,2026-01-20,INV-002,Reduced rate\n-200,19,2026-01-25,CR-001,Credit note\n")
let (csvOut, csvRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("CSV mixed rates exits 0", csvRc == 0, csvOut)
check("CSV Kz81 = 800 (1000-200)", csvOut.contains("<Kz81>800</Kz81>"))
check("CSV Kz86 = 500", csvOut.contains("<Kz86>500</Kz86>"))
check("CSV Kz83 = 187.00", csvOut.contains("<Kz83>187.00</Kz83>"))
echo ""

# Test 2: TSV without header (auto-detect)
echo "--- invoice input (TSV) ---"
let invTsv = projectRoot / "tests" / "tmp_invoices.tsv"
writeFile(invTsv, "750\t19\n250\t7\n")
let (tsvOut, tsvRc) = run(Viking & " submit -c " & submitConf & " -i " & invTsv & " --p 01 --dry-run")
check("TSV auto-detect exits 0", tsvRc == 0, tsvOut)
check("TSV Kz81 = 750", tsvOut.contains("<Kz81>750</Kz81>"))
check("TSV Kz86 = 250", tsvOut.contains("<Kz86>250</Kz86>"))
removeFile(invTsv)
echo ""

# Test 3: Amount-only (single column, default rate 19%)
echo "--- invoice input (amount-only) ---"
writeFile(invCsv, "100\n200\n300\n")
let (amtOut, amtRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("amount-only exits 0", amtRc == 0, amtOut)
check("amount-only Kz81 = 600", amtOut.contains("<Kz81>600</Kz81>"))
check("amount-only no Kz86", not amtOut.contains("<Kz86>"))
echo ""

# Test 4: Mutual exclusivity (--invoices + --amount19 rejected)
echo "--- invoice mutual exclusivity ---"
writeFile(invCsv, "100\n")
let (mutexOut, mutexRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --amount19 100 --p 01 --dry-run")
check("mutex rejected", mutexRc != 0)
check("mutex shows error", mutexOut.contains("mutually exclusive"))
echo ""

# Test 5: Empty file -> zero submission
echo "--- invoice empty file ---"
writeFile(invCsv, "")
let (emptyOut, emptyRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("empty file exits 0", emptyRc == 0, emptyOut)
check("empty file has Kz81 = 0", emptyOut.contains("<Kz81>0</Kz81>"))
echo ""

# Test 6: Validation errors (bad amount, bad rate)
echo "--- invoice validation errors ---"
writeFile(invCsv, "100,19\nabc,19\n100,99\n")
let (valErrOut, valErrRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("validation errors rejected", valErrRc != 0)
check("bad amount reported", valErrOut.contains("line 2") and valErrOut.contains("invalid amount"))
check("bad rate reported", valErrOut.contains("line 3") and valErrOut.contains("invalid rate"))
echo ""

# Test: 0% rate (Kz45 - non-taxable)
echo "--- invoice 0% rate (Kz45) ---"
writeFile(invCsv, "1000,19\n500,0\n")
let (kz45Out, kz45Rc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("0% rate exits 0", kz45Rc == 0, kz45Out)
check("0% rate has Kz45 = 500", kz45Out.contains("<Kz45>500</Kz45>"))
check("0% rate has Kz81 = 1000", kz45Out.contains("<Kz81>1000</Kz81>"))
check("0% rate Kz83 excludes 0%", kz45Out.contains("<Kz83>190.00</Kz83>"))
echo ""

# Test: Period filtering
echo "--- invoice period filtering ---"
writeFile(invCsv, "amount,rate,date,invoice-id,description\n1000,19,2026-01-15,INV-001,Jan\n500,19,2026-02-10,INV-002,Feb\n300,7,2026-04-05,INV-003,Apr\n200,19,2026-06-20,INV-004,Jun\n")

let (q1Out, q1Rc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 41 -y 2026 --dry-run")
check("Q1 filter exits 0", q1Rc == 0, q1Out)
check("Q1 filter Kz81 = 1500", q1Out.contains("<Kz81>1500</Kz81>"))
check("Q1 filter no Kz86", not q1Out.contains("<Kz86>"))

let (q2Out, q2Rc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 42 -y 2026 --dry-run")
check("Q2 filter exits 0", q2Rc == 0, q2Out)
check("Q2 filter Kz81 = 200", q2Out.contains("<Kz81>200</Kz81>"))
check("Q2 filter Kz86 = 300", q2Out.contains("<Kz86>300</Kz86>"))

let (janOut, janRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 -y 2026 --dry-run")
check("Jan filter exits 0", janRc == 0, janOut)
check("Jan filter Kz81 = 1000", janOut.contains("<Kz81>1000</Kz81>"))
check("Jan filter only Jan invoices", not janOut.contains("<Kz86>"))

let (wrongYrOut, wrongYrRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 41 -y 2025 --dry-run")
check("wrong year filter exits 0", wrongYrRc == 0, wrongYrOut)
check("wrong year has Kz81 = 0", wrongYrOut.contains("<Kz81>0</Kz81>"))

writeFile(invCsv, "1000,19,2026-01-15,INV-001,dated\n500,19\n")
let (undatedOut, undatedRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 -y 2026 --dry-run")
check("undated filter exits 0", undatedRc == 0, undatedOut)
check("undated shows warning", undatedOut.contains("without date"))
check("undated Kz81 = 1000", undatedOut.contains("<Kz81>1000</Kz81>"))
echo ""

echo "--- invoice header-only ---"
writeFile(invCsv, "amount,rate,date\n")
let (hdrOut, hdrRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("header-only exits 0", hdrRc == 0, hdrOut)
check("header-only has Kz81 = 0", hdrOut.contains("<Kz81>0</Kz81>"))
echo ""

echo "--- invoice comments ---"
writeFile(invCsv, "# This is a comment\n100,19\n# Another comment\n200,7\n")
let (cmtOut, cmtRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("comments exits 0", cmtRc == 0, cmtOut)
check("comments Kz81 = 100", cmtOut.contains("<Kz81>100</Kz81>"))
check("comments Kz86 = 200", cmtOut.contains("<Kz86>200</Kz86>"))

removeFile(invCsv)
removeFile(submitConf)
echo ""

# =================================================================
# EÜR (Einnahmenüberschussrechnung) tests
# =================================================================

# viking.conf for EÜR tests (Gewerbe source)
let euerConf = projectRoot / "tests" / "tmp_euer_viking.conf"
writeConf(euerConf, personalBlock & """
[freelance]
versteuerung = 2
""")

# Use year-source TSV auto-discovery
let euerTsv = projectRoot / "tests" / "2025-freelance.tsv"

echo "--- euer --dry-run (income only) ---"
writeFile(euerTsv, "1000,19\n500,7\n")
let euerWd = projectRoot / "tests"
let (euerDryOut, euerDryRc) = run("cd " & euerWd & " && " & projectRoot / Viking & " euer freelance -c " & euerConf & " -y 2025 --dry-run")
check("euer dry-run exits 0", euerDryRc == 0, euerDryOut)
check("euer dry-run has XML output", euerDryOut.contains("<?xml"))
check("euer dry-run has E77 root", euerDryOut.contains("<E77"))
check("euer dry-run has EUER element", euerDryOut.contains("<EUER>"))
check("euer dry-run has ElsterErklaerung", euerDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("euer dry-run has DatenArt EUER", euerDryOut.contains("<DatenArt>EUER</DatenArt>"))
check("euer dry-run has Empfaenger Ziel", euerDryOut.contains("<Ziel>BY</Ziel>"))
check("euer dry-run has Unterfallart 77", euerDryOut.contains("<Unterfallart>77</Unterfallart>"))
check("euer dry-run has BEin", euerDryOut.contains("<BEin>"))
check("euer dry-run has BAus", euerDryOut.contains("<BAus>"))
echo ""

# --- EÜR: income/expense split ---
echo "--- euer income/expense split ---"
writeFile(euerTsv, "1000,19\n-300,19\n")
let (splitOut, splitRc) = run("cd " & euerWd & " && " & projectRoot / Viking & " euer freelance -c " & euerConf & " -y 2025 --dry-run")
check("split exits 0", splitRc == 0, splitOut)
check("split income net 1000", splitOut.contains("<E6000401>1000,00</E6000401>"))
check("split income VAT 190", splitOut.contains("<E6000601>190,00</E6000601>"))
check("split income total 1190", splitOut.contains("<E6001201>1190,00</E6001201>"))
check("split expense net 300", splitOut.contains("<E6004901>300,00</E6004901>"))
check("split expense Vorsteuer 57", splitOut.contains("<E6005001>57,00</E6005001>"))
check("split profit 833", splitOut.contains("<E6007202>833,00</E6007202>"))
echo ""

# --- EÜR: missing tsv ---
echo "--- euer missing tsv ---"
removeFile(euerTsv)
let (euerMissOut, euerMissRc) = run("cd " & euerWd & " && " & projectRoot / Viking & " euer freelance -c " & euerConf & " -y 2025 --dry-run")
check("euer missing tsv rejected", euerMissRc != 0)
check("euer missing tsv error", euerMissOut.contains("2025-freelance.tsv") or euerMissOut.contains("not found"))
echo ""

# --- EÜR: per-year validation ---
echo "--- euer per-year validation ---"
var euerYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let euerPrefix = PluginPrefix & "EUER_"
    if name.startsWith(euerPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[euerPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2025:
          euerYears.add(y)
      except ValueError:
        discard
euerYears.sort()

check("found EUER plugins for 2025+", euerYears.len > 0, "plugins in: " & pluginPath)
for year in euerYears:
  let ey = euerWd / ($year & "-freelance.tsv")
  writeFile(ey, "1000,19\n-500,19\n")
  let (eyOut, eyRc) = run("cd " & euerWd & " && " & projectRoot / Viking & " euer freelance -c " & euerConf & " -y " & $year & " --validate-only")
  let eySchemaOk = not eyOut.contains("610301200")
  let eyCertOk = not eyOut.contains("610001050")
  let eyHidBlocked = eyOut.contains("610301202")
  let eyOk = eyRc == 0 or eyHidBlocked
  check("euer " & $year & " schema valid", eySchemaOk, eyOut)
  check("euer " & $year & " no cert errors", eyCertOk, eyOut)
  if eyOk:
    check("euer " & $year & " passes validation", true)
  else:
    check("euer " & $year & " passes validation", false, eyOut)
  removeFile(ey)
echo ""

removeFile(euerConf)
echo ""

# =================================================================
# ESt (Einkommensteuererklarung) tests
# =================================================================

let estWd = projectRoot / "tests"

# Base conf: Anlage G (Gewerbe) via named source
let estConf = projectRoot / "tests" / "tmp_viking.conf"
writeConf(estConf, personalBlock & """
[mybiz]
versteuerung = 2
""")

let estTsv = estWd / "2025-mybiz.tsv"

# --- ESt: dry-run with Anlage G ---
echo "--- est --dry-run (Anlage G) ---"
writeFile(estTsv, "1000,19\n-300,19\n")
let (estDryOut, estDryRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est --test -c " & estConf & " -y 2025 --dry-run --force")
check("est dry-run exits 0", estDryRc == 0, estDryOut)
check("est dry-run has XML output", estDryOut.contains("<?xml"))
check("est dry-run has E10 root", estDryOut.contains("<E10"))
check("est dry-run has ESt1A", estDryOut.contains("<ESt1A>"))
check("est dry-run has Vorsatz", estDryOut.contains("<Vorsatz>"))
check("est dry-run has ElsterErklaerung", estDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("est dry-run has DatenArt ESt", estDryOut.contains("<DatenArt>ESt</DatenArt>"))
check("est dry-run has Empfaenger Ziel", estDryOut.contains("<Ziel>BY</Ziel>"))
check("est dry-run has Unterfallart 10", estDryOut.contains("<Unterfallart>10</Unterfallart>"))
check("est dry-run has Anlage G", estDryOut.contains("<G>"))
check("est dry-run has profit 833", estDryOut.contains("<E0800302>833</E0800302>"))
check("est dry-run has IBAN", estDryOut.contains("<E0102102>"))
check("est dry-run has Testmerker", estDryOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

# --- ESt: Anlage S ---
echo "--- est Anlage S ---"
let estConfS = projectRoot / "tests" / "tmp_viking_s.conf"
writeConf(estConfS, personalBlock & """
[freiberuf]
versteuerung = 2
""")
let estSTsv = estWd / "2025-freiberuf.tsv"
writeFile(estSTsv, "1000,19\n-300,19\n")
let (estSOut, estSRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConfS & " -y 2025 --dry-run --force")
check("est Anlage S exits 0", estSRc == 0, estSOut)
check("est Anlage S has <S>", estSOut.contains("<S>"))
check("est Anlage S has E0803202", estSOut.contains("<E0803202>833</E0803202>"))
check("est Anlage S no <G>", not estSOut.contains("<G>"))
removeFile(estConfS)
removeFile(estSTsv)
echo ""

# --- ESt: Vorsorgeaufwand (privat) ---
echo "--- est Vorsorgeaufwand (privat) ---"
let estVorDed = projectRoot / "tests" / "tmp_deductions_vor.tsv"
writeFile(estVorDed, "code\tamount\tdescription\nvor316\t5000\tKV privat\nvor319\t600\tPV privat\nvor300\t3000\tRentenversicherung\n")
let (estVorOut, estVorRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estVorDed & " -y 2025 --validate-only")
check("est Vorsorge privat exits 0 or HID", estVorRc == 0 or estVorOut.contains("610301202"), estVorOut)
check("est Vorsorge no schema errors", not estVorOut.contains("610301200"), estVorOut)
removeFile(estVorDed)
echo ""

# --- ESt: Vorsorgeaufwand (gesetzlich) ---
echo "--- est Vorsorgeaufwand (gesetzlich) ---"
let estGkvDed = projectRoot / "tests" / "tmp_deductions_gkv.tsv"
writeFile(estGkvDed, "code\tamount\nvor326\t4800\nvor329\t500\n")
let (estGkvOut, estGkvRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estGkvDed & " -y 2025 --validate-only")
check("est Vorsorge gesetzlich exits 0 or HID", estGkvRc == 0 or estGkvOut.contains("610301202"), estGkvOut)
check("est Vorsorge gesetzlich no schema errors", not estGkvOut.contains("610301200"), estGkvOut)
removeFile(estGkvDed)
echo ""

# --- ESt: no sources (KAP-only filing) ---
echo "--- est no sources ---"
let estNoSrcConf = projectRoot / "tests" / "tmp_viking_nosrc.conf"
writeConf(estNoSrcConf, personalBlock)
let (estNoEuerOut, estNoEuerRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estNoSrcConf & " -y 2025 --dry-run --force")
check("est no sources exits 0", estNoEuerRc == 0, estNoEuerOut)
check("est no sources no Anlage G/S", not estNoEuerOut.contains("<G>") and not estNoEuerOut.contains("<S>"))
removeFile(estNoSrcConf)
echo ""

# --- ESt: multiple sources (one G, one S) ---
echo "--- est multiple sources ---"
let estMultiConf = projectRoot / "tests" / "tmp_est_multi.conf"
writeConf(estMultiConf, personalBlock & """
[mybiz]
versteuerung = 2

[freiberuf]
versteuerung = 2
""")
let estTsv2 = estWd / "2025-freiberuf.tsv"
writeFile(estTsv, "1000,19\n-300,19\n")
writeFile(estTsv2, "500,19\n")
let (estMultiOut, estMultiRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estMultiConf & " -y 2025 --dry-run --force")
check("est multi exits 0", estMultiRc == 0, estMultiOut)
check("est multi has Anlage G profit 833", estMultiOut.contains("<E0800302>833</E0800302>"))
check("est multi has Anlage S profit 595", estMultiOut.contains("<E0803202>595</E0803202>"))
check("est multi has both G and S", estMultiOut.contains("<G>") and estMultiOut.contains("<S>"))
removeFile(estTsv2)
removeFile(estMultiConf)
echo ""

# --- ESt: Testmerker ---
echo "--- est Testmerker ---"
writeFile(estTsv, "100,19\n")
let (estTestOut, estTestRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est --test -c " & estConf & " -y 2025 --dry-run --force")
check("est --test has Testmerker", estTestOut.contains("<Testmerker>700000004</Testmerker>"))

let (estProdOut, estProdRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -y 2025 --dry-run --force")
check("est production exits 0", estProdRc == 0, estProdOut)
check("est production no Testmerker", not estProdOut.contains("Testmerker"), estProdOut)
echo ""

# --- ESt: per-year validation ---
echo "--- est per-year validation ---"
var estYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let eStPrefix = PluginPrefix & "ESt_"
    if name.startsWith(eStPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[eStPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2024:
          estYears.add(y)
      except ValueError:
        discard
estYears.sort()

check("found ESt plugins for 2024+", estYears.len > 0, "plugins in: " & pluginPath)
for year in estYears:
  let ey = estWd / ($year & "-mybiz.tsv")
  writeFile(ey, "1000,19\n-500,19\n")
  let (eyOut, eyRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -y " & $year & " --validate-only --force")
  let eySchemaOk = not eyOut.contains("610301200")
  let eyCertOk = not eyOut.contains("610001050")
  let eyHidBlocked = eyOut.contains("610301202")
  let eyOk = eyRc == 0 or eyHidBlocked
  check("est " & $year & " schema valid", eySchemaOk, eyOut)
  check("est " & $year & " no cert errors", eyCertOk, eyOut)
  if eyOk:
    check("est " & $year & " passes validation", true)
  else:
    check("est " & $year & " passes validation", false, eyOut)
  removeFile(ey)

# --- ESt: full send path ---
echo "--- est (send) ---"
writeFile(estTsv, "1000,19\n-500,19\n")
let (estSendOut, estSendRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est --test -c " & estConf & " -y 2025 --force")
let estSendSchemaOk = not estSendOut.contains("610301200")
let estSendCertOk = not estSendOut.contains("610001050")
check("est send: no schema errors", estSendSchemaOk, estSendOut)
check("est send: no cert errors", estSendCertOk, estSendOut)
let estSendHidBlocked = estSendOut.contains("610301202")
if estSendRc == 0:
  check("est send: succeeds", true)
elif estSendHidBlocked:
  check("est send: only HerstellerID issue", true)
else:
  check("est send: unexpected error", false, estSendOut)
echo ""

# --- ESt: Sonderausgaben ---
echo "--- est Sonderausgaben ---"
let estSaDed = projectRoot / "tests" / "tmp_deductions_sa.tsv"
writeFile(estSaDed, "code\tamount\nsa140\t500\nsa141\t50\nsa131\t200\n")
let (estSaOut, estSaRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estSaDed & " -y 2025 --dry-run")
check("est SA exits 0", estSaRc == 0, estSaOut)
check("est SA has <SA>", estSaOut.contains("<SA>"))
check("est SA has KiSt gezahlt", estSaOut.contains("<E0107601>"))
check("est SA has KiSt erstattet", estSaOut.contains("<E0107602>"))
check("est SA has Spenden", estSaOut.contains("<E0108105>"))
echo ""

# --- ESt: Aussergewoehnliche Belastungen ---
echo "--- est AgB ---"
let estAgbDed = projectRoot / "tests" / "tmp_deductions_agb.tsv"
writeFile(estAgbDed, "code\tamount\nagb187\t750\n")
let (estAgbOut, estAgbRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estAgbDed & " -y 2025 --dry-run")
check("est AgB exits 0", estAgbRc == 0, estAgbOut)
check("est AgB has <AgB>", estAgbOut.contains("<AgB>"))
check("est AgB has Krankh", estAgbOut.contains("<E0161304>"))
echo ""

# --- ESt: Weitere sonstige Vorsorgeaufwendungen ---
echo "--- est Weit_Sons_VorAW ---"
let estWsDed = projectRoot / "tests" / "tmp_deductions_ws.tsv"
writeFile(estWsDed, "code\tamount\nvor502\t550\n")
let (estWsOut, estWsRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estWsDed & " -y 2025 --dry-run")
check("est Weit exits 0", estWsRc == 0, estWsOut)
check("est Weit has Weit_Sons_VorAW", estWsOut.contains("<Weit_Sons_VorAW>"))
check("est Weit has U_HP_Ris_Vers sum 550", estWsOut.contains("<E2001803>550</E2001803>"))
echo ""

# --- ESt: Zusatz-KV (privat) ---
echo "--- est Zusatz-KV (privat) ---"
let estZkDed = projectRoot / "tests" / "tmp_deductions_zk.tsv"
writeFile(estZkDed, "code\tamount\nvor316\t5000\nvor328\t120\n")
let (estZkOut, estZkRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estConf & " -D " & estZkDed & " -y 2025 --dry-run")
check("est ZK privat exits 0", estZkRc == 0, estZkOut)
check("est ZK privat has E2003302", estZkOut.contains("<E2003302>120</E2003302>"))
echo ""

# --- ESt: Anlage KAP ---
echo "--- est Anlage KAP ---"
let estKapConf = projectRoot / "tests" / "tmp_viking_kap.conf"
writeConf(estKapConf, personalBlock & """
[mybiz]
versteuerung = 2

[ibkr]
gains = 1500.50
tax = 375.13
soli = 20.63
guenstigerpruefung = 1
""")
let (estKapOut, estKapRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estKapConf & " -y 2025 --dry-run --force")
check("est KAP exits 0", estKapRc == 0, estKapOut)
check("est KAP has <KAP>", estKapOut.contains("<KAP>"))
check("est KAP has Guenstigerpruefung", estKapOut.contains("<E1900401>1</E1900401>"))
check("est KAP has Kapitalertraege", estKapOut.contains("<E1900701>"))
check("est KAP has KapESt", estKapOut.contains("<E1904701>"))
check("est KAP has Soli", estKapOut.contains("<E1904801>"))
removeFile(estKapConf)
echo ""

# --- ESt: Anlage Kind ---
echo "--- est Anlage Kind ---"
let estKindConf = projectRoot / "tests" / "tmp_viking_kind.conf"
writeConf(estKindConf, personalBlock & """
[mybiz]
versteuerung = 2

[Max Maier]
geburtsdatum = 01.06.2018
idnr = 12345678901
verhaeltnis = 1
kindergeld = 2400

[Lisa Maier]
geburtsdatum = 15.03.2020
idnr = 98765432109
verhaeltnis = 1
kindergeld = 2400
""")
let estKindDed = projectRoot / "tests" / "tmp_deductions_kind.tsv"
writeFile(estKindDed, "code\tamount\nmax174\t2400\nlisa174\t3600\nlisa176\t1500\n")
let (estKindOut, estKindRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estKindConf & " -D " & estKindDed & " -y 2025 --dry-run")
check("est Kind exits 0", estKindRc == 0, estKindOut)
check("est Kind has 2 <Kind>", estKindOut.count("<Kind>") == 2)
check("est Kind has Max", estKindOut.contains("Max"))
check("est Kind has Lisa", estKindOut.contains("Lisa"))
check("est Kind has betreuungskosten", estKindOut.contains("<E0506105>"))
check("est Kind has schulgeld", estKindOut.contains("<E0505607>"))
# Kid without kindschaftsverhaeltnis_b -> no <K_Verh_B>.
check("est Kind no K_Verh_B without kindschaftsverhaeltnis_b",
      estKindOut.contains("<K_Verh_A>") and
      not estKindOut.contains("<K_Verh_B>"), estKindOut)
removeFile(estKindConf)
removeFile(estKindDed)

# --- ESt: K_Verh_B is gated on [spouse] (Einzel vs Zusammen) ---
echo "--- est Anlage Kind K_Verh_B gated on [spouse] ---"
# (1) No [spouse] + kindschaftsverhaeltnis_b set -> K_Verh_B suppressed
# (ERiC rule 5075 rejects K_Verh_B on Einzelveranlagung).
let estKindBNoSpouseConf = projectRoot / "tests" / "tmp_viking_kind_b_nospouse.conf"
writeConf(estKindBNoSpouseConf, personalBlock & """
[mybiz]
versteuerung = 2

[Max Maier]
geburtsdatum = 01.06.2018
idnr = 12345678901
verhaeltnis = leiblich
personb-verhaeltnis = leiblich
familienkasse = Berlin
""")
let (estNoSpOut, estNoSpRc) = run("cd " & estWd & " && " & projectRoot / Viking &
  " est -c " & estKindBNoSpouseConf & " -y 2025 --dry-run --force")
check("est Kind no-spouse exits 0", estNoSpRc == 0, estNoSpOut)
check("est Kind no K_Verh_B without [spouse]",
      not estNoSpOut.contains("<K_Verh_B>"), estNoSpOut)
check("est Kind emits familienkasse as E0500706",
      estNoSpOut.contains("<E0500706>Berlin</E0500706>"), estNoSpOut)
# Without parent_b_name: no K_Verh_and_P emitted (plausi 100500048 will fire
# at sandbox-time; schema still valid).
check("est Kind no K_Verh_and_P without parent_b_name",
      not estNoSpOut.contains("<K_Verh_and_P>"), estNoSpOut)
removeFile(estKindBNoSpouseConf)

# (1b) No [spouse] + parent_b_name set -> K_Verh_and_P emitted with
# E0501103/E0501903/E0501106 (plausi rules 100500048 + 100500001).
let estKindAndPConf = projectRoot / "tests" / "tmp_viking_kind_and_p.conf"
writeConf(estKindAndPConf, personalBlock & """
[mybiz]
versteuerung = 2

[Max Maier]
geburtsdatum         = 01.06.2018
idnr                 = 12345678901
verhaeltnis          = leiblich
personb-verhaeltnis  = leiblich
personb-name         = Greta Maier
familienkasse        = Berlin
""")
let (estAndPOut, estAndPRc) = run("cd " & estWd & " && " & projectRoot / Viking &
  " est -c " & estKindAndPConf & " -y 2025 --dry-run --force")
check("est Kind and_P exits 0", estAndPRc == 0, estAndPOut)
check("est Kind emits K_Verh_and_P without [spouse] when parent_b_name set",
      estAndPOut.contains("<K_Verh_and_P>"), estAndPOut)
check("est Kind K_Verh_and_P has E0501103",
      estAndPOut.contains("<E0501103>Greta Maier</E0501103>"), estAndPOut)
check("est Kind K_Verh_and_P has E0501903",
      estAndPOut.contains("<E0501903>01.01-31.12</E0501903>"), estAndPOut)
check("est Kind K_Verh_and_P has E0501106",
      estAndPOut.contains("<E0501106>1</E0501106>"), estAndPOut)
check("est Kind still no K_Verh_B on Einzel",
      not estAndPOut.contains("<K_Verh_B>"), estAndPOut)
removeFile(estKindAndPConf)

# (2) [spouse] present + kindschaftsverhaeltnis_b set -> K_Verh_B emitted
let estKindBConf = projectRoot / "tests" / "tmp_viking_kind_b.conf"
writeConf(estKindBConf, personalBlock & """
[Greta Maier]
geburtsdatum = 12.07.1956
idnr = 04452397688

[mybiz]
versteuerung = 2

[Max Maier]
geburtsdatum = 01.06.2018
idnr = 12345678901
verhaeltnis = leiblich
personb-verhaeltnis = leiblich
familienkasse = Berlin
""")
let (estKbOut, estKbRc) = run("cd " & estWd & " && " & projectRoot / Viking &
  " est -c " & estKindBConf & " -y 2025 --dry-run --force")
check("est Kind B exits 0", estKbRc == 0, estKbOut)
check("est Kind emits K_Verh_B with [spouse]",
      estKbOut.contains("<K_Verh_B>"), estKbOut)
check("est Kind K_Verh_B uses E0500808",
      estKbOut.contains("<E0500808>1</E0500808>"), estKbOut)
check("est Kind K_Verh_B period uses E0500805",
      estKbOut.contains("<E0500805>01.01-31.12</E0500805>"), estKbOut)
removeFile(estKindBConf)

# Kid without familienkasse -> no E0500706 emitted.
let estKindNoFkConf = projectRoot / "tests" / "tmp_viking_kind_nofk.conf"
writeConf(estKindNoFkConf, personalBlock & """
[mybiz]
versteuerung = 2

[Max Maier]
geburtsdatum = 01.06.2018
idnr = 12345678901
verhaeltnis = leiblich
""")
let (estNoFkOut, estNoFkRc) = run("cd " & estWd & " && " & projectRoot / Viking &
  " est -c " & estKindNoFkConf & " -y 2025 --dry-run --force")
check("est Kind no familienkasse exits 0", estNoFkRc == 0, estNoFkOut)
check("est Kind no E0500706 without familienkasse",
      not estNoFkOut.contains("<E0500706>"), estNoFkOut)
removeFile(estKindNoFkConf)
echo ""

# --- ESt: validate deductions against ERiC ---
echo "--- est personal deductions validation ---"
let estPdDed = projectRoot / "tests" / "tmp_deductions_pd.tsv"
writeFile(estPdDed, "code\tamount\nvor316\t5000\nvor319\t600\nvor502\t350\nsa140\t500\nsa131\t200\nagb187\t750\n")
let estPdConf = projectRoot / "tests" / "tmp_viking_pd.conf"
writeConf(estPdConf, personalBlock & """
[mybiz]
versteuerung = 2

[ibkr]
gains = 1500
tax = 375
soli = 0
guenstigerpruefung = 1
pauschbetrag = 1000
""")
let (estPdOut, estPdRc) = run("cd " & estWd & " && " & projectRoot / Viking & " est -c " & estPdConf & " -D " & estPdDed & " -y 2025 --validate-only")
check("est PD validate no schema errors", not estPdOut.contains("610301200"), estPdOut)
check("est PD validate no cert errors", not estPdOut.contains("610001050"), estPdOut)
let estPdOk = estPdRc == 0 or estPdOut.contains("610301202")
check("est PD validates", estPdOk, estPdOut)
removeFile(estPdDed)
removeFile(estPdConf)

removeFile(estConf)
removeFile(estTsv)

for f in @[estSaDed, estAgbDed, estWsDed, estZkDed]:
  removeFile(f)

echo ""

# =================================================================
# USt (Umsatzsteuererklaerung) tests
# =================================================================

let ustConf = projectRoot / "tests" / "tmp_viking_ust.conf"
writeConf(ustConf, personalBlock & """
[freelance]
versteuerung = 2
""")

let ustTsv = estWd / "2025-freelance.tsv"

echo "--- ust --dry-run (mixed rates) ---"
writeFile(ustTsv, "1000,19\n500,7\n-200,19\n")
let (ustDryOut, ustDryRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance --test -c " & ustConf & " -y 2025 --dry-run")
check("ust dry-run exits 0", ustDryRc == 0, ustDryOut)
check("ust dry-run has XML output", ustDryOut.contains("<?xml"))
check("ust dry-run has E50 root", ustDryOut.contains("<E50"))
check("ust dry-run has USt2A", ustDryOut.contains("<USt2A>"))
check("ust dry-run has ElsterErklaerung", ustDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("ust dry-run has DatenArt USt", ustDryOut.contains("<DatenArt>USt</DatenArt>"))
check("ust dry-run has Empfaenger Ziel", ustDryOut.contains("<Ziel>BY</Ziel>"))
check("ust dry-run has Unterfallart 50", ustDryOut.contains("<Unterfallart>50</Unterfallart>"))
check("ust dry-run has Ums_allg 19%", ustDryOut.contains("<E3003303>1000</E3003303>"))
check("ust dry-run has Ums_erm 7%", ustDryOut.contains("<E3004401>500</E3004401>"))
check("ust dry-run has Testmerker", ustDryOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

echo "--- ust income/expense split ---"
writeFile(ustTsv, "1000,19\n-300,19\n")
let (ustSplitOut, ustSplitRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance -c " & ustConf & " -y 2025 --dry-run")
check("ust split exits 0", ustSplitRc == 0, ustSplitOut)
check("ust split Ums_allg base", ustSplitOut.contains("<E3003303>1000</E3003303>"))
check("ust split Ums_allg tax", ustSplitOut.contains("<E3003304>190,00</E3003304>"))
check("ust split Vorsteuer in Abz_VoSt", ustSplitOut.contains("<E3006201>57,00</E3006201>"))
check("ust split Vorsteuer sum", ustSplitOut.contains("<E3006901>57,00</E3006901>"))
check("ust split Vorsteuer in calc", ustSplitOut.contains("<E3009901>57,00</E3009901>"))
check("ust split verbleibende USt", ustSplitOut.contains("<E3011101>133,00</E3011101>"))
echo ""

echo "--- ust with Vorauszahlungen (from conf) ---"
let ustVzConf = projectRoot / "tests" / "tmp_ust_vz.conf"
writeConf(ustVzConf, personalBlock & """
[freelance]
versteuerung = 2
vorauszahlungen = 100
""")
writeFile(ustTsv, "1000,19\n")
let (ustVzOut, ustVzRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance -c " & ustVzConf & " -y 2025 --dry-run")
check("ust vorauszahlungen exits 0", ustVzRc == 0, ustVzOut)
check("ust vorauszahlungen E3011301", ustVzOut.contains("<E3011301>100,00</E3011301>"))
check("ust vorauszahlungen E3011401", ustVzOut.contains("<E3011401>90,00</E3011401>"))
removeFile(ustVzConf)
echo ""

echo "--- ust empty file ---"
writeFile(ustTsv, "")
let (ustEmptyOut, ustEmptyRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance -c " & ustConf & " -y 2025 --dry-run")
check("ust empty exits 0", ustEmptyRc == 0, ustEmptyOut)
check("ust empty Ums_Sum 0", ustEmptyOut.contains("<E3006001>0,00</E3006001>"))
check("ust empty verbleibende 0", ustEmptyOut.contains("<E3011101>0,00</E3011101>"))
echo ""

echo "--- ust per-year validation ---"
var ustYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let uStPrefix = PluginPrefix & "USt_"
    let uStVAPrefix2 = PluginPrefix & "UStVA_"
    if name.startsWith(uStPrefix) and not name.startsWith(uStVAPrefix2) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[uStPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2025:
          ustYears.add(y)
      except ValueError:
        discard
ustYears.sort()

check("found USt plugins for 2025+", ustYears.len > 0, "plugins in: " & pluginPath)
for year in ustYears:
  let ey = estWd / ($year & "-freelance.tsv")
  writeFile(ey, "1000,19\n-500,19\n")
  let (eyOut, eyRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance -c " & ustConf & " -y " & $year & " --validate-only")
  let eySchemaOk = not eyOut.contains("610301200")
  let eyCertOk = not eyOut.contains("610001050")
  let eyHidBlocked = eyOut.contains("610301202")
  let eyOk = eyRc == 0 or eyHidBlocked
  check("ust " & $year & " schema valid", eySchemaOk, eyOut)
  check("ust " & $year & " no cert errors", eyCertOk, eyOut)
  if eyOk:
    check("ust " & $year & " passes validation", true)
  else:
    check("ust " & $year & " passes validation", false, eyOut)
  removeFile(ey)

echo "--- ust (send) ---"
writeFile(ustTsv, "1000,19\n-500,19\n")
let (ustSendOut, ustSendRc) = run("cd " & estWd & " && " & projectRoot / Viking & " ust freelance -c " & ustConf & " -y 2025 --test")
let ustSendSchemaOk = not ustSendOut.contains("610301200")
let ustSendCertOk = not ustSendOut.contains("610001050")
check("ust send: no schema errors", ustSendSchemaOk, ustSendOut)
check("ust send: no cert errors", ustSendCertOk, ustSendOut)
let ustSendHidBlocked = ustSendOut.contains("610301202")
if ustSendRc == 0:
  check("ust send: succeeds", true)
elif ustSendHidBlocked:
  check("ust send: only HerstellerID issue", true)
else:
  check("ust send: unexpected error", false, ustSendOut)

removeFile(ustTsv)
removeFile(ustConf)
echo ""

# =================================================================
# Message (SonstigeNachrichten) tests
# =================================================================

let messageConf = projectRoot / "tests" / "tmp_message_viking.conf"
writeConf(messageConf, personalBlock)

echo "--- message --dry_run ---"
let (msgDryOut, msgDryRc) = run(Viking & " message --test -c " & messageConf & " --subject \"Test Betreff\" --text \"Test Nachricht\" --dry_run")
check("message dry_run exits 0", msgDryRc == 0, msgDryOut)
check("message dry_run has Nachricht element", msgDryOut.contains("<Nachricht xmlns="))
check("message dry_run has ElsterNachricht", msgDryOut.contains("<Verfahren>ElsterNachricht</Verfahren>"))
check("message dry_run has DatenArt SonstigeNachrichten", msgDryOut.contains("<DatenArt>SonstigeNachrichten</DatenArt>"))
check("message dry_run has Testmerker", msgDryOut.contains("<Testmerker>700000004</Testmerker>"))
check("message dry_run has Betreff", msgDryOut.contains("<Betreff>Test Betreff</Betreff>"))
check("message dry_run has Text", msgDryOut.contains("<Text>Test Nachricht</Text>"))
check("message dry_run has Steuernummer", msgDryOut.contains("<Steuernummer>"))
echo ""

echo "--- message --validate_only ---"
let (msgValOut, msgValRc) = run(Viking & " message -c " & messageConf & " --subject \"Test\" --text \"Testnachricht\" --validate_only")
check("message validate_only exits 0", msgValRc == 0, msgValOut)
echo ""

echo "--- message validation ---"
let (msgNoSubj, msgNoSubjRc) = run(Viking & " message -c " & messageConf & " --text \"Test\"")
check("message without subject fails", msgNoSubjRc != 0)
check("message without subject shows error", msgNoSubj.contains("--subject is required"))

let (msgNoText, msgNoTextRc) = run(Viking & " message -c " & messageConf & " --subject \"Test\"")
check("message without text fails", msgNoTextRc != 0)
check("message without text shows error", msgNoText.contains("--text or --text-file is required"))

let (msgBothInput, msgBothInputRc) = run(Viking & " message -c " & messageConf & " --subject \"Test\" --text \"a\" --text_file \"b\"")
check("message with both text and text_file fails", msgBothInputRc != 0)
check("message with both inputs shows error", msgBothInput.contains("mutually exclusive"))

let longSubject = 'A'.repeat(100)
let (msgLongSubj, msgLongSubjRc) = run(Viking & " message -c " & messageConf & " --subject \"" & longSubject & "\" --text \"Test\"")
check("message with long subject fails", msgLongSubjRc != 0)
check("message long subject shows error", msgLongSubj.contains("at most 99"))

removeFile(messageConf)
echo ""

# =================================================================
# IBAN change tests
# =================================================================

let ibanConf = projectRoot / "tests" / "tmp_iban_viking.conf"
writeConf(ibanConf, personalBlock)

echo "--- iban --dry_run ---"
let (ibanDryOut, ibanDryRc) = run(Viking & " iban --test -c " & ibanConf & " --new_iban DE89370400440532013000 --dry_run")
check("iban dry_run exits 0", ibanDryRc == 0, ibanDryOut)
check("iban dry_run has AenderungBankverbindung", ibanDryOut.contains("<AenderungBankverbindung xmlns="))
check("iban dry_run has DatenArt", ibanDryOut.contains("<DatenArt>AenderungBankverbindung</DatenArt>"))
check("iban dry_run has Testmerker", ibanDryOut.contains("<Testmerker>700000004</Testmerker>"))
check("iban dry_run has IBAN", ibanDryOut.contains("<IBAN>DE89370400440532013000</IBAN>"))
check("iban dry_run has Steuernummer", ibanDryOut.contains("<Steuernummer>"))
echo ""

echo "--- iban --validate_only ---"
let (ibanValOut, ibanValRc) = run(Viking & " iban --test -c " & ibanConf & " --new_iban DE89370400440532013000 --validate_only")
check("iban validate_only exits 0", ibanValRc == 0, ibanValOut)
echo ""

echo "--- iban validation ---"
let (ibanNoIban, ibanNoIbanRc) = run(Viking & " iban -c " & ibanConf)
check("iban without new_iban fails", ibanNoIbanRc != 0)
check("iban without new_iban shows error", ibanNoIban.contains("--new-iban is required"))

removeFile(ibanConf)
echo ""

# =================================================================
# Retrieve (Datenabholung) tests
# =================================================================

let abholConf = projectRoot / "tests" / "tmp_abhol_viking.conf"
writeConf(abholConf, """[Hans Maier]
""")

echo "--- list --dry_run ---"
let (listDryOut, listDryRc) = run(Viking & " list -c " & abholConf & " --dry_run")
check("list dry_run exits 0", listDryRc == 0, listDryOut)
check("list dry_run has PostfachAnfrage XML", listDryOut.contains("<PostfachAnfrage "))
check("list dry_run has Datenabholung element", listDryOut.contains("<Datenabholung"))
check("list dry_run has DatenLieferant from conf", listDryOut.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))
check("list dry_run has HerstellerID constant", listDryOut.contains("<HerstellerID>40036</HerstellerID>"))

echo "--- download --dry_run ---"
let (dlDryOut, dlDryRc) = run(Viking & " download -c " & abholConf & " --dry_run")
check("download dry_run exits 0", dlDryRc == 0, dlDryOut)
check("download dry_run has PostfachAnfrage XML", dlDryOut.contains("<PostfachAnfrage "))
check("download dry_run has DatenLieferant from conf", dlDryOut.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))

removeFile(abholConf)
echo ""

# --- init ---
echo "--- init ---"
let initDir = "tests/tmp_init"
createDir(initDir)

let (initOut, initRc) = run(Viking & " init --dir " & initDir)
check("init creates files", initRc == 0, initOut)
check("init creates viking.conf", fileExists(initDir / "viking.conf"))
check("init creates deductions.tsv", fileExists(initDir / "deductions.tsv"))

let confContent = readFile(initDir / "viking.conf")
check("init conf has full-name taxpayer section", confContent.contains("[Vorname Nachname]"))
check("init conf has geburtsdatum", confContent.contains("geburtsdatum ="))
check("init conf has steuernr",    confContent.contains("steuernr     ="))
check("init conf has source examples",
  confContent.contains("[freiberuf]") or confContent.contains("[gewerbe]"))

let dedContent = readFile(initDir / "deductions.tsv")
check("init deductions has header", dedContent.contains("code\tamount\tdescription"))
check("init deductions has vor300", dedContent.contains("vor300"))
check("init deductions has sa140", dedContent.contains("sa140"))
check("init deductions has agb187", dedContent.contains("agb187"))

let (skipOut, skipRc) = run(Viking & " init --dir " & initDir)
check("init skips existing files", skipRc == 0, skipOut)
check("init skip message", skipOut.contains("Skipped"))

let (forceOut, forceRc) = run(Viking & " init --dir " & initDir & " --force")
check("init force overwrites", forceRc == 0, forceOut)
check("init force creates", forceOut.contains("Created"))

let (badDirOut, badDirRc) = run(Viking & " init --dir /nonexistent/path")
check("init bad dir fails", badDirRc != 0, badDirOut)

# Check generated conf is parseable (will fail validation because fields are empty)
let (initEstDry, initEstDryRc) = run(Viking & " est -c " & initDir / "viking.conf" & " --dry-run -y 2025 --force")
check("init conf is parseable", initEstDryRc != 0)
check("init conf validation errors", initEstDry.contains("not set"))

removeDir(initDir)
echo ""

# Cleanup XDG isolation dir
removeDir(testXdgHome)

# --- Summary ---
echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
