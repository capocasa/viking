## End-to-end smoke test for the example/ project.
## Copies example/ to tests/tmp_example/, wires up the public ELSTER test
## cert via [auth], and runs every subcommand. Data comes from TSVs
## referenced by source.euer= in viking.conf; the tax year comes from
## personal.year.

import std/[osproc, os, strutils]
import viking/ericsetup

when defined(windows):
  const Viking = "viking.exe"
else:
  const Viking = "./viking"

let projectRoot = currentSourcePath().parentDir.parentDir
setCurrentDir(projectRoot)

var failures = 0
var passes = 0

proc check(name: string, ok: bool, detail: string = "") =
  if ok:
    inc passes
    echo "  PASS: ", name
  else:
    inc failures
    echo "  FAIL: ", name
    if detail.len > 0: echo "        ", detail

proc run(cmd: string): tuple[output: string, code: int] =
  let (output, code) = execCmdEx(cmd)
  (output.strip, code)

func validateOk(out_text: string, rc: int): bool =
  ## True on clean exit OR only the HerstellerID-blocked status expected
  ## in CI when using the demo HID.
  rc == 0 or out_text.contains("610301202")

func structuralOk(outText: string, rc: int): bool =
  ## Allow plausibility failures (610001002) for structural inspection —
  ## demo data (fake IDNRs etc.) often fails ELSTER's plausi checks.
  rc == 0 or outText.contains("610301202") or outText.contains("610001002")

echo "=== example/ project E2E tests ==="
echo ""

check("viking binary exists", fileExists(Viking))
if not fileExists(Viking):
  echo "Build first: nimble build"
  quit(1)

let (_, fcRc) = run(Viking & " fetch --check")
check("ERiC installed", fcRc == 0)
if fcRc != 0:
  echo "Run: viking fetch"
  quit(1)

let testXdgHome = projectRoot / "tests" / "tmp_xdg_example"
createDir(testXdgHome)
putEnv("XDG_CONFIG_HOME", testXdgHome)

let tmp = projectRoot / "tests" / "tmp_example"
removeDir(tmp)
copyDir(projectRoot / "example", tmp)

let testCertPath = getAppDataDir() / "certificates" / "test-softorg-pse.pfx"
let testCertAvailable = fileExists(testCertPath)
let confPath = tmp / "viking.conf"
let rawConf = readFile(confPath)
let authIdx = rawConf.find("[auth]")
let baseConf = if authIdx >= 0: rawConf[0 ..< authIdx] else: rawConf
let authBlock = "\n[auth]\ncert = " & testCertPath &
                "\npin = " & (tmp / "viking.pin") & "\n"
writeFile(confPath, baseConf & authBlock)

proc inEx(args: string): tuple[output: string, code: int] =
  run("cd " & tmp & " && " & projectRoot / Viking & " " & args)

# -----------------------------------------------------------------
# Conf parses
# -----------------------------------------------------------------
echo "--- conf parses ---"
let (h, hRc) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
check("conf parses", hRc == 0, h)
check("personal taxnumber in XML", h.contains("<Steuernummer>9198011310010</Steuernummer>"))
echo ""

# -----------------------------------------------------------------
# Multi-source dispatch
# -----------------------------------------------------------------
echo "--- multi-source dispatch ---"
let (amb, ambRc) = inEx("ustva --test --period q1 --dry-run -v")
check("ambiguous source rejected", ambRc != 0)
check("error lists sources", amb.contains("freiberuf") and amb.contains("gewerbe"))

let (gw, _) = inEx("ustva gewerbe --test --period q1 --dry-run -v")
check("gewerbe inherits personal taxnumber",
      gw.contains("<Steuernummer>9198011310010</Steuernummer>"))
echo ""

# -----------------------------------------------------------------
# Period aliases
# -----------------------------------------------------------------
echo "--- period aliases ---"
let (pMar, _) = inEx("ustva freiberuf --test --period mar --dry-run -v")
check("period mar -> 03", pMar.contains("<Zeitraum>03</Zeitraum>"))
let (pQ1, _) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
check("period q1 -> 41", pQ1.contains("<Zeitraum>41</Zeitraum>"))
let (p3, _) = inEx("ustva freiberuf --test --period 3 --dry-run -v")
check("period 3 -> 03 (padded)", p3.contains("<Zeitraum>03</Zeitraum>"))
echo ""

# -----------------------------------------------------------------
# TSV load + period filter
# -----------------------------------------------------------------
echo "--- TSV load + period filter ---"
let (uQ1, uQ1Rc) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
check("Q1 ok", uQ1Rc == 0, uQ1)
check("Q1 Jan+Feb summed (1200+800)", uQ1.contains("<Kz81>2000</Kz81>"))

let (uQ2, _) = inEx("ustva freiberuf --test --period q2 --dry-run -v")
check("Q2 19% (Apr+May)", uQ2.contains("<Kz81>2400</Kz81>"))
check("Q2 7% (May)", uQ2.contains("<Kz86>500</Kz86>"))
echo ""

# -----------------------------------------------------------------
# EÜR per source — rechtsform translation
# -----------------------------------------------------------------
echo "--- EÜR per source ---"
let (eF, eFRc) = inEx("euer freiberuf --test --dry-run -v")
check("euer freiberuf ok", eFRc == 0, eF)
check("rechtsform freiberuf -> 140", eF.contains("<E6000602>140</E6000602>"))

let (eM, eMRc) = inEx("euer gewerbe --test --dry-run -v")
check("euer gewerbe ok", eMRc == 0, eM)
check("rechtsform einzel -> 120", eM.contains("<E6000602>120</E6000602>"))
echo ""

# -----------------------------------------------------------------
# Annual USt + vorauszahlungen
# -----------------------------------------------------------------
echo "--- USt + vorauszahlungen ---"
let (u, uRc) = inEx("ust gewerbe --test --dry-run -v")
check("ust dry-run ok", uRc == 0, u)
check("vorauszahlungen=100", u.contains("<E3011301>100,00</E3011301>"))
check("besteuerungsart soll -> 1", u.contains("<E3002203>1</E3002203>"))
echo ""

# -----------------------------------------------------------------
# ESt: full aggregation
# -----------------------------------------------------------------
echo "--- ESt aggregation ---"
let (e, eRc) = inEx("est --test --dry-run -v")
check("est dry-run ok", structuralOk(e, eRc), e)
check("Anlage G (gewerbe)", e.contains("<G>"))
check("Anlage S (freiberuf)", e.contains("<S>"))
check("Anlage KAP (ibkr)", e.contains("<KAP>"))
check("two Anlage Kind", e.count("<Kind>") == 2)
check("KAP guenstigerpruefung", e.contains("<E1900401>1</E1900401>"))
check("religion rk -> 03", e.contains("<E0100402>03</E0100402>"))
check("Sonderausgaben Spenden", e.contains("<E0108105>"))
check("AgB Krankheitskosten", e.contains("<E0161304>"))
check("Anlage Kind Betreuungskosten", e.contains("<E0506105>"))
check("Anlage Kind Schulgeld", e.contains("<E0505607>"))
check("Vorsorge KV privat", e.contains("<E2003104>"))
check("Testmerker", e.contains("<Testmerker>700000004</Testmerker>"))
echo ""

# -----------------------------------------------------------------
# Postfach list / download
# -----------------------------------------------------------------
echo "--- Postfach list/download ---"
let (l, lRc) = inEx("list --dry-run -v")
check("list dry-run ok", lRc == 0, l)
check("PostfachAnfrage", l.contains("<PostfachAnfrage "))
check("DatenLieferant", l.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))

let (d, dRc) = inEx("download --dry-run -v")
check("download dry-run ok", dRc == 0, d)
check("download PostfachAnfrage", d.contains("<PostfachAnfrage "))
echo ""

# -----------------------------------------------------------------
# IBAN / message
# -----------------------------------------------------------------
echo "--- iban + message ---"
let (ib, ibRc) = inEx("iban --test --new-iban DE89370400440532013000 --dry-run -v")
check("iban dry-run ok", ibRc == 0, ib)
check("iban IBAN", ib.contains("<IBAN>DE89370400440532013000</IBAN>"))

let (msg, msgRc) = inEx("message --test --subject \"Hallo\" --text \"Test\" --dry-run -v")
check("message dry-run ok", msgRc == 0, msg)
check("message Betreff", msg.contains("<Betreff>Hallo</Betreff>"))
echo ""

# -----------------------------------------------------------------
# ELSTER validation (--test + dry-run runs ERiC validate)
# -----------------------------------------------------------------
if testCertAvailable:
  echo "--- ELSTER validation ---"
  let (vU, vURc) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
  check("UStVA validates", validateOk(vU, vURc), vU)
  check("UStVA no schema errors", not vU.contains("610301200"))

  let (vE, vERc) = inEx("euer freiberuf --test --dry-run -v")
  check("EÜR validates", validateOk(vE, vERc), vE)
  check("EÜR no schema errors", not vE.contains("610301200"))

  let (vUst, vUstRc) = inEx("ust gewerbe --test --dry-run -v")
  check("USt validates", validateOk(vUst, vUstRc), vUst)
  check("USt no schema errors", not vUst.contains("610301200"))

  let (vEst, _) = inEx("est --test --dry-run -v --verbose")
  check("ESt no schema errors", not vEst.contains("610301200"))
  check("ESt Kind 100500048 not triggered",
        not vEst.contains("Regel_Kind_2020_100500048"))
  check("ESt Kind 100500001 not triggered",
        not vEst.contains("Kind_Kindschaftsverhaeltnis_100500001"))
  echo ""

  # ---------------------------------------------------------------
  # pincmd shell command (copyDir drops the exec bit — reinstate it)
  # ---------------------------------------------------------------
  echo "--- pincmd shell command ---"
  let pinShPath = tmp / "viking.pin.sh"
  setFilePermissions(pinShPath,
    getFilePermissions(pinShPath) + {fpUserExec, fpGroupExec, fpOthersExec})
  writeFile(confPath, baseConf &
    "\n[auth]\ncert = " & testCertPath &
    "\npincmd = ./viking.pin.sh\n")
  let (pc, pcRc) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
  check("pincmd shell command accepted", validateOk(pc, pcRc), pc)
  echo ""

  # ---------------------------------------------------------------
  # Inline pin (value is the PIN itself, not a file path)
  # ---------------------------------------------------------------
  echo "--- inline pin ---"
  writeFile(confPath, baseConf &
    "\n[auth]\ncert = " & testCertPath & "\npin = 123456\n")
  let (ip, ipRc) = inEx("ustva freiberuf --test --period q1 --dry-run -v")
  check("inline pin accepted", validateOk(ip, ipRc), ip)
  echo ""
else:
  echo "  SKIP: ELSTER validation tests (test cert not at " & testCertPath & ")"
  echo "  Install with: wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip"
  echo ""

removeDir(tmp)
removeDir(testXdgHome)

echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0: quit(1)
