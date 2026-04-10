## End-to-end sandbox tests for viking
## Requires: ERiC library + test certificates in test/cache (run `viking fetch` first)

import std/[osproc, strutils, os, algorithm]

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

# --- Prerequisite check ---
echo "--- Prerequisites ---"
let envExists = fileExists(".env")
check("dotenv file exists", envExists)

let binaryExists = fileExists("viking")
check("viking binary exists", binaryExists)
if not binaryExists:
  echo "Build with `nimble build` first."
  quit(1)

let (fetchCheck, fetchCheckRc) = run("./viking fetch --check")
let ericInstalled = fetchCheckRc == 0
check("ERiC installation found", ericInstalled, fetchCheck)
if not ericInstalled:
  echo "Run `viking fetch` first to download ERiC + test certs."
  quit(1)
echo ""

# --- Fetch command ---
echo "--- fetch ---"
check("fetch --check succeeds", fetchCheckRc == 0)
check("fetch --check shows version", fetchCheck.contains("ERiC"))
echo ""

# --- Submit: dry-run ---
echo "--- submit --dry-run ---"
let (dryOut, dryRc) = run("./viking submit --p 41 --amount19 1000 --dry-run")
check("dry-run exits 0", dryRc == 0, "exit code: " & $dryRc)
check("dry-run loads ERiC", dryOut.contains("ERiC library loaded"))
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
writeFile(prodEnv, readFile(projectRoot / ".env").replace("TEST=1", "TEST=0"))
let (prodOut, prodRc) = run("./viking submit --p 41 --amount19 0 --dry-run --env " & prodEnv)
check("TEST=0 dry-run exits 0", prodRc == 0, prodOut)
check("TEST=0 no Testmerker", not prodOut.contains("Testmerker"), prodOut)

let (testOut, testRc) = run("./viking submit --p 41 --amount19 0 --dry-run")
check("TEST=1 dry-run exits 0", testRc == 0, testOut)
check("TEST=1 has Testmerker", testOut.contains("<Testmerker>700000004</Testmerker>"))
removeFile(prodEnv)
echo ""

# --- Submit: dry-run with both rates ---
echo "--- submit --dry-run (19% + 7%) ---"
let (dryBoth, dryBothRc) = run("./viking submit --p 01 --amount19 500 --amount7 200 --dry-run")
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
let (valOut, valRc) = run("./viking submit --p 41 --amount19 0 --validate-only")
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
let (sendOut, sendRc) = run("./viking submit --p 41 --amount19 0")
let sendSchemaOk = not sendOut.contains("610301200")
let sendCertOk = not sendOut.contains("610001050")
check("send: no XML schema errors", sendSchemaOk, sendOut)
check("send: no certificate errors", sendCertOk, sendOut)
let sendHidBlocked = sendOut.contains("610301202")
if sendRc == 0:
  check("send: succeeds", true)
elif sendHidBlocked:
  check("send: only HerstellerID issue (expected with demo ID)", true)
  check("send: shows actionable hint", sendOut.contains("HERSTELLER_ID"))
else:
  check("send: unexpected error", false, sendOut)
echo ""

# --- Per-year validation ---
echo "--- per-year validation (2025+) ---"
# Discover available UStVA years from plugin files
let pluginPath = getEnv("ERIC_PLUGIN_PATH", "test/cache/eric/ERiC-43.3.2.0/Linux-x86_64/lib/plugins")
var years: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    if name.startsWith("libcheckUStVA_") and name.endsWith(".so"):
      try:
        let y = parseInt(name[14..^4])
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
    let cmd = "./viking submit --p 41 " & combo.args & " --year " & $year & " --validate-only"
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
let (noperiod, noperiodRc) = run("./viking submit --amount19 100")
check("missing --period is rejected", noperiodRc != 0)
check("missing --period shows error", noperiod.contains("--period is required"))

let (noamt, noamtRc) = run("./viking submit --p 41")
check("missing amounts is rejected", noamtRc != 0)
check("missing amounts shows error", noamt.contains("--amount19") or noamt.contains("--invoice-file"))

let (badperiod, badperiodRc) = run("./viking submit --p 99 --amount19 100")
check("invalid period is rejected", badperiodRc != 0)
check("invalid period shows error", badperiod.contains("Invalid period"))
echo ""

# --- Invoice input ---
echo "--- invoice input (CSV) ---"
let invCsv = projectRoot / "tests" / "tmp_invoices.csv"

# Test 1: CSV with header + mixed rates + negative amount
writeFile(invCsv, "amount,rate,date,invoice-id,description\n1000,19,2026-01-15,INV-001,January sales\n500,7,2026-01-20,INV-002,Reduced rate\n-200,19,2026-01-25,CR-001,Credit note\n")
let (csvOut, csvRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("CSV mixed rates exits 0", csvRc == 0, csvOut)
check("CSV shows invoice count", csvOut.contains("Count:    3"))
check("CSV Kz81 = 800 (1000-200)", csvOut.contains("<Kz81>800</Kz81>"))
check("CSV Kz86 = 500", csvOut.contains("<Kz86>500</Kz86>"))
# 800*0.19 + 500*0.07 = 152 + 35 = 187
check("CSV Kz83 = 187.00", csvOut.contains("<Kz83>187.00</Kz83>"))
check("CSV shows sum 19%", csvOut.contains("Sum 19%:  800.00 EUR"))
check("CSV shows sum 7%", csvOut.contains("Sum 7%:   500.00 EUR"))
echo ""

# Test 2: TSV without header (auto-detect)
echo "--- invoice input (TSV) ---"
let invTsv = projectRoot / "tests" / "tmp_invoices.tsv"
writeFile(invTsv, "750\t19\n250\t7\n")
let (tsvOut, tsvRc) = run("./viking submit -i " & invTsv & " --p 01 --dry-run")
check("TSV auto-detect exits 0", tsvRc == 0, tsvOut)
check("TSV Kz81 = 750", tsvOut.contains("<Kz81>750</Kz81>"))
check("TSV Kz86 = 250", tsvOut.contains("<Kz86>250</Kz86>"))
removeFile(invTsv)
echo ""

# Test 3: Amount-only (single column, default rate 19%)
echo "--- invoice input (amount-only) ---"
writeFile(invCsv, "100\n200\n300\n")
let (amtOut, amtRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("amount-only exits 0", amtRc == 0, amtOut)
check("amount-only Kz81 = 600", amtOut.contains("<Kz81>600</Kz81>"))
check("amount-only no Kz86", not amtOut.contains("<Kz86>"))
echo ""

# Test 4: Mutual exclusivity (--invoices + --amount19 rejected)
echo "--- invoice mutual exclusivity ---"
writeFile(invCsv, "100\n")
let (mutexOut, mutexRc) = run("./viking submit -i " & invCsv & " --amount19 100 --p 01 --dry-run")
check("mutex rejected", mutexRc != 0)
check("mutex shows error", mutexOut.contains("mutually exclusive"))
echo ""

# Test 5: Empty file -> zero submission
echo "--- invoice empty file ---"
writeFile(invCsv, "")
let (emptyOut, emptyRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("empty file exits 0", emptyRc == 0, emptyOut)
check("empty file count 0", emptyOut.contains("Count:    0"))
check("empty file has Kz81 = 0", emptyOut.contains("<Kz81>0</Kz81>"))
echo ""

# Test 6: Validation errors (bad amount, bad rate)
echo "--- invoice validation errors ---"
writeFile(invCsv, "100,19\nabc,19\n100,99\n")
let (valErrOut, valErrRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("validation errors rejected", valErrRc != 0)
check("bad amount reported", valErrOut.contains("line 2") and valErrOut.contains("invalid amount"))
check("bad rate reported", valErrOut.contains("line 3") and valErrOut.contains("invalid rate"))
echo ""

# Test: 0% rate (Kz45 - non-taxable)
echo "--- invoice 0% rate (Kz45) ---"
writeFile(invCsv, "1000,19\n500,0\n")
let (kz45Out, kz45Rc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("0% rate exits 0", kz45Rc == 0, kz45Out)
check("0% rate has Kz45 = 500", kz45Out.contains("<Kz45>500</Kz45>"))
check("0% rate has Kz81 = 1000", kz45Out.contains("<Kz81>1000</Kz81>"))
check("0% rate Kz83 excludes 0%", kz45Out.contains("<Kz83>190.00</Kz83>"))
check("0% rate shows sum 0%", kz45Out.contains("Sum 0%:   500.00 EUR"))
echo ""

# Test: Period filtering
echo "--- invoice period filtering ---"
# Invoices spanning Q1 and Q2 2026
writeFile(invCsv, "amount,rate,date,invoice-id,description\n1000,19,2026-01-15,INV-001,Jan\n500,19,2026-02-10,INV-002,Feb\n300,7,2026-04-05,INV-003,Apr\n200,19,2026-06-20,INV-004,Jun\n")

# Q1 should get Jan + Feb only
let (q1Out, q1Rc) = run("./viking submit -i " & invCsv & " --p 41 -y 2026 --dry-run")
check("Q1 filter exits 0", q1Rc == 0, q1Out)
check("Q1 filter Kz81 = 1500", q1Out.contains("<Kz81>1500</Kz81>"))
check("Q1 filter no Kz86", not q1Out.contains("<Kz86>"))
check("Q1 filter shows filtered count", q1Out.contains("filtered to 2"))

# Q2 should get Apr + Jun
let (q2Out, q2Rc) = run("./viking submit -i " & invCsv & " --p 42 -y 2026 --dry-run")
check("Q2 filter exits 0", q2Rc == 0, q2Out)
check("Q2 filter Kz81 = 200", q2Out.contains("<Kz81>200</Kz81>"))
check("Q2 filter Kz86 = 300", q2Out.contains("<Kz86>300</Kz86>"))
check("Q2 filter shows filtered count", q2Out.contains("filtered to 2"))

# Monthly: January only
let (janOut, janRc) = run("./viking submit -i " & invCsv & " --p 01 -y 2026 --dry-run")
check("Jan filter exits 0", janRc == 0, janOut)
check("Jan filter Kz81 = 1000", janOut.contains("<Kz81>1000</Kz81>"))
check("Jan filter shows filtered count", janOut.contains("filtered to 1"))

# Wrong year -> zero submission
let (wrongYrOut, wrongYrRc) = run("./viking submit -i " & invCsv & " --p 41 -y 2025 --dry-run")
check("wrong year filter exits 0", wrongYrRc == 0, wrongYrOut)
check("wrong year shows filtered to 0", wrongYrOut.contains("filtered to 0"))

# Undated invoices excluded with warning
writeFile(invCsv, "1000,19,2026-01-15,INV-001,dated\n500,19\n")
let (undatedOut, undatedRc) = run("./viking submit -i " & invCsv & " --p 01 -y 2026 --dry-run 2>&1")
check("undated filter exits 0", undatedRc == 0, undatedOut)
check("undated shows warning", undatedOut.contains("without date"))
check("undated Kz81 = 1000", undatedOut.contains("<Kz81>1000</Kz81>"))
echo ""

# Test 7: Header-only file -> zero submission
echo "--- invoice header-only ---"
writeFile(invCsv, "amount,rate,date\n")
let (hdrOut, hdrRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("header-only exits 0", hdrRc == 0, hdrOut)
check("header-only count 0", hdrOut.contains("Count:    0"))
echo ""

# Test 8: Comment lines skipped
echo "--- invoice comments ---"
writeFile(invCsv, "# This is a comment\n100,19\n# Another comment\n200,7\n")
let (cmtOut, cmtRc) = run("./viking submit -i " & invCsv & " --p 01 --dry-run")
check("comments exits 0", cmtRc == 0, cmtOut)
check("comments count 2", cmtOut.contains("Count:    2"))
check("comments Kz81 = 100", cmtOut.contains("<Kz81>100</Kz81>"))
check("comments Kz86 = 200", cmtOut.contains("<Kz86>200</Kz86>"))

removeFile(invCsv)
echo ""

# =================================================================
# EÜR (Einnahmenüberschussrechnung) tests
# =================================================================

# --- EÜR: dry-run with income only ---
echo "--- euer --dry-run (income only) ---"
let euerCsv = projectRoot / "tests" / "tmp_euer.csv"
writeFile(euerCsv, "1000,19\n500,7\n")
let (euerDryOut, euerDryRc) = run("./viking euer -i " & euerCsv & " -y 2025 --dry-run")
check("euer dry-run exits 0", euerDryRc == 0, euerDryOut)
check("euer dry-run loads ERiC", euerDryOut.contains("ERiC library loaded"))
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
let (splitOut, splitRc) = run("./viking euer -i " & euerCsv & " -y 2025 --dry-run")
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
check("split shows income count", splitOut.contains("Income:    1 invoices"))
check("split shows expense count", splitOut.contains("Expenses:  1 invoices"))
echo ""

# --- EÜR: empty file (zero submission) ---
echo "--- euer empty file ---"
writeFile(euerCsv, "")
let (euerEmptyOut, euerEmptyRc) = run("./viking euer -i " & euerCsv & " -y 2025 --dry-run")
check("euer empty exits 0", euerEmptyRc == 0, euerEmptyOut)
check("euer empty income 0", euerEmptyOut.contains("<E6000401>0,00</E6000401>"))
check("euer empty profit 0", euerEmptyOut.contains("<E6007202>0,00</E6007202>"))
echo ""

# --- EÜR: missing invoice file ---
echo "--- euer input validation ---"
let (euerNoFile, euerNoFileRc) = run("./viking euer -y 2025 --dry-run")
check("euer missing invoice rejected", euerNoFileRc != 0)
check("euer missing invoice error", euerNoFile.contains("--invoice-file is required"))
echo ""

# --- EÜR: Testmerker ---
echo "--- euer Testmerker ---"
writeFile(euerCsv, "100,19\n")
let (euerTestOut, euerTestRc) = run("./viking euer -i " & euerCsv & " -y 2025 --dry-run")
check("euer TEST=1 has Testmerker", euerTestOut.contains("<Testmerker>700000004</Testmerker>"))

# TEST=0
let euerProdEnv = projectRoot / "tests" / ".env.euer_prod"
writeFile(euerProdEnv, readFile(projectRoot / ".env").replace("TEST=1", "TEST=0"))
let (euerProdOut, euerProdRc) = run("./viking euer -i " & euerCsv & " -y 2025 --dry-run --env " & euerProdEnv)
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
    if name.startsWith("libcheckEUER_") and name.endsWith(".so"):
      try:
        let y = parseInt(name[13..^4])
        if y >= 2025:
          euerYears.add(y)
      except ValueError:
        discard
euerYears.sort()

check("found EUER plugins for 2025+", euerYears.len > 0, "plugins in: " & pluginPath)
writeFile(euerCsv, "1000,19\n-500,19\n")
for year in euerYears:
  let (eyOut, eyRc) = run("./viking euer -i " & euerCsv & " -y " & $year & " --validate-only")
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

removeFile(euerCsv)
echo ""

# --- Summary ---
echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
