## End-to-end smoke test for the example/ project.
## Copies example/ to tests/tmp_example/, wires up the public ELSTER test
## cert via [auth], and runs every submission command. High-level: each
## subcommand should produce reasonable XML and (where applicable) pass
## ELSTER schema validation in --test mode.

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
  ## True on clean exit OR only the HerstellerID-blocked status that's
  ## expected in CI when using the demo HID.
  rc == 0 or out_text.contains("610301202")

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

# Isolate from user's global conf
let testXdgHome = projectRoot / "tests" / "tmp_xdg_example"
createDir(testXdgHome)
putEnv("XDG_CONFIG_HOME", testXdgHome)

# Stage a working copy of example/ that we can mutate
let tmp = projectRoot / "tests" / "tmp_example"
removeDir(tmp)
copyDir(projectRoot / "example", tmp)

# Wire up the public ELSTER test cert via [auth]
let testCertPath = getAppDataDir() / "certificates" / "test-softorg-pse.pfx"
let testCertAvailable = fileExists(testCertPath)
let confPath = tmp / "viking.conf"
let baseConf = readFile(confPath)
let authBlock = "\n[auth]\ncert = " & testCertPath &
                "\npin = " & (tmp / "viking.pin") & "\n"
writeFile(confPath, baseConf & authBlock)

proc inEx(args: string): tuple[output: string, code: int] =
  ## Run a viking subcommand from inside the example dir.
  run("cd " & tmp & " && " & projectRoot / Viking & " " & args)

# -----------------------------------------------------------------
# Conf parses with the full feature kit (words, KAP, kids, spouse)
# -----------------------------------------------------------------
echo "--- conf parses with all features ---"
let (h, hRc) = inEx("submit freelance --test --period q1 --amount19 0 --dry-run")
check("conf with words/spouse/kids/KAP parses", hRc == 0, h)
check("personal taxnumber in XML", h.contains("<Steuernummer>9198011310010</Steuernummer>"))
echo ""

# -----------------------------------------------------------------
# Multi-source: ambiguous without name; explicit picks the right one
# -----------------------------------------------------------------
echo "--- multi-source dispatch ---"
let (amb, ambRc) = inEx("submit --test --period q1 --amount19 0 --dry-run")
check("ambiguous source rejected", ambRc != 0)
check("error lists every source", amb.contains("freelance") and
                                   amb.contains("mygewerbe"))

let (gw, _) = inEx("submit mygewerbe --test --period q1 --amount19 0 --dry-run")
check("mygewerbe -> inherits personal taxnumber",
      gw.contains("<Steuernummer>9198011310010</Steuernummer>"))
echo ""

# -----------------------------------------------------------------
# Period aliases (word, padded numeric, unpadded numeric)
# -----------------------------------------------------------------
echo "--- period word/number aliases ---"
let (pMar, _) = inEx("submit freelance --test --period mar --amount19 100 --dry-run")
check("period mar -> 03", pMar.contains("<Zeitraum>03</Zeitraum>"))
let (pQ1,  _) = inEx("submit freelance --test --period q1  --amount19 100 --dry-run")
check("period q1 -> 41", pQ1.contains("<Zeitraum>41</Zeitraum>"))
let (p3,   _) = inEx("submit freelance --test --period 3   --amount19 100 --dry-run")
check("period 3 -> 03 (padded)", p3.contains("<Zeitraum>03</Zeitraum>"))
echo ""

# -----------------------------------------------------------------
# Auto-loaded <year>-<source>.tsv with date-based period filter
# -----------------------------------------------------------------
echo "--- TSV auto-discovery + period filter ---"
let (uQ1, uQ1Rc) = inEx("submit freelance --test --period q1 --year 2025 --dry-run")
check("Q1 freelance from TSV ok", uQ1Rc == 0, uQ1)
check("Jan+Feb invoices summed (1200+800)", uQ1.contains("<Kz81>2000</Kz81>"))

let (uQ2, _) = inEx("submit freelance --test --period q2 --year 2025 --dry-run")
check("Q2 (Apr+May) sums 19% rates", uQ2.contains("<Kz81>2400</Kz81>"))
check("Q2 picks up 7% from May", uQ2.contains("<Kz86>500</Kz86>"))
echo ""

# -----------------------------------------------------------------
# EÜR per source — rechtsform aliases get translated correctly
# -----------------------------------------------------------------
echo "--- EÜR per source ---"
let (eF, eFRc) = inEx("euer freelance --test --year 2025 --dry-run")
check("euer freelance ok", eFRc == 0, eF)
check("rechtsform=freiberuf -> 140", eF.contains("<E6000602>140</E6000602>"))

let (eM, eMRc) = inEx("euer mygewerbe --test --year 2025 --dry-run")
check("euer mygewerbe ok", eMRc == 0, eM)
check("rechtsform=einzel -> 120", eM.contains("<E6000602>120</E6000602>"))
echo ""

# -----------------------------------------------------------------
# Annual USt with conf-side vorauszahlungen
# -----------------------------------------------------------------
echo "--- annual USt + vorauszahlungen ---"
let (u, uRc) = inEx("ust mygewerbe --test --year 2025 --dry-run")
check("ust dry-run ok", uRc == 0, u)
check("vorauszahlungen=100 carried into XML",
      u.contains("<E3011301>100,00</E3011301>"))
check("besteuerungsart=soll -> 1",
      u.contains("<E3002203>1</E3002203>"))
echo ""

# -----------------------------------------------------------------
# ESt: aggregate G + S + KAP + 2 kids in one return
# -----------------------------------------------------------------
echo "--- ESt aggregation across all sources ---"
let (e, eRc) = inEx("est --test --year 2025 --deductions deductions.tsv --dry-run")
check("est dry-run ok", eRc == 0, e)
check("Anlage G emitted (mygewerbe)",  e.contains("<G>"))
check("Anlage S emitted (freelance)",  e.contains("<S>"))
check("Anlage KAP emitted (ibkr)",     e.contains("<KAP>"))
check("two Anlage Kind blocks",        e.count("<Kind>") == 2)
check("KAP guenstigerpruefung set",    e.contains("<E1900401>1</E1900401>"))
check("religion rk -> 03",             e.contains("<E0100402>03</E0100402>"))
check("Sonderausgaben Spenden",        e.contains("<E0108105>"))
check("AgB Krankheitskosten",          e.contains("<E0161304>"))
check("Anlage Kind Betreuungskosten",  e.contains("<E0506105>"))
check("Anlage Kind Schulgeld",         e.contains("<E0505607>"))
check("Vorsorge KV privat",            e.contains("<E2003104>"))
check("Testmerker present (--test)",   e.contains("<Testmerker>700000004</Testmerker>"))
echo ""

# -----------------------------------------------------------------
# Postfach commands: dry-run renders the request XML
# -----------------------------------------------------------------
echo "--- Postfach (list/download) dry-run ---"
let (l, lRc) = inEx("list --dry-run")
check("list dry-run ok", lRc == 0, l)
check("PostfachAnfrage XML emitted", l.contains("<PostfachAnfrage "))
check("DatenLieferant from conf",
      l.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))

let (d, dRc) = inEx("download --dry-run")
check("download dry-run ok", dRc == 0, d)
check("download dry-run also emits PostfachAnfrage",
      d.contains("<PostfachAnfrage "))
echo ""

# -----------------------------------------------------------------
# IBAN change + free-text message commands
# -----------------------------------------------------------------
echo "--- iban + message dry-runs ---"
let (ib, ibRc) = inEx("iban --test --new-iban DE89370400440532013000 --dry-run")
check("iban dry-run ok", ibRc == 0, ib)
check("AenderungBankverbindung XML",
      ib.contains("<IBAN>DE89370400440532013000</IBAN>"))

let (msg, msgRc) = inEx("message --test --subject \"Hallo\" --text \"Test\" --dry-run")
check("message dry-run ok", msgRc == 0, msg)
check("Nachricht XML with Betreff", msg.contains("<Betreff>Hallo</Betreff>"))
echo ""

# -----------------------------------------------------------------
# Real ELSTER schema validation against the sandbox
# -----------------------------------------------------------------
if testCertAvailable:
  echo "--- ELSTER validation (--test --validate-only) ---"

  let (vU, vURc) = inEx("submit freelance --test --period q1 --amount19 0 --validate-only")
  check("UStVA validates",       validateOk(vU, vURc), vU)
  check("UStVA no schema errors", not vU.contains("610301200"), vU)

  let (vE, vERc) = inEx("euer freelance --test --year 2025 --validate-only")
  check("EÜR validates",         validateOk(vE, vERc), vE)
  check("EÜR no schema errors",   not vE.contains("610301200"), vE)

  let (vUst, vUstRc) = inEx("ust mygewerbe --test --year 2025 --validate-only")
  check("USt validates",         validateOk(vUst, vUstRc), vUst)
  check("USt no schema errors",   not vUst.contains("610301200"), vUst)

  # ESt with the demo kid IDNRs and partial Anlage Kind data won't pass
  # ELSTER's plausibility checks (those need real IDNRs + dienstleister
  # details viking doesn't model). The XML schema itself is fine.
  # --verbose dumps the response puffer to stdout so we can assert on
  # specific plausibility rules.
  let (vEst, _) = inEx("est --test --year 2025 --deductions deductions.tsv --validate-only --verbose")
  check("ESt no schema errors",   not vEst.contains("610301200"), vEst)
  # Regression: plausi 100500048 requires info about the other parent
  # (K_Verh_and_P) on Einzelveranlagung. Example conf ships with
  # parent_b_name, so rule must not fire.
  check("ESt Anlage Kind: rule 100500048 not triggered (parent_b_name emits K_Verh_and_P)",
        not vEst.contains("Regel_Kind_2020_100500048"), vEst)
  check("ESt Anlage Kind: rule 100500001 not triggered (E0501103/03/06 emitted together)",
        not vEst.contains("Kind_Kindschaftsverhaeltnis_100500001"), vEst)
  # Known open: rule 5075 currently fires because the example ships with
  # [spouse] -> K_Verh_B is emitted, but Vlg_Art wiring is not done yet,
  # so ERiC treats the return as Einzel. Tracked in state.md TODO.
  echo ""

  # ---------------------------------------------------------------
  # Swap pin -> pincmd: the script form must work the same way
  # ---------------------------------------------------------------
  echo "--- pincmd (script) auth ---"
  writeFile(confPath, baseConf &
    "\n[auth]\ncert = " & testCertPath &
    "\npincmd = " & (tmp / "viking.pin.sh") & "\n")
  let (pc, pcRc) = inEx("submit freelance --test --period q1 --amount19 0 --validate-only")
  check("pincmd script PIN accepted", validateOk(pc, pcRc), pc)
  echo ""
else:
  echo "  SKIP: ELSTER validation tests (test cert not at " & testCertPath & ")"
  echo "  Install with: wget https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip"
  echo ""

# Cleanup
removeDir(tmp)
removeDir(testXdgHome)

echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0: quit(1)
