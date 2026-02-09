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
for year in years:
  let (yearOut, yearRc) = run("./viking submit --p 41 --amount19 1000 --year " & $year & " --validate-only")
  let yearSchemaOk = not yearOut.contains("610301200")
  let yearCertOk = not yearOut.contains("610001050")
  let yearHidBlocked = yearOut.contains("610301202")
  let yearOk = yearRc == 0 or yearHidBlocked
  check($year & " schema valid", yearSchemaOk, yearOut)
  check($year & " no cert errors", yearCertOk, yearOut)
  if yearOk:
    check($year & " passes validation", true)
  else:
    check($year & " passes validation", false, yearOut)
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

# --- Summary ---
echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
