## End-to-end sandbox tests for viking
## Requires: ERiC library + test certificates in test/cache (run `viking fetch` first)

import std/[osproc, strutils, os]

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

# --- Submit: input validation ---
echo "--- input validation ---"
let (noperiod, noperiodRc) = run("./viking submit --amount19 100")
check("missing --period is rejected", noperiodRc != 0)
check("missing --period shows error", noperiod.contains("--period is required"))

let (noamt, noamtRc) = run("./viking submit --p 41")
check("missing amounts is rejected", noamtRc != 0)
check("missing amounts shows error", noamt.toLowerAscii.contains("at least one"))

let (badperiod, badperiodRc) = run("./viking submit --p 99 --amount19 100")
check("invalid period is rejected", badperiodRc != 0)
check("invalid period shows error", badperiod.contains("Invalid period"))
echo ""

# --- Summary ---
echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
