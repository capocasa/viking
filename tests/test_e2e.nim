## End-to-end sandbox tests for viking
## Requires: ERiC library + test certificates in <data-dir>/certificates.
## Data is TSV-driven via source.euer= in viking.conf. Year comes from
## personal.year. Dry-run validates via ERiC and prints XML.

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

func structuralOk(outText: string, rc: int): bool =
  ## Dry-run is considered OK for structural inspection when either:
  ## clean exit, HerstellerID blocked (demo HID), or plausibility
  ## failure (demo data often doesn't satisfy ELSTER's checks).
  rc == 0 or outText.contains("610301202") or outText.contains("610001002")

let projectRoot = currentSourcePath().parentDir.parentDir
setCurrentDir(projectRoot)

echo "=== viking end-to-end tests ==="
echo "Working directory: ", getCurrentDir()
echo ""

# Isolate from user's global config
let testXdgHome = projectRoot / "tests" / "tmp_xdg"
createDir(testXdgHome)
putEnv("XDG_CONFIG_HOME", testXdgHome)

let testCertPath = getAppDataDir() / "certificates" / "test-softorg-pse.pfx"
let testCertAvailable = fileExists(testCertPath)
let testPinPath = projectRoot / "tests" / "tmp_viking.pin"
writeFile(testPinPath, "123456")

let testDir = projectRoot / "tests"

proc authBlock(): string =
  "\n[auth]\ncert = " & testCertPath & "\npin = " & testPinPath & "\n"

proc personalBlock(year: int = 2025): string =
  "[Hans Maier]\n" &
  "year         = " & $year & "\n" &
  "geburtsdatum = 05.05.1955\n" &
  "idnr         = 04452397687\n" &
  "steuernr     = 9198011310010\n" &
  "strasse      = Musterstr.\n" &
  "nr           = 1\n" &
  "plz          = 10115\n" &
  "ort          = Berlin\n" &
  "iban         = DE91100000000123456789\n" &
  "religion     = 11\n" &
  "beruf        = Software-Entwickler\n"

proc writeConf(path, body: string) =
  writeFile(path, body & authBlock())

proc runIn(dir, args: string): tuple[output: string, code: int] =
  run("cd " & dir & " && " & projectRoot / Viking & " " & args)

# --- Prerequisites ---
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
  echo "  Run `viking fetch` for details."
  quit(1)
check("fetch --check succeeds", fetchCheckRc == 0)
check("fetch --check shows version", fetchCheck.contains("ERiC"))
echo ""

# =================================================================
# UStVA
# =================================================================

let ustvaConf = testDir / "tmp_ustva.conf"
writeConf(ustvaConf, personalBlock() & """
[freiberuf]
versteuerung = 2
euer = freiberuf.tsv
""")
let ustvaTsv = testDir / "freiberuf.tsv"

echo "--- ustva --dry-run -v ---"
writeFile(ustvaTsv, "1000,19\n")
let (dryOut, dryRc) = runIn(testDir, "ustva --test -c " & ustvaConf & " --period 41 --dry-run -v")
check("dry-run exits 0", dryRc == 0, dryOut)
check("dry-run has XML", dryOut.contains("<?xml"))
check("dry-run has UStVA", dryOut.contains("<Umsatzsteuervoranmeldung>"))
check("dry-run has Kz81 1000", dryOut.contains("<Kz81>1000</Kz81>"))
check("dry-run has Kz83 190.00", dryOut.contains("<Kz83>190.00</Kz83>"))
check("dry-run has Testmerker", dryOut.contains("<Testmerker>700000004</Testmerker>"))
check("dry-run has Empfaenger", dryOut.contains("""<Empfaenger id="F">9198</Empfaenger>"""))
echo ""

echo "--- --test flag toggles Testmerker ---"
writeFile(ustvaTsv, "0,19\n")
let (prodOut, prodRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 41 --dry-run -v")
check("production dry-run exits 0", prodRc == 0, prodOut)
check("production no Testmerker", not prodOut.contains("Testmerker"))
let (testOut, testRc) = runIn(testDir, "ustva --test -c " & ustvaConf & " --period 41 --dry-run -v")
check("--test dry-run exits 0", testRc == 0, testOut)
check("--test has Testmerker", testOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

echo "--- ustva: multi-rate TSV ---"
writeFile(ustvaTsv, "500,19\n200,7\n")
let (dryBoth, dryBothRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("dual-rate dry-run exits 0", dryBothRc == 0, dryBoth)
check("dual-rate has Kz81 500", dryBoth.contains("<Kz81>500</Kz81>"))
check("dual-rate has Kz86 200", dryBoth.contains("<Kz86>200</Kz86>"))
check("dual-rate has Kz83 109.00", dryBoth.contains("<Kz83>109.00</Kz83>"))
echo ""

echo "--- ustva: 0% Kz45 ---"
writeFile(ustvaTsv, "1000,19\n500,0\n")
let (kz45Out, kz45Rc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("0% exits 0", kz45Rc == 0, kz45Out)
check("0% Kz45 500", kz45Out.contains("<Kz45>500</Kz45>"))
check("0% Kz81 1000", kz45Out.contains("<Kz81>1000</Kz81>"))
echo ""

echo "--- ustva: negative amounts ---"
writeFile(ustvaTsv, "1000,19\n-200,19\n")
let (negOut, negRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("negative exits 0", negRc == 0, negOut)
check("Kz81 800 (1000-200)", negOut.contains("<Kz81>800</Kz81>"))
echo ""

echo "--- ustva: trailing % accepted ---"
writeFile(ustvaTsv, "1000,19%\n500,7%\n")
let (pctOut, pctRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("trailing % exits 0", pctRc == 0, pctOut)
check("19% -> Kz81 1000", pctOut.contains("<Kz81>1000</Kz81>"))
check("7% -> Kz86 500", pctOut.contains("<Kz86>500</Kz86>"))
echo ""

echo "--- ustva: empty TSV -> zero ---"
writeFile(ustvaTsv, "")
let (emptyOut, emptyRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("empty exits 0", emptyRc == 0, emptyOut)
check("empty Kz81 0", emptyOut.contains("<Kz81>0</Kz81>"))
echo ""

echo "--- ustva: period filtering ---"
writeFile(ustvaTsv,
  "amount,rate,date,id,description\n" &
  "1000,19,2025-01-15,INV-001,Jan\n" &
  "500,19,2025-02-10,INV-002,Feb\n" &
  "300,7,2025-04-05,INV-003,Apr\n" &
  "200,19,2025-06-20,INV-004,Jun\n")
let (q1Out, q1Rc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 41 --dry-run -v")
check("Q1 exits 0", q1Rc == 0, q1Out)
check("Q1 sums Jan+Feb to 1500", q1Out.contains("<Kz81>1500</Kz81>"))
let (q2Out, q2Rc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 42 --dry-run -v")
check("Q2 exits 0", q2Rc == 0, q2Out)
check("Q2 19% = 200", q2Out.contains("<Kz81>200</Kz81>"))
check("Q2 7% = 300", q2Out.contains("<Kz86>300</Kz86>"))
let (janOut, janRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 01 --dry-run -v")
check("Jan exits 0", janRc == 0, janOut)
check("Jan = 1000", janOut.contains("<Kz81>1000</Kz81>"))
echo ""

echo "--- ustva: missing --period ---"
let (noPer, noPerRc) = runIn(testDir, "ustva -c " & ustvaConf)
check("missing --period rejected", noPerRc != 0)
check("missing --period error", noPer.contains("--period is required"))

let (badPer, badPerRc) = runIn(testDir, "ustva -c " & ustvaConf & " --period 99")
check("bad period rejected", badPerRc != 0)
check("bad period lists words", badPer.contains("jan") and badPer.contains("q1"))
echo ""

echo "--- period aliases ---"
writeFile(ustvaTsv, "100,19\n")
let (pq1, _) = runIn(testDir, "ustva -c " & ustvaConf & " --period q1 --dry-run -v")
check("q1 -> 41", pq1.contains("<Zeitraum>41</Zeitraum>"))
let (pmar, _) = runIn(testDir, "ustva -c " & ustvaConf & " --period mar --dry-run -v")
check("mar -> 03", pmar.contains("<Zeitraum>03</Zeitraum>"))
let (p3, _) = runIn(testDir, "ustva -c " & ustvaConf & " --period 3 --dry-run -v")
check("3 -> 03", p3.contains("<Zeitraum>03</Zeitraum>"))
echo ""

echo "--- per-year UStVA plugins validate ---"
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
        if y >= 2025: years.add(y)
      except ValueError: discard
years.sort()
check("found UStVA plugins >=2025", years.len > 0)
writeFile(ustvaTsv, "1000,19\n")
for year in years:
  let yearConf = testDir / ("tmp_ustva_" & $year & ".conf")
  writeConf(yearConf, personalBlock(year) & """
[freiberuf]
versteuerung = 2
euer = freiberuf.tsv
""")
  let (yOut, yRc) = runIn(testDir, "ustva -c " & yearConf & " --period 41 --dry-run -v")
  let schemaOk = not yOut.contains("610301200")
  let hidBlocked = yOut.contains("610301202")
  check($year & " schema valid", schemaOk, yOut)
  check($year & " validates", yRc == 0 or hidBlocked, yOut)
  removeFile(yearConf)
removeFile(ustvaTsv)
echo ""

echo "--- ustva: alphanumeric aliases (rechtsform, versteuerung, religion) ---"
let wordConf = testDir / "tmp_words.conf"
writeConf(wordConf, personalBlock().replace("religion     = 11", "religion     = rk") & """
[freelance]
rechtsform = einzel
versteuerung = ist
euer = freelance.tsv
""")
writeFile(testDir / "freelance.tsv", "1000,19\n")
let (wordOut, wordRc) = runIn(testDir, "ustva -c " & wordConf & " --period jan --dry-run -v")
check("word conf exits 0", wordRc == 0, wordOut)
check("word conf Zeitraum 01", wordOut.contains("<Zeitraum>01</Zeitraum>"))
let (wEuerOut, wEuerRc) = runIn(testDir, "euer -s freelance -c " & wordConf & " --dry-run -v")
check("euer word conf exits 0", wEuerRc == 0, wEuerOut)
check("rechtsform einzel -> 120", wEuerOut.contains("<E6000602>120</E6000602>"))
let (wUstOut, _) = runIn(testDir, "ust -s freelance -c " & wordConf & " --dry-run -v")
check("besteuerungsart ist -> 2", wUstOut.contains("<E3002203>2</E3002203>"))
let (wEstOut, _) = runIn(testDir, "est -c " & wordConf & " --force --dry-run -v")
check("religion rk -> 03", wEstOut.contains("<E0100402>03</E0100402>"))
removeFile(testDir / "freelance.tsv")
removeFile(wordConf)

echo "--- ustva: bad rechtsform lists valid values ---"
let badConf = testDir / "tmp_bad.conf"
writeConf(badConf, personalBlock() & """
[freelance]
rechtsform = zzz
versteuerung = ist
""")
let (badOut, badRc) = runIn(testDir, "ustva -c " & badConf & " --period q1 --dry-run -v")
check("bad rechtsform rejected", badRc != 0)
check("bad rechtsform lists words", badOut.contains("einzel") and badOut.contains("gmbh"))
removeFile(badConf)
echo ""

echo "--- ustva: multi-source requires name ---"
let multiConf = testDir / "tmp_multi.conf"
writeConf(multiConf, personalBlock() & """
[freiberuf]
versteuerung = 2
euer = freiberuf.tsv

[mygewerbe]
steuernr = 9198011310020
versteuerung = 2
euer = mygewerbe.tsv
""")
writeFile(testDir / "freiberuf.tsv", "100,19\n")
writeFile(testDir / "mygewerbe.tsv", "200,19\n")

let (ambigOut, ambigRc) = runIn(testDir, "ustva -c " & multiConf & " --period 41 --dry-run -v")
check("multi-source without name rejected", ambigRc != 0)
check("multi-source error lists names", ambigOut.contains("freiberuf") and ambigOut.contains("mygewerbe"))

let (gOut, gRc) = runIn(testDir, "ustva -s mygewerbe -c " & multiConf & " --period 41 --dry-run -v")
check("explicit source ok", structuralOk(gOut, gRc), gOut)
check("source taxnumber override", gOut.contains("<Steuernummer>9198011310020</Steuernummer>"))

let (fOut, _) = runIn(testDir, "ustva -s freiberuf -c " & multiConf & " --period 41 --dry-run -v")
check("other source uses personal taxnumber", fOut.contains("<Steuernummer>9198011310010</Steuernummer>"))

let (uOut, uRc) = runIn(testDir, "ustva -s bogus -c " & multiConf & " --period 41 --dry-run -v")
check("unknown source rejected", uRc != 0)
check("unknown source error", uOut.contains("not found"))
removeFile(testDir / "freiberuf.tsv")
removeFile(testDir / "mygewerbe.tsv")
removeFile(multiConf)
removeFile(ustvaConf)
echo ""

# =================================================================
# Auth
# =================================================================

let authTsvPath = testDir / "freiberuf.tsv"
writeFile(authTsvPath, "0,19\n")

echo "--- auth: pin inline ---"
let inlinePinConf = testDir / "tmp_inline_pin.conf"
writeFile(inlinePinConf, personalBlock() &
  "[freiberuf]\nversteuerung = 2\neuer = freiberuf.tsv\n\n" &
  "[auth]\ncert = " & testCertPath & "\npin = 123456\n")
let (inPinOut, inPinRc) = runIn(testDir, "ustva -s freiberuf --test -c " & inlinePinConf & " --period 41")
check("inline pin accepted",
      inPinRc == 0 or inPinOut.contains("610301202"), inPinOut)
check("inline pin: no pin-read error", not inPinOut.contains("Error reading"))
removeFile(inlinePinConf)

echo "--- auth: pincmd shell ---"
let pincmdConf = testDir / "tmp_pincmd.conf"
let pinFile = testDir / "tmp_pincmd.pin"
writeFile(pinFile, "123456\n")
writeFile(pincmdConf, personalBlock() &
  "[freiberuf]\nversteuerung = 2\neuer = freiberuf.tsv\n\n" &
  "[auth]\ncert = " & testCertPath & "\npincmd = cat " & pinFile & "\n")
let (pcOut, pcRc) = runIn(testDir, "ustva -s freiberuf --test -c " & pincmdConf & " --period 41")
check("pincmd shell accepted", pcRc == 0 or pcOut.contains("610301202"), pcOut)
removeFile(pincmdConf)
removeFile(pinFile)

echo "--- auth: missing pin+pincmd ---"
let noAuthConf = testDir / "tmp_no_auth.conf"
writeFile(noAuthConf, personalBlock() &
  "[freiberuf]\nversteuerung = 2\neuer = freiberuf.tsv\n\n" &
  "[auth]\ncert = " & testCertPath & "\n")
let (noAuthOut, noAuthRc) = runIn(testDir, "ustva -s freiberuf --test -c " & noAuthConf & " --period 41")
check("missing pin+pincmd rejected", noAuthRc != 0)
check("missing pin+pincmd error", noAuthOut.contains("pin") and noAuthOut.contains("pincmd"))
removeFile(noAuthConf)
removeFile(authTsvPath)
echo ""

# =================================================================
# EÜR
# =================================================================

let euerConf = testDir / "tmp_euer.conf"
writeConf(euerConf, personalBlock() & """
[freelance]
versteuerung = 2
euer = freelance.tsv
""")
let euerTsv = testDir / "freelance.tsv"

echo "--- euer --dry-run -v ---"
writeFile(euerTsv, "1000,19\n500,7\n")
let (eDryOut, eDryRc) = runIn(testDir, "euer -s freelance -c " & euerConf & " --dry-run -v")
check("euer dry-run exits 0", eDryRc == 0, eDryOut)
check("euer has EUER element", eDryOut.contains("<EUER>"))
check("euer Verfahren ElsterErklaerung", eDryOut.contains("<Verfahren>ElsterErklaerung</Verfahren>"))
check("euer DatenArt EUER", eDryOut.contains("<DatenArt>EUER</DatenArt>"))
echo ""

echo "--- euer: income/expense split ---"
writeFile(euerTsv, "1000,19\n-300,19\n")
let (splitOut, splitRc) = runIn(testDir, "euer -s freelance -c " & euerConf & " --dry-run -v")
check("split exits 0", splitRc == 0, splitOut)
check("income net 1000", splitOut.contains("<E6000401>1000,00</E6000401>"))
check("income VAT 190", splitOut.contains("<E6000601>190,00</E6000601>"))
check("expense net 300", splitOut.contains("<E6004901>300,00</E6004901>"))
check("profit 833", splitOut.contains("<E6007202>833,00</E6007202>"))
echo ""

echo "--- euer: missing tsv ---"
removeFile(euerTsv)
let (missOut, missRc) = runIn(testDir, "euer -s freelance -c " & euerConf & " --dry-run -v")
check("missing tsv rejected", missRc != 0)
check("missing tsv error", missOut.contains("not found") or missOut.contains("freelance.tsv"))
echo ""

echo "--- euer: unset (optional, warns + zeros) ---"
let noEuerConf = testDir / "tmp_no_euer.conf"
writeConf(noEuerConf, personalBlock() & """
[freelance]
versteuerung = 2
""")
let (noEOut, noERc) = runIn(testDir, "euer -s freelance -c " & noEuerConf & " --dry-run -v")
check("euer unset exits 0", noERc == 0, noEOut)
check("euer unset warns", noEOut.contains("Warning") and noEOut.contains("euer="))
check("euer unset zeros", noEOut.contains("<E6000401>0,00</E6000401>"))

let (noUstOut, noUstRc) = runIn(testDir, "ust -s freelance -c " & noEuerConf & " --dry-run -v")
check("ust unset Nullmeldung exits 0", noUstRc == 0, noUstOut)
check("ust unset Nullmeldung warns", noUstOut.contains("Nullmeldung"))
check("ust Nullmeldung zero Ums_allg", noUstOut.contains("<E3003303>0</E3003303>"))
check("ust Nullmeldung zero Ums_Sum", noUstOut.contains("<E3006001>0,00</E3006001>"))
check("ust Nullmeldung zero Abschluss", noUstOut.contains("<E3011401>0,00</E3011401>"))

let (noUvOut, noUvRc) = runIn(testDir, "ustva -s freelance -c " & noEuerConf & " --period 41 --dry-run -v")
check("ustva unset exits 0", noUvRc == 0, noUvOut)
check("ustva unset warns", noUvOut.contains("Warning"))
check("ustva unset Kz81 0", noUvOut.contains("<Kz81>0</Kz81>"))
removeFile(noEuerConf)
echo ""

echo "--- euer: per-year plugin validation ---"
var euerYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let euerPrefix = PluginPrefix & "EUER_"
    if name.startsWith(euerPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[euerPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2025: euerYears.add(y)
      except ValueError: discard
euerYears.sort()
check("found EUER plugins >=2025", euerYears.len > 0)
writeFile(euerTsv, "1000,19\n-500,19\n")
for year in euerYears:
  let yearConf = testDir / ("tmp_euer_" & $year & ".conf")
  writeConf(yearConf, personalBlock(year) & """
[freelance]
versteuerung = 2
euer = freelance.tsv
""")
  let (yOut, yRc) = runIn(testDir, "euer -s freelance -c " & yearConf & " --dry-run -v")
  check("euer " & $year & " schema valid", not yOut.contains("610301200"), yOut)
  check("euer " & $year & " validates",
        yRc == 0 or yOut.contains("610301202"), yOut)
  removeFile(yearConf)
removeFile(euerTsv)
removeFile(euerConf)
echo ""

# =================================================================
# ESt
# =================================================================

let estConf = testDir / "tmp_est.conf"
writeConf(estConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv
""")
let estTsv = testDir / "mybiz.tsv"

echo "--- est --dry-run -v (Anlage G) ---"
writeFile(estTsv, "1000,19\n-300,19\n")
let (estOut, estRc) = runIn(testDir, "est --test -c " & estConf & " --dry-run -v --force")
check("est dry-run exits 0", estRc == 0, estOut)
check("est has Anlage G", estOut.contains("<G>"))
check("est profit 833", estOut.contains("<E0800302>833</E0800302>"))
check("est has Testmerker", estOut.contains("<Testmerker>700000004</Testmerker>"))
echo ""

echo "--- est Anlage S ---"
let estConfS = testDir / "tmp_est_s.conf"
writeConf(estConfS, personalBlock() & """
[freiberuf]
versteuerung = 2
euer = freiberuf.tsv
""")
let estFreiTsv = testDir / "freiberuf.tsv"
writeFile(estFreiTsv, "1000,19\n-300,19\n")
let (estSOut, estSRc) = runIn(testDir, "est -c " & estConfS & " --dry-run -v --force")
check("est Anlage S exits 0", estSRc == 0, estSOut)
check("est Anlage S has <S>", estSOut.contains("<S>"))
check("est Anlage S profit 833", estSOut.contains("<E0803202>833</E0803202>"))
check("est Anlage S no <G>", not estSOut.contains("<G>"))
removeFile(estConfS)
removeFile(estFreiTsv)
echo ""

echo "--- est multi-source (G + S) ---"
let estMultiConf = testDir / "tmp_est_multi.conf"
writeConf(estMultiConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv

[freiberuf]
versteuerung = 2
euer = freiberuf.tsv
""")
writeFile(estTsv, "1000,19\n-300,19\n")
writeFile(estFreiTsv, "500,19\n")
let (mOut, mRc) = runIn(testDir, "est -c " & estMultiConf & " --dry-run -v --force")
check("est multi exits 0", mRc == 0, mOut)
check("est multi G profit 833", mOut.contains("<E0800302>833</E0800302>"))
check("est multi S profit 595", mOut.contains("<E0803202>595</E0803202>"))
check("est multi has both", mOut.contains("<G>") and mOut.contains("<S>"))
removeFile(estMultiConf)
removeFile(estFreiTsv)
echo ""

echo "--- est no sources ---"
let estNoSrc = testDir / "tmp_est_nosrc.conf"
writeConf(estNoSrc, personalBlock())
let (nsOut, nsRc) = runIn(testDir, "est -c " & estNoSrc & " --dry-run -v --force")
check("est no sources exits 0", nsRc == 0, nsOut)
check("est no sources no G/S", not nsOut.contains("<G>") and not nsOut.contains("<S>"))
removeFile(estNoSrc)
echo ""

echo "--- est: abzuege from conf ---"
let dedTsv = testDir / "tmp_abzuege.tsv"
writeFile(dedTsv, "code\tamount\nsa131\t500\n")
let estDedConf = testDir / "tmp_est_ded.conf"
writeConf(estDedConf, personalBlock().replace("beruf        = Software-Entwickler",
  "beruf        = Software-Entwickler\nabzuege      = " & dedTsv) & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv
""")
writeFile(estTsv, "100,19\n")
let (dedOut, dedRc) = runIn(testDir, "est -c " & estDedConf & " --dry-run -v")
check("est abzuege from conf exits 0", dedRc == 0, dedOut)
check("est abzuege loaded (Spenden)", dedOut.contains("<E0108105>500</E0108105>"))

echo "--- est: missing abzuege warns, --force suppresses ---"
let estNoDedConf = testDir / "tmp_est_noded.conf"
writeConf(estNoDedConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv
""")
let (noDedOut, _) = runIn(testDir, "est -c " & estNoDedConf & " --dry-run -v")
check("missing abzuege warns", noDedOut.contains("Warning") and noDedOut.contains("abzuege"))
let (forceOut, forceRc) = runIn(testDir, "est -c " & estNoDedConf & " --dry-run -v --force")
check("--force ok", forceRc == 0, forceOut)
check("--force suppresses warning", not forceOut.contains("Warning"))
removeFile(estDedConf)
removeFile(estNoDedConf)
removeFile(dedTsv)
echo ""

echo "--- est Anlage KAP ---"
let estKapConf = testDir / "tmp_est_kap.conf"
writeConf(estKapConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv

[ibkr]
gains = 1500.50
tax = 375.13
soli = 20.63
guenstigerpruefung = 1
""")
let (kapOut, kapRc) = runIn(testDir, "est -c " & estKapConf & " --dry-run -v --force")
check("est KAP ok", structuralOk(kapOut, kapRc), kapOut)
check("est KAP <KAP>", kapOut.contains("<KAP>"))
check("est KAP guenstigerpruefung", kapOut.contains("<E1900401>1</E1900401>"))
check("est KAP Kapitalertraege", kapOut.contains("<E1900701>"))
removeFile(estKapConf)
echo ""

echo "--- est Anlage Kind ---"
let estKindConf = testDir / "tmp_est_kind.conf"
writeConf(estKindConf, personalBlock().replace("beruf        = Software-Entwickler",
  "beruf        = Software-Entwickler\nabzuege      = " & (testDir / "tmp_kind_ded.tsv")) & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv

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
writeFile(testDir / "tmp_kind_ded.tsv",
  "code\tamount\nmax174\t2400\nlisa174\t3600\nlisa176\t1500\n")
let (kindOut, kindRc) = runIn(testDir, "est -c " & estKindConf & " --dry-run -v")
check("est Kind ok", structuralOk(kindOut, kindRc), kindOut)
check("est Kind 2 <Kind>", kindOut.count("<Kind>") == 2)
check("est Kind betreuungskosten", kindOut.contains("<E0506105>"))
check("est Kind schulgeld", kindOut.contains("<E0505607>"))
check("est Kind no K_Verh_B without kindschaftsverhaeltnis_b",
      not kindOut.contains("<K_Verh_B>"))
removeFile(estKindConf)
removeFile(testDir / "tmp_kind_ded.tsv")
echo ""

echo "--- est Anlage Kind K_Verh_and_P ---"
let estAndPConf = testDir / "tmp_est_andp.conf"
writeConf(estAndPConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv

[Max Maier]
geburtsdatum         = 01.06.2018
idnr                 = 12345678901
verhaeltnis          = leiblich
personb-verhaeltnis  = leiblich
personb-name         = Greta Maier
familienkasse        = Berlin
""")
let (andPOut, andPRc) = runIn(testDir, "est -c " & estAndPConf & " --dry-run -v --force")
check("est K_Verh_and_P ok", structuralOk(andPOut, andPRc), andPOut)
check("est K_Verh_and_P emitted", andPOut.contains("<K_Verh_and_P>"))
check("est K_Verh_and_P has E0501103", andPOut.contains("<E0501103>Greta Maier</E0501103>"))
check("est K_Verh_and_P has E0501903", andPOut.contains("<E0501903>01.01-31.12</E0501903>"))
check("est K_Verh_and_P has E0501106", andPOut.contains("<E0501106>1</E0501106>"))
check("est Kind familienkasse", andPOut.contains("<E0500706>Berlin</E0500706>"))
removeFile(estAndPConf)
echo ""

echo "--- est Anlage Kind date ranges ---"
# Mix of: born in tax year (auto-start from birthdate), aging out mid-year
# (verhaeltnis_bis), and an independent wohnsitz override.
let estDatesConf = testDir / "tmp_est_dates.conf"
writeConf(estDatesConf, personalBlock() & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv

[Baby Maier]
geburtsdatum       = 10.04.2025
idnr               = 11111111111
verhaeltnis        = leiblich
personb-verhaeltnis= leiblich
personb-name       = Greta Maier

[Anna Maier]
geburtsdatum       = 01.06.2000
idnr               = 22222222222
verhaeltnis        = leiblich
personb-verhaeltnis= leiblich
personb-name       = Greta Maier
verhaeltnis_bis    = 30.06

[Tim Maier]
geburtsdatum       = 15.03.2000
idnr               = 33333333333
verhaeltnis        = leiblich
personb-verhaeltnis= leiblich
personb-name       = Greta Maier
wohnsitz_bis       = 31.08
""")
let (datesOut, datesRc) = runIn(testDir, "est -c " & estDatesConf & " --dry-run -v --force")
check("est date ranges ok", structuralOk(datesOut, datesRc), datesOut)
# Baby: born 10.04.2025 → kvh + wohnsitz auto-start on 10.04
check("Baby auto-start K_Verh_A", datesOut.contains("<E0500601>10.04-31.12</E0500601>"))
check("Baby auto-start Wohnsitz", datesOut.contains("<E0500703>10.04-31.12</E0500703>"))
# Anna: aged out 30.06 → kvh ends 30.06, wohnsitz follows by default
check("Anna verhaeltnis_bis", datesOut.contains("<E0500601>01.01-30.06</E0500601>"))
check("Anna wohnsitz follows kvh", datesOut.contains("<E0500703>01.01-30.06</E0500703>"))
# Tim: wohnsitz overridden independently (moved out 31.08); kvh stays full year
check("Tim kvh default", datesOut.contains("<E0500601>01.01-31.12</E0500601>"))
check("Tim wohnsitz override", datesOut.contains("<E0500703>01.01-31.08</E0500703>"))
removeFile(estDatesConf)
echo ""

echo "--- --output-pdf renders PDFs across subcommands ---"
let pdfConf = testDir / "tmp_pdf.conf"
writeConf(pdfConf, personalBlock() & """
[freelance]
versteuerung = 2
euer = freelance.tsv
""")
writeFile(testDir / "freelance.tsv", "1000,19\n-300,19\n")
for (cmd, args) in [
    ("ustva", "ustva -s freelance --test -c " & pdfConf & " --period 41"),
    ("euer", "euer -s freelance --test -c " & pdfConf),
    ("est", "est --test -c " & pdfConf & " --force"),
    ("ust", "ust -s freelance --test -c " & pdfConf)]:
  let pdfPath = testDir / ("tmp_" & cmd & ".pdf")
  removeFile(pdfPath)
  let (pOut, pRc) = runIn(testDir, args & " --dry-run --output-pdf=" & pdfPath)
  check(cmd & " --output-pdf exits 0", pRc == 0, pOut)
  check(cmd & " --output-pdf writes PDF",
        fileExists(pdfPath) and getFileSize(pdfPath) > 0)
  if fileExists(pdfPath):
    let head = readFile(pdfPath)[0 ..< min(4, getFileSize(pdfPath).int)]
    check(cmd & " --output-pdf is a PDF", head == "%PDF")
  removeFile(pdfPath)
echo "--- --output-pdf failure modes ---"
## ERiC auto-creates writable parent dirs, so nonexistent-dir isn't a
## reliable failure. These are: (1) output path is itself a directory,
## (2) parent dir is unwritable.
writeFile(testDir / "freelance.tsv", "1000,19\n")
let estArgs = "est --test -c " & pdfConf & " --force --dry-run"

let dirPath = testDir / "tmp_pdf_isdir"
createDir(dirPath)
let (ddOut, ddRc) = runIn(testDir, estArgs & " --output-pdf=" & dirPath)
check("output path is a directory rejected", ddRc != 0, ddOut)
check("directory-as-output error surfaces ERiC print code",
      ddOut.contains("610501"))
removeDir(dirPath)

when not defined(windows):
  let roDir = testDir / "tmp_pdf_ro"
  createDir(roDir)
  let roPath = roDir / "out.pdf"
  setFilePermissions(roDir, {fpUserRead, fpUserExec})
  let (roOut, roRc) = runIn(testDir, estArgs & " --output-pdf=" & roPath)
  setFilePermissions(roDir, {fpUserRead, fpUserWrite, fpUserExec})
  check("read-only dir rejected", roRc != 0, roOut)
  check("read-only dir error surfaces ERiC print code",
        roOut.contains("610501"))
  check("read-only dir leaves no PDF", not fileExists(roPath))
  removeDir(roDir)

removeFile(testDir / "freelance.tsv")
removeFile(pdfConf)
echo ""

echo "--- est per-year plugin validation ---"
var estYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let estPrefix = PluginPrefix & "ESt_"
    if name.startsWith(estPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[estPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2024: estYears.add(y)
      except ValueError: discard
estYears.sort()
check("found ESt plugins >=2024", estYears.len > 0)
writeFile(estTsv, "1000,19\n-500,19\n")
for year in estYears:
  let yConf = testDir / ("tmp_est_" & $year & ".conf")
  writeConf(yConf, personalBlock(year) & """
[mybiz]
versteuerung = 2
euer = mybiz.tsv
""")
  let (yOut, yRc) = runIn(testDir, "est -c " & yConf & " --dry-run -v --force")
  check("est " & $year & " schema valid", not yOut.contains("610301200"), yOut)
  check("est " & $year & " validates",
        yRc == 0 or yOut.contains("610301202"), yOut)
  removeFile(yConf)
removeFile(estTsv)
removeFile(estConf)
echo ""

# =================================================================
# USt
# =================================================================

let ustConf = testDir / "tmp_ust.conf"
writeConf(ustConf, personalBlock() & """
[freelance]
versteuerung = 2
euer = freelance.tsv
""")
let ustTsv = testDir / "freelance.tsv"

echo "--- ust --dry-run -v ---"
writeFile(ustTsv, "1000,19\n500,7\n-200,19\n")
let (uDryOut, uDryRc) = runIn(testDir, "ust -s freelance --test -c " & ustConf & " --dry-run -v")
check("ust dry-run exits 0", uDryRc == 0, uDryOut)
check("ust has USt2A", uDryOut.contains("<USt2A>"))
check("ust Ums_allg 19%", uDryOut.contains("<E3003303>1000</E3003303>"))
check("ust Ums_erm 7%", uDryOut.contains("<E3004401>500</E3004401>"))
echo ""

echo "--- ust income/expense split ---"
writeFile(ustTsv, "1000,19\n-300,19\n")
let (uspOut, uspRc) = runIn(testDir, "ust -s freelance -c " & ustConf & " --dry-run -v")
check("ust split exits 0", uspRc == 0, uspOut)
check("ust Ums_allg base 1000", uspOut.contains("<E3003303>1000</E3003303>"))
check("ust Vorsteuer sum 57", uspOut.contains("<E3006901>57,00</E3006901>"))
check("ust verbleibende 133", uspOut.contains("<E3011101>133,00</E3011101>"))
echo ""

echo "--- rate=-1 (nicht steuerbar, EUER-only) ---"
# FA USt-Erstattung is Betriebseinnahme in EÜR (Brutto-Methode, § 4/3 EStG)
# but not steuerbar for USt — rate=-1 skips it in aggregateForUst.
writeFile(ustTsv, "1000,19\n200,-1\n")
let (nstU, nstURc) = runIn(testDir, "ust -s freelance -c " & ustConf & " --dry-run -v")
check("ust nst exits 0", nstURc == 0, nstU)
check("ust nst skips rate -1 from Umsaetze", nstU.contains("<E3003303>1000</E3003303>"))
check("ust nst Ums_Sum ignores rate -1", nstU.contains("<E3006001>190,00</E3006001>"))
let (nstE, nstERc) = runIn(testDir, "euer -s freelance -c " & ustConf & " --dry-run -v")
check("euer nst exits 0", nstERc == 0, nstE)
check("euer nst includes rate -1 as income", nstE.contains("<E6000401>1200,00</E6000401>"))
echo ""

echo "--- ust vorauszahlungen ---"
let ustVzConf = testDir / "tmp_ust_vz.conf"
writeConf(ustVzConf, personalBlock() & """
[freelance]
versteuerung = 2
euer = freelance.tsv
vorauszahlungen = 100
""")
writeFile(ustTsv, "1000,19\n")
let (vzOut, vzRc) = runIn(testDir, "ust -s freelance -c " & ustVzConf & " --dry-run -v")
check("ust vz ok", structuralOk(vzOut, vzRc), vzOut)
check("ust vz E3011301", vzOut.contains("<E3011301>100,00</E3011301>"))
check("ust vz E3011401", vzOut.contains("<E3011401>90,00</E3011401>"))
removeFile(ustVzConf)
echo ""

echo "--- ust per-year plugin validation ---"
var ustYears: seq[int] = @[]
for kind, path in walkDir(pluginPath):
  if kind == pcFile:
    let name = path.extractFilename
    let ustPrefix = PluginPrefix & "USt_"
    let ustvaPrefix = PluginPrefix & "UStVA_"
    if name.startsWith(ustPrefix) and not name.startsWith(ustvaPrefix) and name.endsWith(DynlibExt):
      try:
        let y = parseInt(name[ustPrefix.len ..^ (DynlibExt.len + 1)])
        if y >= 2025: ustYears.add(y)
      except ValueError: discard
ustYears.sort()
check("found USt plugins >=2025", ustYears.len > 0)
writeFile(ustTsv, "1000,19\n-500,19\n")
for year in ustYears:
  let yConf = testDir / ("tmp_ust_" & $year & ".conf")
  writeConf(yConf, personalBlock(year) & """
[freelance]
versteuerung = 2
euer = freelance.tsv
""")
  let (yOut, yRc) = runIn(testDir, "ust -s freelance -c " & yConf & " --dry-run -v")
  check("ust " & $year & " schema valid", not yOut.contains("610301200"), yOut)
  check("ust " & $year & " validates",
        yRc == 0 or yOut.contains("610301202"), yOut)
  removeFile(yConf)
removeFile(ustTsv)
removeFile(ustConf)
echo ""

# =================================================================
# Message
# =================================================================

let messageConf = testDir / "tmp_message.conf"
writeConf(messageConf, personalBlock())

echo "--- message --dry-run -v ---"
let (mDryOut, mDryRc) = runIn(testDir, "message --test -c " & messageConf &
  " --subject \"Test Betreff\" --text \"Test Nachricht\" --dry-run -v")
check("message dry-run exits 0", mDryRc == 0, mDryOut)
check("message DatenArt SonstigeNachrichten", mDryOut.contains("<DatenArt>SonstigeNachrichten</DatenArt>"))
check("message Betreff", mDryOut.contains("<Betreff>Test Betreff</Betreff>"))

echo "--- message validation ---"
let (mnSubj, mnSubjRc) = runIn(testDir, "message -c " & messageConf & " --text foo")
check("message without subject fails", mnSubjRc != 0)
check("message without subject error", mnSubj.contains("--subject is required"))

let (mnText, mnTextRc) = runIn(testDir, "message -c " & messageConf & " --subject foo")
check("message without text fails", mnTextRc != 0)

let longSubj = 'A'.repeat(100)
let (mlOut, mlRc) = runIn(testDir,
  "message -c " & messageConf & " --subject \"" & longSubj & "\" --text foo")
check("message long subject rejected", mlRc != 0)
check("message long subject error", mlOut.contains("at most 99"))
removeFile(messageConf)
echo ""

# =================================================================
# IBAN
# =================================================================

let ibanConf = testDir / "tmp_iban.conf"
writeConf(ibanConf, personalBlock())

echo "--- iban --dry-run -v ---"
let (iOut, iRc) = runIn(testDir, "iban --test -c " & ibanConf &
  " --new-iban DE89370400440532013000 --dry-run -v")
check("iban dry-run exits 0", iRc == 0, iOut)
check("iban DatenArt", iOut.contains("<DatenArt>AenderungBankverbindung</DatenArt>"))
check("iban has IBAN", iOut.contains("<IBAN>DE89370400440532013000</IBAN>"))

let (inIbanOut, inIbanRc) = runIn(testDir, "iban -c " & ibanConf)
check("iban without --new-iban fails", inIbanRc != 0)
check("iban without --new-iban error", inIbanOut.contains("--new-iban is required"))
removeFile(ibanConf)
echo ""

# =================================================================
# Postfach list / download
# =================================================================

let abholConf = testDir / "tmp_abhol.conf"
writeConf(abholConf, personalBlock() & "\n")

echo "--- list --dry-run -v ---"
let (lOut, lRc) = runIn(testDir, "list -c " & abholConf & " --dry-run -v")
check("list dry-run exits 0", lRc == 0, lOut)
check("list PostfachAnfrage", lOut.contains("<PostfachAnfrage "))
check("list DatenLieferant", lOut.contains("<DatenLieferant>Hans Maier</DatenLieferant>"))

echo "--- download --dry-run -v ---"
let (dOut, dRc) = runIn(testDir, "download -c " & abholConf & " --dry-run -v")
check("download dry-run exits 0", dRc == 0, dOut)
check("download PostfachAnfrage", dOut.contains("<PostfachAnfrage "))
removeFile(abholConf)
echo ""

# =================================================================
# init
# =================================================================

echo "--- init ---"
let initDir = testDir / "tmp_init"
createDir(initDir)

let (initOut, initRc) = run(Viking & " init --dir " & initDir)
check("init creates files", initRc == 0, initOut)
check("init creates viking.conf", fileExists(initDir / "viking.conf"))
check("init creates abzuege.tsv", fileExists(initDir / "abzuege.tsv"))

let confContent = readFile(initDir / "viking.conf")
check("init has taxpayer section", confContent.contains("[Vorname Nachname]"))
check("init has year", confContent.contains("year"))
check("init has geburtsdatum", confContent.contains("geburtsdatum"))

let dedContent = readFile(initDir / "abzuege.tsv")
check("init abzuege has header", dedContent.contains("code\tamount\tdescription"))

let (skipOut, skipRc) = run(Viking & " init --dir " & initDir)
check("init skips existing", skipRc == 0)
check("init skip message", skipOut.contains("Skipped"))

let (forceInitOut, forceInitRc) = run(Viking & " init --dir " & initDir & " --force")
check("init --force ok", forceInitRc == 0, forceInitOut)

let (badDirOut, badDirRc) = run(Viking & " init --dir /nonexistent/xyz")
check("init bad dir fails", badDirRc != 0, badDirOut)

# Generated conf is parseable; empty fields trigger validation errors
let (genEstOut, genEstRc) = run(Viking & " est -c " & (initDir / "viking.conf") & " --dry-run -v --force")
check("generated conf parseable", genEstRc != 0)
check("generated conf validation errors", genEstOut.contains("not set"))
removeDir(initDir)
echo ""

# =================================================================
# Conf validation: year required
# =================================================================

echo "--- conf validation: year required ---"
let noYearConf = testDir / "tmp_no_year.conf"
writeConf(noYearConf,
  "[Hans Maier]\n" &
  "geburtsdatum = 05.05.1955\n" &
  "idnr = 04452397687\n" &
  "steuernr = 9198011310010\n" &
  "strasse = Musterstr.\n" &
  "nr = 1\n" &
  "plz = 10115\n" &
  "ort = Berlin\n" &
  "iban = DE91100000000123456789\n" &
  "religion = 11\n" &
  "beruf = Software-Entwickler\n")
let (nyOut, nyRc) = runIn(testDir, "est -c " & noYearConf & " --dry-run -v --force")
check("missing year rejected", nyRc != 0)
check("missing year error", nyOut.contains("year"))
removeFile(noYearConf)
echo ""

echo "--- conf validation: unknown keys and malformed lines ---"
let unkConf = testDir / "tmp_unknown.conf"
writeConf(unkConf, personalBlock() & "typokey = oops\n" & """
[freiberuf]
versteuerung = 2
unknownfield  = bad
euer = freiberuf.tsv
""")
let (unkOut, unkRc) = runIn(testDir, "ustva -c " & unkConf & " --period 41 --dry-run -v")
check("unknown key rejected", unkRc != 0)
check("unknown key mentions typokey", unkOut.contains("typokey"))
check("unknown key mentions unknownfield", unkOut.contains("unknownfield"))
removeFile(unkConf)

let malConf = testDir / "tmp_malformed.conf"
writeConf(malConf, personalBlock() & "this line has no equals sign\n" & """
[freiberuf]
versteuerung = 2
euer = freiberuf.tsv
""")
let (malOut, malRc) = runIn(testDir, "ustva -c " & malConf & " --period 41 --dry-run -v")
check("malformed line rejected", malRc != 0)
check("malformed line cites filepath:lineno", malOut.contains(":13:"))
check("malformed line shown", malOut.contains("this line has no equals"))
removeFile(malConf)
echo ""

# Cleanup isolation
removeDir(testXdgHome)

echo "=== Results ==="
echo "  Passed: ", passes
echo "  Failed: ", failures
if failures > 0:
  quit(1)
