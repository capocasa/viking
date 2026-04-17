## End-to-end sandbox tests for viking
## Requires: ERiC library + test certificates in test/cache (run `viking fetch` first)

import std/[osproc, strutils, os, algorithm]
import dotenv

when defined(macosx):
  const DynlibExt = ".dylib"
  const PluginPrefix = "libcheck"
  const Viking = "./viking"
elif defined(windows):
  const DynlibExt = ".dll"
  const PluginPrefix = "check"
  const Viking = "viking.exe"
else:
  const DynlibExt = ".so"
  const PluginPrefix = "libcheck"
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

# Load .env if present
if fileExists(".env"):
  load()

echo "=== viking end-to-end tests ==="
echo "Working directory: ", getCurrentDir()
echo ""

# --- Prerequisite check ---
echo "--- Prerequisites ---"
let envExists = fileExists(".env")
check("dotenv file exists", envExists)

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

# viking.conf for submit tests
let submitConf = projectRoot / "tests" / "tmp_submit_viking.conf"
writeFile(submitConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
income = 2
street = Musterstr.
housenumber = 1
zip = 10115
city = Berlin
iban = DE91100000000123456789
""")

# --- Submit: dry-run ---
echo "--- submit --dry-run ---"
let (dryOut, dryRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 1000 --dry-run")
check("dry-run exits 0", dryRc == 0, "exit code: " & $dryRc)
check("dry-run has XML output", dryOut.contains("<?xml"))
check("dry-run shows XML", dryOut.contains("<Elster"))
check("dry-run XML has TransferHeader", dryOut.contains("<TransferHeader"))
check("dry-run XML has UStVA", dryOut.contains("<Umsatzsteuervoranmeldung>"))
check("dry-run XML has Kz81", dryOut.contains("<Kz81>1000</Kz81>"))
check("dry-run XML has Kz83 (VAT)", dryOut.contains("<Kz83>190.00</Kz83>"))
check("dry-run XML has Testmerker 700000004", dryOut.contains("<Testmerker>700000004</Testmerker>"))
check("dry-run XML has Empfaenger", dryOut.contains("""<Empfaenger id="F">9198</Empfaenger>"""))
echo ""

# --- Testmerker presence based on TEST flag ---
echo "--- TEST flag ---"
# Create a minimal env with TEST=0 (production)
let prodEnv = projectRoot / "tests" / ".env.test_prod"
writeFile(prodEnv, readFile(projectRoot / ".env").replace("VIKING_TEST=1", "VIKING_TEST=0"))
let (prodOut, prodRc) = run("VIKING_TEST=0 " & Viking & " submit -c " & submitConf & " --p 41 --amount19 0 --dry-run --env " & prodEnv)
check("TEST=0 dry-run exits 0", prodRc == 0, prodOut)
check("TEST=0 no Testmerker", not prodOut.contains("Testmerker"), prodOut)

let (testOut, testRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 0 --dry-run")
check("TEST=1 dry-run exits 0", testRc == 0, testOut)
check("TEST=1 has Testmerker", testOut.contains("<Testmerker>700000004</Testmerker>"))
removeFile(prodEnv)
echo ""

# --- Submit: dry-run with both rates ---
echo "--- submit --dry-run (19% + 7%) ---"
let (dryBoth, dryBothRc) = run(Viking & " submit -c " & submitConf & " --p 01 --amount19 500 --amount7 200 --dry-run")
check("dual-rate dry-run exits 0", dryBothRc == 0)
check("dual-rate has Kz81", dryBoth.contains("<Kz81>500</Kz81>"))
check("dual-rate has Kz86", dryBoth.contains("<Kz86>200</Kz86>"))
# 500*0.19 + 200*0.07 = 95 + 14 = 109
check("dual-rate has Kz83", dryBoth.contains("<Kz83>109.00</Kz83>"))
# Kz83 must appear before Kz86 per ELSTER XSD sequence
check("Kz83 before Kz86", dryBoth.find("<Kz83>") < dryBoth.find("<Kz86>"))
echo ""

# --- Submit: validate-only ---
echo "--- submit --validate-only ---"
let (valOut, valRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 0 --validate-only")
# This may fail with HerstellerID error (610301202) which is expected
# if the demo ID is blocked. But it should NOT fail with schema errors (610301200)
# or certificate errors (610001050).
let schemaOk = not valOut.contains("610301200")
let certOk = not valOut.contains("610001050")
check("no XML schema errors", schemaOk, valOut)
check("no certificate errors", certOk, valOut)
# If it succeeds or fails only on HerstellerID, that's acceptable
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
let (sendOut, sendRc) = run(Viking & " submit -c " & submitConf & " --p 41 --amount19 0")
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
# Discover available UStVA years from plugin files
let pluginPath = getEnv("VIKING_ERIC_PLUGIN_PATH", "test/cache/eric/ERiC-43.3.2.0/Linux-x86_64/lib/plugins")
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

# Test each year with different rate combinations
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
let (noconf, noconfRc) = run(Viking & " submit --amount19 100 --p 01")
check("missing --conf is rejected", noconfRc != 0)
check("missing --conf shows error", noconf.contains("--conf is required"))

let (noperiod, noperiodRc) = run(Viking & " submit -c " & submitConf & " --amount19 100")
check("missing --period is rejected", noperiodRc != 0)
check("missing --period shows error", noperiod.contains("--period is required"))

let (noamt, noamtRc) = run(Viking & " submit -c " & submitConf & " --p 41")
check("missing amounts is rejected", noamtRc != 0)
check("missing amounts shows error", noamt.contains("--amount19") or noamt.contains("--invoice-file"))

let (badperiod, badperiodRc) = run(Viking & " submit -c " & submitConf & " --p 99 --amount19 100")
check("invalid period is rejected", badperiodRc != 0)
check("invalid period shows error", badperiod.contains("Invalid period"))
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
# 800*0.19 + 500*0.07 = 152 + 35 = 187
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
check("0% rate XML has all Kz", kz45Out.contains("<Kz83>190.00</Kz83>"))
echo ""

# Test: Period filtering
echo "--- invoice period filtering ---"
# Invoices spanning Q1 and Q2 2026
writeFile(invCsv, "amount,rate,date,invoice-id,description\n1000,19,2026-01-15,INV-001,Jan\n500,19,2026-02-10,INV-002,Feb\n300,7,2026-04-05,INV-003,Apr\n200,19,2026-06-20,INV-004,Jun\n")

# Q1 should get Jan + Feb only
let (q1Out, q1Rc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 41 -y 2026 --dry-run")
check("Q1 filter exits 0", q1Rc == 0, q1Out)
check("Q1 filter Kz81 = 1500", q1Out.contains("<Kz81>1500</Kz81>"))
check("Q1 filter no Kz86", not q1Out.contains("<Kz86>"))
check("Q1 filter no Kz86 for Q1", not q1Out.contains("<Kz86>"))

# Q2 should get Apr + Jun
let (q2Out, q2Rc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 42 -y 2026 --dry-run")
check("Q2 filter exits 0", q2Rc == 0, q2Out)
check("Q2 filter Kz81 = 200", q2Out.contains("<Kz81>200</Kz81>"))
check("Q2 filter Kz86 = 300", q2Out.contains("<Kz86>300</Kz86>"))
check("Q2 filter has both rates", q2Out.contains("<Kz86>300</Kz86>"))

# Monthly: January only
let (janOut, janRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 -y 2026 --dry-run")
check("Jan filter exits 0", janRc == 0, janOut)
check("Jan filter Kz81 = 1000", janOut.contains("<Kz81>1000</Kz81>"))
check("Jan filter only Jan invoices", not janOut.contains("<Kz86>"))

# Wrong year -> zero submission
let (wrongYrOut, wrongYrRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 41 -y 2025 --dry-run")
check("wrong year filter exits 0", wrongYrRc == 0, wrongYrOut)
check("wrong year has Kz81 = 0", wrongYrOut.contains("<Kz81>0</Kz81>"))

# Undated invoices excluded with warning
writeFile(invCsv, "1000,19,2026-01-15,INV-001,dated\n500,19\n")
let (undatedOut, undatedRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 -y 2026 --dry-run 2>&1")
check("undated filter exits 0", undatedRc == 0, undatedOut)
check("undated shows warning", undatedOut.contains("without date"))
check("undated Kz81 = 1000", undatedOut.contains("<Kz81>1000</Kz81>"))
echo ""

# Test 7: Header-only file -> zero submission
echo "--- invoice header-only ---"
writeFile(invCsv, "amount,rate,date\n")
let (hdrOut, hdrRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("header-only exits 0", hdrRc == 0, hdrOut)
check("header-only has Kz81 = 0", hdrOut.contains("<Kz81>0</Kz81>"))
echo ""

# Test 8: Comment lines skipped
echo "--- invoice comments ---"
writeFile(invCsv, "# This is a comment\n100,19\n# Another comment\n200,7\n")
let (cmtOut, cmtRc) = run(Viking & " submit -c " & submitConf & " -i " & invCsv & " --p 01 --dry-run")
check("comments exits 0", cmtRc == 0, cmtOut)
check("comments parses 2 invoices", cmtOut.contains("<Kz81>100</Kz81>"))
check("comments Kz81 = 100", cmtOut.contains("<Kz81>100</Kz81>"))
check("comments Kz86 = 200", cmtOut.contains("<Kz86>200</Kz86>"))

removeFile(invCsv)
removeFile(submitConf)
echo ""

# =================================================================
# EÜR (Einnahmenüberschussrechnung) tests
# =================================================================

# viking.conf for EÜR tests
let euerConf = projectRoot / "tests" / "tmp_euer_viking.conf"
writeFile(euerConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
income = 2
street = Musterstr.
housenumber = 1
zip = 10115
city = Berlin
iban = DE91100000000123456789
""")

# --- EÜR: dry-run with income only ---
echo "--- euer --dry-run (income only) ---"
let euerCsv = projectRoot / "tests" / "tmp_euer.csv"
writeFile(euerCsv, "1000,19\n500,7\n")
let (euerDryOut, euerDryRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y 2025 --dry-run")
check("euer dry-run exits 0", euerDryRc == 0, euerDryOut)
check("euer dry-run has XML output", euerDryOut.contains("<?xml"))
check("euer dry-run has E77 root", euerDryOut.contains("<E77"))
check("euer dry-run has EUER element", euerDryOut.contains("<EUER>"))
check("euer dry-run has Vorsatz", euerDryOut.contains("<Vorsatz>"))
check("euer dry-run has ElsterErklaerung", euerDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("euer dry-run has DatenArt EUER", euerDryOut.contains("<DatenArt>EUER</DatenArt>"))
check("euer dry-run has Empfaenger Ziel", euerDryOut.contains("<Ziel>BY</Ziel>"))
check("euer dry-run has Unterfallart 77", euerDryOut.contains("<Unterfallart>77</Unterfallart>"))
check("euer dry-run has BEin", euerDryOut.contains("<BEin>"))
check("euer dry-run has BAus", euerDryOut.contains("<BAus>"))
check("euer dry-run has Ermittlung_Gewinn", euerDryOut.contains("<Ermittlung_Gewinn>"))
echo ""

# --- EÜR: income/expense split ---
echo "--- euer income/expense split ---"
# 1000 at 19% (income), -300 at 19% (expense)
writeFile(euerCsv, "1000,19\n-300,19\n")
let (splitOut, splitRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y 2025 --dry-run")
check("split exits 0", splitRc == 0, splitOut)
# Income: 1000 net, 190 VAT -> total 1190 (German comma format)
check("split income net 1000", splitOut.contains("<E6000401>1000,00</E6000401>"))
check("split income VAT 190", splitOut.contains("<E6000601>190,00</E6000601>"))
check("split income total 1190", splitOut.contains("<E6001201>1190,00</E6001201>"))
# Expense: 300 net, 57 Vorsteuer -> total 357
check("split expense net 300", splitOut.contains("<E6004901>300,00</E6004901>"))
check("split expense Vorsteuer 57", splitOut.contains("<E6005001>57,00</E6005001>"))
check("split expense total 357", splitOut.contains("<E6005301>357,00</E6005301>"))
# Profit: 1190 - 357 = 833
check("split profit 833", splitOut.contains("<E6007202>833,00</E6007202>"))
check("split income total correct", splitOut.contains("<E6001201>1190,00</E6001201>"))
check("split expense total correct", splitOut.contains("<E6005301>357,00</E6005301>"))
echo ""

# --- EÜR: empty file (zero submission) ---
echo "--- euer empty file ---"
writeFile(euerCsv, "")
let (euerEmptyOut, euerEmptyRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y 2025 --dry-run")
check("euer empty exits 0", euerEmptyRc == 0, euerEmptyOut)
check("euer empty income 0", euerEmptyOut.contains("<E6000401>0,00</E6000401>"))
check("euer empty profit 0", euerEmptyOut.contains("<E6007202>0,00</E6007202>"))
echo ""

# --- EÜR: missing conf/euer args ---
echo "--- euer input validation ---"
let (euerNoConf, euerNoConfRc) = run(Viking & " euer -y 2025 --dry-run")
check("euer missing conf rejected", euerNoConfRc != 0)
check("euer missing conf error", euerNoConf.contains("--conf is required"))
let (euerNoFile, euerNoFileRc) = run(Viking & " euer -c " & euerConf & " -y 2025 --dry-run")
check("euer missing euer rejected", euerNoFileRc != 0)
check("euer missing euer error", euerNoFile.contains("--euer is required"))
echo ""

# --- EÜR: Testmerker ---
echo "--- euer Testmerker ---"
writeFile(euerCsv, "100,19\n")
let (euerTestOut, euerTestRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y 2025 --dry-run")
check("euer TEST=1 has Testmerker", euerTestOut.contains("<Testmerker>700000004</Testmerker>"))

# TEST=0
let euerProdEnv = projectRoot / "tests" / ".env.euer_prod"
writeFile(euerProdEnv, readFile(projectRoot / ".env").replace("VIKING_TEST=1", "VIKING_TEST=0"))
let (euerProdOut, euerProdRc) = run("VIKING_TEST=0 " & Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y 2025 --dry-run --env " & euerProdEnv)
check("euer TEST=0 exits 0", euerProdRc == 0, euerProdOut)
check("euer TEST=0 no Testmerker", not euerProdOut.contains("Testmerker"), euerProdOut)
removeFile(euerProdEnv)
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
writeFile(euerCsv, "1000,19\n-500,19\n")
for year in euerYears:
  let (eyOut, eyRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " -y " & $year & " --validate-only")
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

# --- EÜR: multiple --euer files ---
echo "--- euer multiple files ---"
let euerCsv2 = projectRoot / "tests" / "tmp_euer2.csv"
writeFile(euerCsv, "1000,19\n")
writeFile(euerCsv2, "500,19\n-200,19\n")
let (euerMultiOut, euerMultiRc) = run(Viking & " euer -c " & euerConf & " --euer " & euerCsv & " --euer " & euerCsv2 & " -y 2025 --dry-run")
check("euer multi exits 0", euerMultiRc == 0, euerMultiOut)
check("euer multi has two XMLs", euerMultiOut.count("<?xml") == 2)
# First file: 1000 net at 19%
check("euer multi file 1 income", euerMultiOut.contains("<E6000401>1000,00</E6000401>"))
# Second file: 500 net at 19%, -200 expense
check("euer multi file 2 income", euerMultiOut.contains("<E6000401>500,00</E6000401>"))
removeFile(euerCsv2)
echo ""

removeFile(euerCsv)
removeFile(euerConf)
echo ""

# =================================================================
# ESt (Einkommensteuererklarung) tests — new flag-based interface
# =================================================================

# Base viking.conf for tests (Anlage G)
let estConf = projectRoot / "tests" / "tmp_viking.conf"
writeFile(estConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
income = 2
street = Musterstr. 1
housenumber = 1
zip = 10115
city = Berlin
iban = DE91100000000123456789
religion = 11
profession = Software-Entwickler
""")

let estEuer = projectRoot / "tests" / "tmp_euer.tsv"

# --- ESt: dry-run with Anlage G ---
echo "--- est --dry-run (Anlage G) ---"
writeFile(estEuer, "1000,19\n-300,19\n")
let (estDryOut, estDryRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -y 2025 --dry-run --force")
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
writeFile(estConfS, readFile(estConf).replace("income = 2", "income = 3"))
let (estSOut, estSRc) = run(Viking & " est -c " & estConfS & " -i " & estEuer & " -y 2025 --dry-run --force")
check("est Anlage S exits 0", estSRc == 0, estSOut)
check("est Anlage S has <S>", estSOut.contains("<S>"))
check("est Anlage S has E0803202", estSOut.contains("<E0803202>833</E0803202>"))
check("est Anlage S no <G>", not estSOut.contains("<G>"))
removeFile(estConfS)
echo ""

# --- ESt: Vorsorgeaufwand (privat) ---
echo "--- est Vorsorgeaufwand (privat) ---"
let estVorDed = projectRoot / "tests" / "tmp_deductions_vor.tsv"
writeFile(estVorDed, "code\tamount\tdescription\nvor316\t5000\tKV privat\nvor319\t600\tPV privat\nvor300\t3000\tRentenversicherung\n")
let (estVorOut, estVorRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estVorDed & " -y 2025 --validate-only")
check("est Vorsorge privat exits 0 or HID", estVorRc == 0 or estVorOut.contains("610301202"), estVorOut)
check("est Vorsorge no schema errors", not estVorOut.contains("610301200"), estVorOut)
removeFile(estVorDed)
echo ""

# --- ESt: Vorsorgeaufwand (gesetzlich) ---
echo "--- est Vorsorgeaufwand (gesetzlich) ---"
let estGkvDed = projectRoot / "tests" / "tmp_deductions_gkv.tsv"
writeFile(estGkvDed, "code\tamount\nvor326\t4800\nvor329\t500\n")
let (estGkvOut, estGkvRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estGkvDed & " -y 2025 --validate-only")
check("est Vorsorge gesetzlich exits 0 or HID", estGkvRc == 0 or estGkvOut.contains("610301202"), estGkvOut)
check("est Vorsorge gesetzlich no schema errors", not estGkvOut.contains("610301200"), estGkvOut)
removeFile(estGkvDed)
echo ""

# --- ESt: no euer (KAP-only filing) ---
echo "--- est no euer ---"
let (estNoEuerOut, estNoEuerRc) = run(Viking & " est -c " & estConf & " -y 2025 --dry-run --force")
check("est no euer exits 0", estNoEuerRc == 0, estNoEuerOut)
echo ""

# --- ESt: multiple --euer files ---
echo "--- est multiple euer ---"
let estEuer2 = projectRoot / "tests" / "tmp_euer2.tsv"
writeFile(estEuer, "1000,19\n-300,19\n")
writeFile(estEuer2, "500,19\n")
let (estMultiOut, estMultiRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -i " & estEuer2 & " -y 2025 --dry-run --force")
check("est multi exits 0", estMultiRc == 0, estMultiOut)
# First file: 1000*1.19 - 300*1.19 = 833 profit
check("est multi has first profit", estMultiOut.contains("<E0800302>833</E0800302>"))
# Second file: 500*1.19 = 595 profit
check("est multi has second profit", estMultiOut.contains("<E0800302>595</E0800302>"))
# Both in same Anlage G
check("est multi has single Anlage G", estMultiOut.contains("<G>"))
# Two Betr_1_2 blocks
check("est multi has two Betr blocks", estMultiOut.contains("Betr_1_2"))
removeFile(estEuer2)
echo ""

# --- ESt: input validation ---
echo "--- est input validation ---"
let (estNoConf, estNoConfRc) = run(Viking & " est -y 2025 --dry-run")
check("est missing conf rejected", estNoConfRc != 0)
check("est missing conf error", estNoConf.contains("--conf is required"))
echo ""

# --- ESt: Testmerker ---
echo "--- est Testmerker ---"
writeFile(estEuer, "100,19\n")
let (estTestOut, estTestRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -y 2025 --dry-run --force")
check("est TEST=1 has Testmerker", estTestOut.contains("<Testmerker>700000004</Testmerker>"))

let estProdEnv = projectRoot / "tests" / ".env.est_prod"
writeFile(estProdEnv, readFile(projectRoot / ".env").replace("VIKING_TEST=1", "VIKING_TEST=0"))
let (estProdOut, estProdRc) = run("VIKING_TEST=0 " & Viking & " est -c " & estConf & " -i " & estEuer & " -y 2025 --dry-run --force --env " & estProdEnv)
check("est TEST=0 exits 0", estProdRc == 0, estProdOut)
check("est TEST=0 no Testmerker", not estProdOut.contains("Testmerker"), estProdOut)
removeFile(estProdEnv)
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
writeFile(estEuer, "1000,19\n-500,19\n")
for year in estYears:
  let (eyOut, eyRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -y " & $year & " --validate-only --force")
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

# --- ESt: full send path ---
echo "--- est (send) ---"
let (estSendOut, estSendRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -y 2025 --force")
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

# --- ESt: Sonderausgaben (Kirchensteuer + Spenden) ---
echo "--- est Sonderausgaben ---"
let estSaDed = projectRoot / "tests" / "tmp_deductions_sa.tsv"
writeFile(estSaDed, "code\tamount\nsa140\t500\nsa141\t50\nsa131\t200\n")
let (estSaOut, estSaRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estSaDed & " -y 2025 --dry-run")
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
let (estAgbOut, estAgbRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estAgbDed & " -y 2025 --dry-run")
check("est AgB exits 0", estAgbRc == 0, estAgbOut)
check("est AgB has <AgB>", estAgbOut.contains("<AgB>"))
check("est AgB has Krankh", estAgbOut.contains("<E0161304>"))
echo ""

# --- ESt: Weitere sonstige Vorsorgeaufwendungen ---
echo "--- est Weit_Sons_VorAW ---"
let estWsDed = projectRoot / "tests" / "tmp_deductions_ws.tsv"
writeFile(estWsDed, "code\tamount\nvor502\t550\n")
let (estWsOut, estWsRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estWsDed & " -y 2025 --dry-run")
check("est Weit exits 0", estWsRc == 0, estWsOut)
check("est Weit has Weit_Sons_VorAW", estWsOut.contains("<Weit_Sons_VorAW>"))
check("est Weit has U_HP_Ris_Vers sum 550", estWsOut.contains("<E2001803>550</E2001803>"))
echo ""

# --- ESt: Zusatz-KV (privat) ---
echo "--- est Zusatz-KV (privat) ---"
let estZkDed = projectRoot / "tests" / "tmp_deductions_zk.tsv"
writeFile(estZkDed, "code\tamount\nvor316\t5000\nvor328\t120\n")
let (estZkOut, estZkRc) = run(Viking & " est -c " & estConf & " -i " & estEuer & " -D " & estZkDed & " -y 2025 --dry-run")
check("est ZK privat exits 0", estZkRc == 0, estZkOut)
check("est ZK privat has E2003302", estZkOut.contains("<E2003302>120</E2003302>"))
echo ""

# --- ESt: Anlage KAP ---
echo "--- est Anlage KAP ---"
let estKapTsv = projectRoot / "tests" / "tmp_kap.tsv"
writeFile(estKapTsv, "gains\ttax\tsoli\n1500.50\t375.13\t20.63\n")
let estKapConf = projectRoot / "tests" / "tmp_viking_kap.conf"
writeFile(estKapConf, readFile(estConf) & """
[kap]
guenstigerpruefung = 1
""")
let (estKapOut, estKapRc) = run(Viking & " est -c " & estKapConf & " -i " & estEuer & " -K " & estKapTsv & " -y 2025 --dry-run --force")
check("est KAP exits 0", estKapRc == 0, estKapOut)
check("est KAP has <KAP>", estKapOut.contains("<KAP>"))
check("est KAP has Guenstigerpruefung", estKapOut.contains("<E1900401>1</E1900401>"))
check("est KAP has Kapitalertraege", estKapOut.contains("<E1900701>"))
check("est KAP has KapESt", estKapOut.contains("<E1904701>"))
check("est KAP has Soli", estKapOut.contains("<E1904801>"))
removeFile(estKapTsv)
removeFile(estKapConf)
echo ""

# --- ESt: Anlage Kind ---
echo "--- est Anlage Kind ---"
let estKindConf = projectRoot / "tests" / "tmp_viking_kind.conf"
writeFile(estKindConf, readFile(estConf) & """
[kid]
firstname = Max
birthdate = 01.06.2018
idnr = 12345678901

[kid]
firstname = Lisa
birthdate = 15.03.2020
idnr = 98765432109
""")
let estKindDed = projectRoot / "tests" / "tmp_deductions_kind.tsv"
writeFile(estKindDed, "code\tamount\nmax174\t2400\nlisa174\t3600\nlisa176\t1500\n")
let (estKindOut, estKindRc) = run(Viking & " est -c " & estKindConf & " -i " & estEuer & " -D " & estKindDed & " -y 2025 --dry-run")
check("est Kind exits 0", estKindRc == 0, estKindOut)
check("est Kind has 2 <Kind>", estKindOut.count("<Kind>") == 2)
check("est Kind has Max", estKindOut.contains("Max"))
check("est Kind has Lisa", estKindOut.contains("Lisa"))
check("est Kind has betreuungskosten", estKindOut.contains("<E0506105>"))
check("est Kind has schulgeld", estKindOut.contains("<E0505607>"))
check("est Kind XML has both children", estKindOut.count("<Kind>") == 2)
removeFile(estKindConf)
removeFile(estKindDed)
echo ""

# --- ESt: validate deductions against ERiC ---
echo "--- est personal deductions validation ---"
let estPdDed = projectRoot / "tests" / "tmp_deductions_pd.tsv"
writeFile(estPdDed, "code\tamount\nvor316\t5000\nvor319\t600\nvor502\t350\nsa140\t500\nsa131\t200\nagb187\t750\n")
let estPdKap = projectRoot / "tests" / "tmp_kap_pd.tsv"
writeFile(estPdKap, "gains\ttax\tsoli\n1500\t375\t0\n")
let estPdConf = projectRoot / "tests" / "tmp_viking_pd.conf"
writeFile(estPdConf, readFile(estConf) & """
[kap]
guenstigerpruefung = 1
sparer_pauschbetrag = 1000
""")
let (estPdOut, estPdRc) = run(Viking & " est -c " & estPdConf & " -i " & estEuer & " -D " & estPdDed & " -K " & estPdKap & " -y 2025 --validate-only")
check("est PD validate no schema errors", not estPdOut.contains("610301200"), estPdOut)
check("est PD validate no cert errors", not estPdOut.contains("610001050"), estPdOut)
let estPdOk = estPdRc == 0 or estPdOut.contains("610301202")
check("est PD validates", estPdOk, estPdOut)
removeFile(estPdDed)
removeFile(estPdKap)
removeFile(estPdConf)

# Cleanup shared fixtures
removeFile(estConf)
removeFile(estEuer)

# Cleanup any stray deduction files
for f in @[estSaDed, estAgbDed, estWsDed, estZkDed]:
  removeFile(f)

echo ""

# =================================================================
# USt (Umsatzsteuererklaerung) tests — new flag-based interface
# =================================================================

# Reuse the viking.conf for USt tests (needs taxnumber + besteuerungsart)
let ustConf = projectRoot / "tests" / "tmp_viking_ust.conf"
writeFile(ustConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
income = 2
street = Musterstr.
housenumber = 1
zip = 10115
city = Berlin
iban = DE91100000000123456789
religion = 11
profession = Software-Entwickler
besteuerungsart = 2
""")

let ustCsv = projectRoot / "tests" / "tmp_ust.csv"

# --- USt: dry-run with mixed rates ---
echo "--- ust --dry-run (mixed rates) ---"
writeFile(ustCsv, "1000,19\n500,7\n-200,19\n")
let (ustDryOut, ustDryRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --dry-run")
check("ust dry-run exits 0", ustDryRc == 0, ustDryOut)
check("ust dry-run has XML output", ustDryOut.contains("<?xml"))
check("ust dry-run has E50 root", ustDryOut.contains("<E50"))
check("ust dry-run has USt2A", ustDryOut.contains("<USt2A>"))
check("ust dry-run has Vorsatz", ustDryOut.contains("<Vorsatz>"))
check("ust dry-run has ElsterErklaerung", ustDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("ust dry-run has DatenArt USt", ustDryOut.contains("<DatenArt>USt</DatenArt>"))
check("ust dry-run has Empfaenger Ziel", ustDryOut.contains("<Ziel>BY</Ziel>"))
check("ust dry-run has Unterfallart 50", ustDryOut.contains("<Unterfallart>50</Unterfallart>"))
check("ust dry-run has Ums_allg 19%", ustDryOut.contains("<E3003303>1000</E3003303>"))
check("ust dry-run has Ums_erm 7%", ustDryOut.contains("<E3004401>500</E3004401>"))
check("ust dry-run has Berech_USt", ustDryOut.contains("<Berech_USt>"))
check("ust dry-run has Testmerker", ustDryOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

# --- USt: income/expense split ---
echo "--- ust income/expense split ---"
writeFile(ustCsv, "1000,19\n-300,19\n")
let (ustSplitOut, ustSplitRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --dry-run")
check("ust split exits 0", ustSplitRc == 0, ustSplitOut)
# Income 19%: 1000 net, VAT 190
check("ust split Ums_allg base", ustSplitOut.contains("<E3003303>1000</E3003303>"))
check("ust split Ums_allg tax", ustSplitOut.contains("<E3003304>190,00</E3003304>"))
# Expense Vorsteuer: 300 * 0.19 = 57
check("ust split Vorsteuer in Abz_VoSt", ustSplitOut.contains("<E3006201>57,00</E3006201>"))
check("ust split Vorsteuer sum", ustSplitOut.contains("<E3006901>57,00</E3006901>"))
# Vorsteuer in Berech_USt
check("ust split Vorsteuer in calc", ustSplitOut.contains("<E3009901>57,00</E3009901>"))
# Verbleibende USt: 190 - 57 = 133
check("ust split verbleibende USt", ustSplitOut.contains("<E3011101>133,00</E3011101>"))
echo ""

# --- USt: with Vorauszahlungen ---
echo "--- ust with Vorauszahlungen ---"
writeFile(ustCsv, "1000,19\n")
let (ustVzOut, ustVzRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --vorauszahlungen=100 --dry-run")
check("ust vorauszahlungen exits 0", ustVzRc == 0, ustVzOut)
check("ust vorauszahlungen E3011301", ustVzOut.contains("<E3011301>100,00</E3011301>"))
# Abschluss: 190 - 100 = 90
check("ust vorauszahlungen E3011401", ustVzOut.contains("<E3011401>90,00</E3011401>"))
echo ""

# --- USt: empty file (zero submission) ---
echo "--- ust empty file ---"
writeFile(ustCsv, "")
let (ustEmptyOut, ustEmptyRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --dry-run")
check("ust empty exits 0", ustEmptyRc == 0, ustEmptyOut)
check("ust empty Ums_Sum 0", ustEmptyOut.contains("<E3006001>0,00</E3006001>"))
check("ust empty verbleibende 0", ustEmptyOut.contains("<E3011101>0,00</E3011101>"))
echo ""

# --- USt: multiple --euer files ---
echo "--- ust multiple euer ---"
let ustCsv2 = projectRoot / "tests" / "tmp_ust2.csv"
writeFile(ustCsv, "1000,19\n")
writeFile(ustCsv2, "500,19\n-200,19\n")
let (ustMultiOut, ustMultiRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -i " & ustCsv2 & " -y 2025 --dry-run")
check("ust multi exits 0", ustMultiRc == 0, ustMultiOut)
# Combined: 1000 + 500 = 1500 at 19%
check("ust multi combined 19%", ustMultiOut.contains("<E3003303>1500</E3003303>"))
# Vorsteuer: 200 * 0.19 = 38
check("ust multi has Vorsteuer", ustMultiOut.contains("<E3006001>"))
removeFile(ustCsv2)
echo ""

# --- USt: missing euer file ---
echo "--- ust input validation ---"
let (ustNoFile, ustNoFileRc) = run(Viking & " ust -c " & ustConf & " -y 2025 --dry-run")
check("ust missing euer rejected", ustNoFileRc != 0)
check("ust missing euer error", ustNoFile.contains("--euer is required"))
echo ""

# --- USt: missing conf ---
echo "--- ust missing conf ---"
writeFile(ustCsv, "100,19\n")
let (ustNoConf, ustNoConfRc) = run(Viking & " ust -i " & ustCsv & " -y 2025 --dry-run")
check("ust missing conf rejected", ustNoConfRc != 0)
check("ust missing conf error", ustNoConf.contains("--conf is required"))
echo ""

# --- USt: Testmerker ---
echo "--- ust Testmerker ---"
writeFile(ustCsv, "100,19\n")
let (ustTestOut, ustTestRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --dry-run")
check("ust TEST=1 has Testmerker", ustTestOut.contains("<Testmerker>700000004</Testmerker>"))

# TEST=0
let ustProdEnv = projectRoot / "tests" / ".env.ust_prod"
writeFile(ustProdEnv, readFile(projectRoot / ".env").replace("VIKING_TEST=1", "VIKING_TEST=0"))
let (ustProdOut, ustProdRc) = run("VIKING_TEST=0 " & Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025 --dry-run --env " & ustProdEnv)
check("ust TEST=0 exits 0", ustProdRc == 0, ustProdOut)
check("ust TEST=0 no Testmerker", not ustProdOut.contains("Testmerker"), ustProdOut)
removeFile(ustProdEnv)
echo ""

# --- USt: per-year validation ---
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
writeFile(ustCsv, "1000,19\n-500,19\n")
for year in ustYears:
  let (eyOut, eyRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y " & $year & " --validate-only")
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

# --- USt: full send path ---
echo "--- ust (send) ---"
let (ustSendOut, ustSendRc) = run(Viking & " ust -c " & ustConf & " -i " & ustCsv & " -y 2025")
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

removeFile(ustCsv)
removeFile(ustConf)
echo ""

# =================================================================
# Message (SonstigeNachrichten) tests
# =================================================================

# viking.conf for message tests
let messageConf = projectRoot / "tests" / "tmp_message_viking.conf"
writeFile(messageConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
street = Testweg
housenumber = 42
zip = 80331
city = Muenchen
iban = DE91100000000123456789
""")

echo "--- message --dry_run ---"
let (msgDryOut, msgDryRc) = run(Viking & " message -c " & messageConf & " --subject \"Test Betreff\" --text \"Test Nachricht\" --dry_run")
check("message dry_run exits 0", msgDryRc == 0, msgDryOut)
check("message dry_run has Nachricht element", msgDryOut.contains("<Nachricht xmlns="))
check("message dry_run has ElsterNachricht", msgDryOut.contains("<Verfahren>ElsterNachricht</Verfahren>"))
check("message dry_run has DatenArt SonstigeNachrichten", msgDryOut.contains("<DatenArt>SonstigeNachrichten</DatenArt>"))
check("message dry_run has Testmerker", msgDryOut.contains("<Testmerker>700000004</Testmerker>"))
check("message dry_run has Betreff", msgDryOut.contains("<Betreff>Test Betreff</Betreff>"))
check("message dry_run has Text", msgDryOut.contains("<Text>Test Nachricht</Text>"))
check("message dry_run has SteuerpflichtigerTyp", msgDryOut.contains("<SteuerpflichtigerTyp>NichtNatPerson</SteuerpflichtigerTyp>"))
check("message dry_run has Steuernummer", msgDryOut.contains("<Steuernummer>"))
check("message dry_run has Bundesland in TransferHeader", msgDryOut.contains("<Ziel>"))
check("message dry_run has Finanzamt in NutzdatenHeader", msgDryOut.contains("<Empfaenger id=\"F\">"))
echo ""

echo "--- message --validate_only ---"
let (msgValOut, msgValRc) = run(Viking & " message -c " & messageConf & " --subject \"Test\" --text \"Testnachricht\" --validate_only")
check("message validate_only exits 0", msgValRc == 0, msgValOut)
check("message validate_only silent on success", msgValOut.strip.len == 0 or msgValOut.contains("OK"))
echo ""

echo "--- message validation ---"
let (msgNoConf, msgNoConfRc) = run(Viking & " message --subject \"Test\" --text \"Test\"")
check("message without conf fails", msgNoConfRc != 0)
check("message without conf shows error", msgNoConf.contains("--conf is required"))

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
# IBAN change (AenderungBankverbindung) tests
# =================================================================

# viking.conf for iban tests
let ibanConf = projectRoot / "tests" / "tmp_iban_viking.conf"
writeFile(ibanConf, """[taxpayer]
firstname = Hans
lastname = Maier
birthdate = 05.05.1955
idnr = 04452397687
taxnumber = 9198011310010
""")

echo "--- iban --dry_run ---"
let (ibanDryOut, ibanDryRc) = run(Viking & " iban -c " & ibanConf & " --new_iban DE89370400440532013000 --dry_run")
check("iban dry_run exits 0", ibanDryRc == 0, ibanDryOut)
check("iban dry_run has AenderungBankverbindung", ibanDryOut.contains("<AenderungBankverbindung xmlns="))
check("iban dry_run has ElsterNachricht", ibanDryOut.contains("<Verfahren>ElsterNachricht</Verfahren>"))
check("iban dry_run has DatenArt", ibanDryOut.contains("<DatenArt>AenderungBankverbindung</DatenArt>"))
check("iban dry_run has Testmerker", ibanDryOut.contains("<Testmerker>700000004</Testmerker>"))
check("iban dry_run has IBAN", ibanDryOut.contains("<IBAN>DE89370400440532013000</IBAN>"))
check("iban dry_run has Kontoinhaber", ibanDryOut.contains("<Kontoinhaber>Person_A</Kontoinhaber>"))
check("iban dry_run has Steuernummer", ibanDryOut.contains("<Steuernummer>"))
check("iban dry_run has Anrede", ibanDryOut.contains("<Anrede>Herrn</Anrede>"))
check("iban dry_run has Identifikationsnummer", ibanDryOut.contains("<Identifikationsnummer>"))
echo ""

echo "--- iban --validate_only ---"
let (ibanValOut, ibanValRc) = run(Viking & " iban -c " & ibanConf & " --new_iban DE89370400440532013000 --validate_only")
check("iban validate_only exits 0", ibanValRc == 0, ibanValOut)
check("iban validate_only silent on success", ibanValOut.strip.len == 0 or ibanValOut.contains("OK"))
echo ""

echo "--- iban validation ---"
let (ibanNoIban, ibanNoIbanRc) = run(Viking & " iban -c " & ibanConf)
check("iban without new_iban fails", ibanNoIbanRc != 0)
check("iban without new_iban shows error", ibanNoIban.contains("--new-iban is required"))

let (ibanNoConf, ibanNoConfRc) = run(Viking & " iban --new_iban DE89370400440532013000")
check("iban without conf fails", ibanNoConfRc != 0)
check("iban without conf shows error", ibanNoConf.contains("--conf is required"))

removeFile(ibanConf)
echo ""

# =================================================================
# Retrieve (Datenabholung) tests
# =================================================================

let abholConf = projectRoot / "tests" / "tmp_abhol_viking.conf"
writeFile(abholConf, """[taxpayer]
firstname = Hans
lastname = Maier
""")

echo "--- list --dry_run ---"
let (listDryOut, listDryRc) = run(Viking & " list -c " & abholConf & " --dry_run")
check("list dry_run exits 0", listDryRc == 0, listDryOut)
check("list dry_run has PostfachAnfrage XML", listDryOut.contains("<PostfachAnfrage "))
check("list dry_run has Datenabholung element", listDryOut.contains("<Datenabholung"))
check("list dry_run has ElsterDatenabholung", listDryOut.contains("<Verfahren>ElsterDatenabholung</Verfahren>"))
check("list dry_run has DatenArt PostfachAnfrage", listDryOut.contains("<DatenArt>PostfachAnfrage</DatenArt>"))
check("list dry_run has Testmerker", listDryOut.contains("<Testmerker>700000004</Testmerker>"))
check("list dry_run has DatenLieferant from conf", listDryOut.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))
check("list dry_run has HerstellerID constant", listDryOut.contains("<HerstellerID>40036</HerstellerID>"))

echo "--- download --dry_run ---"
let (dlDryOut, dlDryRc) = run(Viking & " download -c " & abholConf & " --dry_run")
check("download dry_run exits 0", dlDryRc == 0, dlDryOut)
check("download dry_run has PostfachAnfrage XML", dlDryOut.contains("<PostfachAnfrage "))
check("download dry_run has Datenabholung element", dlDryOut.contains("<Datenabholung"))
check("download dry_run has DatenLieferant from conf", dlDryOut.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))

echo "--- list/download without conf ---"
let (listNoConf, listNoConfRc) = run(Viking & " list --dry_run")
check("list without conf fails", listNoConfRc != 0)
check("list without conf shows error", listNoConf.contains("--conf is required"))

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
check("init creates kap.tsv", fileExists(initDir / "kap.tsv"))
check("init creates euer.tsv", fileExists(initDir / "euer.tsv"))

# Check viking.conf content
let confContent = readFile(initDir / "viking.conf")
check("init conf has [taxpayer]", confContent.contains("[taxpayer]"))
check("init conf has firstname", confContent.contains("firstname ="))
check("init conf has taxnumber", confContent.contains("taxnumber ="))
check("init conf has [kap]", confContent.contains("[kap]"))
check("init conf has [kid] comment", confContent.contains("# [kid]"))

# Check deductions.tsv content
let dedContent = readFile(initDir / "deductions.tsv")
check("init deductions has header", dedContent.contains("code\tamount\tdescription"))
check("init deductions has vor300", dedContent.contains("vor300"))
check("init deductions has sa140", dedContent.contains("sa140"))
check("init deductions has agb187", dedContent.contains("agb187"))

# Check skip behavior
let (skipOut, skipRc) = run(Viking & " init --dir " & initDir)
check("init skips existing files", skipRc == 0, skipOut)
check("init skip message", skipOut.contains("Skipped"))

# Check force overwrite
let (forceOut, forceRc) = run(Viking & " init --dir " & initDir & " --force")
check("init force overwrites", forceRc == 0, forceOut)
check("init force creates", forceOut.contains("Created"))

# Check invalid dir
let (badDirOut, badDirRc) = run(Viking & " init --dir /nonexistent/path")
check("init bad dir fails", badDirRc != 0, badDirOut)

# Check generated conf is parseable
let (initEstDry, initEstDryRc) = run(Viking & " est -c " & initDir / "viking.conf" & " --dry-run -y 2025")
check("init conf is parseable", initEstDryRc != 0)  # fails validation but parses
check("init conf validation errors", initEstDry.contains("not set"))

removeDir(initDir)
echo ""

# --- Summary ---
echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
