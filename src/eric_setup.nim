## ERiC Library Setup Tool
## Downloads, extracts, and configures the ERiC library for viking

import std/[os, osproc, strutils, strformat, httpclient, algorithm]

const
  EricLibDir* = "lib"
  EricPluginDir* = "plugins2"

  # Required library files
  RequiredLibs = ["libericapi.so", "libericxerces.so", "libeSigner.so"]

  # Download URLs (publicly accessible, no auth needed)
  ElsterDownloadBase* = "https://download.elster.de/download/eric"

  # ELSTER developer portal (for manual download instructions)
  ElsterDevUrl* = "https://www.elster.de/elsterweb/entwickler/infoseite/eric"

  # Test certificate
  TestCertUrl* = "https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip"
  TestCertPin* = "123456"

  # App name for cache directory
  AppName = "viking"

type
  EricInstallation* = object
    path*: string
    version*: string
    libPath*: string
    pluginPath*: string
    valid*: bool
    missingFiles*: seq[string]

  EricDownload* = object
    version*: string
    url*: string
    filename*: string

# ===========================================================================
# Cache directory helpers
# ===========================================================================

proc getAppCacheDir*(): string =
  ## Get the cache directory. Honors VIKING_CACHE_DIR env var,
  ## falls back to OS-appropriate cache dir (~/.cache/viking on Linux)
  result = getEnv("VIKING_CACHE_DIR")
  if result == "":
    result = getCacheDir(AppName)

proc getEricCacheDir*(): string =
  ## Get the ERiC-specific cache directory
  getAppCacheDir() / "eric"

proc getCertCacheDir*(): string =
  ## Get the certificate cache directory
  getAppCacheDir() / "certificates"

# ===========================================================================
# Platform detection
# ===========================================================================

proc getEricPlatform*(): string =
  ## Get the ERiC platform string for the current OS/arch
  when defined(macosx):
    "Darwin-universal"
  elif defined(windows):
    when defined(amd64):
      "Windows-x86_64"
    else:
      "Windows-x86_64"
  else:
    when defined(amd64):
      "Linux-x86_64"
    elif defined(arm64):
      "Linux-aarch64"
    else:
      "Linux-x86_64"

# ===========================================================================
# Version probing (download.elster.de is publicly accessible)
# ===========================================================================

# Known baseline version - used as starting point for probing.
# Only the latest ERiC version is typically available on the download server.
const
  BaselineMajor = 43
  BaselineMinor = 3
  BaselinePatch = 2

proc makeEricUrl(major, minor, patch: int, platform: string): string =
  &"{ElsterDownloadBase}/eric_{major}/ERiC-{major}.{minor}.{patch}.0-{platform}.jar"

var probeCount = 0

proc probeUrl(client: HttpClient, url: string): bool =
  ## Check if a URL exists via HEAD request
  inc probeCount
  if probeCount mod 5 == 0:
    stdout.write(".")
    stdout.flushFile()
  try:
    let resp = client.head(url)
    return resp.code == Http200
  except:
    return false

proc probeVersion(client: HttpClient, major, minor, patch: int, platform: string): bool =
  probeUrl(client, makeEricUrl(major, minor, patch, platform))

proc scanMajor(client: HttpClient, major: int, platform: string): tuple[found: bool, minor, patch: int] =
  ## Scan a major version for any available minor.patch combination
  for minor in 0..10:
    for patch in 0..10:
      if probeVersion(client, major, minor, patch, platform):
        return (true, minor, patch)
  return (false, 0, 0)

proc discoverEricDownloads*(): seq[EricDownload] =
  ## Discover available ERiC downloads by probing download.elster.de.
  ## ERiC JARs are publicly accessible at:
  ##   https://download.elster.de/download/eric/eric_{major}/ERiC-{version}-{platform}.jar
  ##
  ## Strategy: start from a known baseline version, check if it exists,
  ## then scan forward for newer releases. Falls back to a wider scan
  ## if the baseline no longer exists.
  let client = newHttpClient()
  client.timeout = 3000
  defer: client.close()

  let platform = getEricPlatform()
  result = @[]

  var bestMajor = BaselineMajor
  var bestMinor = BaselineMinor
  var bestPatch = BaselinePatch

  # Phase 1: Check if baseline version still exists
  let baselineExists = probeVersion(client, bestMajor, bestMinor, bestPatch, platform)

  if not baselineExists:
    # Baseline gone - scan nearby majors to find current version
    echo "  Baseline version not found, scanning..."
    var found = false
    for major in countdown(BaselineMajor + 5, BaselineMajor - 3):
      let (ok, minor, patch) = scanMajor(client, major, platform)
      if ok:
        bestMajor = major
        bestMinor = minor
        bestPatch = patch
        found = true
        break
    if not found:
      return

  # Phase 2: Scan forward for newer patch versions
  for patch in (bestPatch + 1)..15:
    if probeVersion(client, bestMajor, bestMinor, patch, platform):
      bestPatch = patch
    else:
      break

  # Phase 3: Scan forward for newer minor versions
  for minor in (bestMinor + 1)..15:
    var foundMinor = false
    for patch in 0..10:
      if probeVersion(client, bestMajor, minor, patch, platform):
        bestMinor = minor
        bestPatch = patch
        foundMinor = true
        break
    if not foundMinor:
      break

  # Phase 4: Scan forward for newer major versions
  for major in (bestMajor + 1)..(bestMajor + 5):
    let (found, minor, patch) = scanMajor(client, major, platform)
    if found:
      bestMajor = major
      bestMinor = minor
      bestPatch = patch
    else:
      break

  if probeCount >= 5:
    stdout.write("\n")
    stdout.flushFile()
  probeCount = 0

  let version = &"{bestMajor}.{bestMinor}.{bestPatch}.0"
  let filename = &"ERiC-{version}-{platform}.jar"
  let url = &"{ElsterDownloadBase}/eric_{bestMajor}/{filename}"
  result.add(EricDownload(version: version, url: url, filename: filename))

# ===========================================================================
# Version detection
# ===========================================================================

proc findEricVersion*(path: string): string =
  ## Try to extract version from directory name or version file
  let dirName = path.extractFilename
  if dirName.startsWith("ERiC-"):
    let parts = dirName.split("-")
    if parts.len >= 2:
      return parts[1]

  let parentName = path.parentDir.extractFilename
  if parentName.startsWith("ERiC-"):
    let parts = parentName.split("-")
    if parts.len >= 2:
      return parts[1]

  for f in ["version.txt", "VERSION", "version"]:
    let versionFile = path / f
    if fileExists(versionFile):
      return readFile(versionFile).strip()

  return "unknown"

# ===========================================================================
# Installation checking
# ===========================================================================

proc checkEricInstallation*(basePath: string): EricInstallation =
  ## Check if ERiC is properly installed at the given path
  result.path = basePath
  result.valid = false
  result.missingFiles = @[]

  if not dirExists(basePath):
    result.missingFiles.add("Directory does not exist: " & basePath)
    return

  var libPath = ""
  var pluginPath = ""

  let possibleLibPaths = [
    basePath / EricLibDir,
    basePath / "Linux-x86_64" / EricLibDir,
    basePath,
  ]

  for p in possibleLibPaths:
    if dirExists(p) and fileExists(p / "libericapi.so"):
      libPath = p
      break

  if libPath == "":
    result.missingFiles.add("Could not find lib directory with libericapi.so")
    return

  result.libPath = libPath

  for lib in RequiredLibs:
    if not fileExists(libPath / lib):
      result.missingFiles.add("Missing library: " & lib)

  let possiblePluginPaths = [
    libPath / EricPluginDir,
    basePath / EricPluginDir,
    libPath / "plugins",
  ]

  for p in possiblePluginPaths:
    if dirExists(p):
      pluginPath = p
      break

  if pluginPath == "":
    result.missingFiles.add("Could not find plugins directory")
  else:
    result.pluginPath = pluginPath

  result.version = findEricVersion(basePath)
  result.valid = result.missingFiles.len == 0

# ===========================================================================
# Archive extraction
# ===========================================================================

proc extractJar*(jarPath: string, destPath: string): bool =
  ## Extract ERiC JAR/ZIP file using unzip or jar command
  if not fileExists(jarPath):
    echo &"Error: File not found: {jarPath}"
    return false

  createDir(destPath)

  var cmd = ""
  if findExe("unzip") != "":
    cmd = &"unzip -o -q \"{jarPath}\" -d \"{destPath}\""
  elif findExe("jar") != "":
    cmd = &"cd \"{destPath}\" && jar -xf \"{jarPath}\""
  else:
    echo "Error: Neither 'unzip' nor 'jar' command found. Please install one of them."
    return false

  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo &"Error extracting archive: {output}"
    return false

  return true

proc extractTarGz(archivePath: string, destPath: string): bool =
  ## Extract a .tar.gz archive
  if not fileExists(archivePath):
    echo &"Error: File not found: {archivePath}"
    return false
  createDir(destPath)
  let (output, exitCode) = execCmdEx(&"tar -xzf \"{archivePath}\" -C \"{destPath}\"")
  if exitCode != 0:
    echo &"Error extracting archive: {output}"
    return false
  return true

proc extractArchive*(archivePath: string, destPath: string): bool =
  ## Extract JAR/ZIP or tar.gz archive
  let lower = archivePath.toLowerAscii
  if lower.endsWith(".tar.gz") or lower.endsWith(".tgz"):
    return extractTarGz(archivePath, destPath)
  else:
    return extractJar(archivePath, destPath)

proc findExtractedEricDir*(basePath: string): string =
  ## Find the actual ERiC directory after extraction (may be nested)
  for kind, path in walkDir(basePath):
    if kind == pcDir:
      let name = path.extractFilename
      if name.startsWith("ERiC-"):
        # Check if there's a platform subdirectory
        for subKind, subPath in walkDir(path):
          if subKind == pcDir and subPath.extractFilename.contains("Linux"):
            return subPath
        return path
  return basePath

proc setupEric*(archivePath: string, installDir: string = ""): EricInstallation =
  ## Extract and set up ERiC from an archive file (JAR/ZIP/tar.gz)
  let targetDir = if installDir == "": getEricCacheDir() else: installDir

  echo &"Extracting ERiC from {archivePath} to {targetDir}..."

  if not extractArchive(archivePath, targetDir):
    result.valid = false
    result.missingFiles = @["Failed to extract archive"]
    return

  let ericDir = findExtractedEricDir(targetDir)
  echo &"Found ERiC installation at: {ericDir}"

  result = checkEricInstallation(ericDir)

  if result.valid:
    echo "ERiC installation verified successfully!"
    echo &"  Version: {result.version}"
    echo &"  Library path: {result.libPath}"
    echo &"  Plugin path: {result.pluginPath}"
    # Remove the archive now that extraction succeeded
    if fileExists(archivePath):
      removeFile(archivePath)
      echo &"  Removed archive: {archivePath}"
  else:
    echo "ERiC installation has issues:"
    for issue in result.missingFiles:
      echo &"  - {issue}"

# ===========================================================================
# File download helpers
# ===========================================================================

proc downloadFile*(url: string, destPath: string): bool =
  ## Download a file from URL to destination path
  try:
    let client = newHttpClient()
    defer: client.close()
    var lastPct = -1
    stdout.write(&"  {url.split(\"/\")[^1]} ")
    stdout.flushFile()
    client.onProgressChanged = proc(total, progress, speed: BiggestInt) {.closure.} =
      if total > 0:
        let pct = int(progress * 100 div total)
        if pct div 10 > lastPct div 10:
          lastPct = pct
          stdout.write(&"{pct}% ")
          stdout.flushFile()
      elif progress > 0 and progress mod (5 * 1024 * 1024) < 65536:
        stdout.write(".")
        stdout.flushFile()
    client.downloadFile(url, destPath)
    stdout.write("\n")
    return true
  except:
    echo ""
    echo &"Error downloading {url}: {getCurrentExceptionMsg()}"
    return false

proc extractZip*(zipPath: string, destPath: string, specificFile: string = ""): bool =
  ## Extract a ZIP file, optionally extracting only a specific file
  if not fileExists(zipPath):
    echo &"Error: ZIP file not found: {zipPath}"
    return false

  createDir(destPath)

  var cmd = ""
  if specificFile != "":
    cmd = &"unzip -o -j \"{zipPath}\" \"{specificFile}\" -d \"{destPath}\""
  else:
    cmd = &"unzip -o -q \"{zipPath}\" -d \"{destPath}\""

  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    echo &"Error extracting ZIP: {output}"
    return false

  return true

# ===========================================================================
# ZIP inspection
# ===========================================================================

proc findPfxInZip*(zipPath: string): seq[string] =
  ## List .pfx certificate files inside a ZIP archive
  result = @[]
  let (output, exitCode) = execCmdEx(&"unzip -l \"{zipPath}\"")
  if exitCode != 0: return
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.toLowerAscii.endsWith(".pfx"):
      let parts = trimmed.splitWhitespace()
      if parts.len >= 4:
        result.add(parts[^1])

# ===========================================================================
# Certificate download
# ===========================================================================

proc downloadTestCertificates*(): tuple[certPath: string, pin: string, success: bool] =
  ## Download ELSTER test certificates
  let cacheDir = getCertCacheDir()
  createDir(cacheDir)

  let zipPath = cacheDir / "Test_Zertifikate.zip"

  # Check if we already have .pfx files - prefer org cert for UStVA
  var existing: seq[string] = @[]
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.toLowerAscii.endsWith(".pfx"):
      existing.add(path)
  if existing.len > 0:
    # Prefer softorg cert (needed for UStVA submission)
    var best = existing[0]
    for path in existing:
      if "softorg" in path.extractFilename.toLowerAscii:
        best = path
    echo &"Test certificate: {best}"
    return (best, TestCertPin, true)

  # Download
  if not downloadFile(TestCertUrl, zipPath):
    return ("", "", false)

  # Find .pfx files in the ZIP (don't hardcode names)
  let pfxFiles = findPfxInZip(zipPath)
  if pfxFiles.len == 0:
    echo "Error: No .pfx files found in certificate archive"
    removeFile(zipPath)
    return ("", "", false)

  echo &"Found {pfxFiles.len} certificate(s): {pfxFiles.join(\", \")}"

  for pfx in pfxFiles:
    discard extractZip(zipPath, cacheDir, pfx)

  removeFile(zipPath)

  # Return best cert - prefer softorg (organizational cert for UStVA)
  var allCerts: seq[string] = @[]
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.toLowerAscii.endsWith(".pfx"):
      allCerts.add(path)
  if allCerts.len > 0:
    var best = allCerts[0]
    for path in allCerts:
      if "softorg" in path.extractFilename.toLowerAscii:
        best = path
    echo &"Test certificate: {best}"
    echo &"PIN: {TestCertPin}"
    return (best, TestCertPin, true)

  echo "Error: Certificate file not found after extraction"
  return ("", "", false)

# ===========================================================================
# Existing installation lookup
# ===========================================================================

proc findExistingEric*(): EricInstallation =
  ## Look for existing ERiC installation in cache
  let cacheDir = getEricCacheDir()
  if not dirExists(cacheDir):
    result.valid = false
    return

  for kind, path in walkDir(cacheDir):
    if kind == pcDir:
      let installation = checkEricInstallation(path)
      if installation.valid:
        return installation

      let subDir = findExtractedEricDir(path)
      if subDir != path:
        let subInstallation = checkEricInstallation(subDir)
        if subInstallation.valid:
          return subInstallation

  result.valid = false

# ===========================================================================
# .env management
# ===========================================================================

proc generateEnvConfig*(installation: EricInstallation, certPath: string = "", certPin: string = ""): string =
  ## Generate .env configuration for the ERiC installation
  result = &"""
# ERiC Library Configuration (auto-generated by viking fetch)
ERIC_LIB_PATH={installation.libPath / "libericapi.so"}
ERIC_PLUGIN_PATH={installation.pluginPath}
ERIC_LOG_PATH=/tmp/eric_logs
"""

  if certPath != "":
    result.add(&"\n# Test Certificate (from ELSTER)\nCERT_PATH={certPath}\n")
  else:
    result.add("\n# Certificate Configuration\nCERT_PATH=/path/to/certificate.pfx\n")

  if certPin != "":
    result.add(&"CERT_PIN={certPin}\n")
  else:
    result.add("CERT_PIN=your-certificate-pin\n")

  result.add("\n# Tax Information (test tax number for sandbox)\n")
  result.add("STEUERNUMMER=9198011310010\n")

proc updateEnvFile*(installation: EricInstallation, certPath: string = "", certPin: string = "", envPath: string = ".env") =
  ## Update or create .env file with ERiC configuration
  var content = ""
  var existingLines: seq[string] = @[]

  if fileExists(envPath):
    content = readFile(envPath)
    existingLines = content.splitLines()

    var foundLib, foundPlugin, foundLog, foundCert, foundPin, foundStnr = false

    for i, line in existingLines:
      if line.startsWith("ERIC_LIB_PATH="):
        existingLines[i] = &"ERIC_LIB_PATH={installation.libPath / \"libericapi.so\"}"
        foundLib = true
      elif line.startsWith("ERIC_PLUGIN_PATH="):
        existingLines[i] = &"ERIC_PLUGIN_PATH={installation.pluginPath}"
        foundPlugin = true
      elif line.startsWith("ERIC_LOG_PATH="):
        foundLog = true
      elif line.startsWith("CERT_PATH=") and certPath != "":
        existingLines[i] = &"CERT_PATH={certPath}"
        foundCert = true
      elif line.startsWith("CERT_PIN=") and certPin != "":
        existingLines[i] = &"CERT_PIN={certPin}"
        foundPin = true
      elif line.startsWith("STEUERNUMMER="):
        foundStnr = true

    if not foundLib:
      existingLines.add(&"ERIC_LIB_PATH={installation.libPath / \"libericapi.so\"}")
    if not foundPlugin:
      existingLines.add(&"ERIC_PLUGIN_PATH={installation.pluginPath}")
    if not foundLog:
      existingLines.add("ERIC_LOG_PATH=/tmp/eric_logs")
    if not foundCert and certPath != "":
      existingLines.add(&"CERT_PATH={certPath}")
    if not foundPin and certPin != "":
      existingLines.add(&"CERT_PIN={certPin}")
    if not foundStnr:
      existingLines.add("STEUERNUMMER=9198011310010")

    content = existingLines.join("\n")
  else:
    content = generateEnvConfig(installation, certPath, certPin)

  writeFile(envPath, content)
  echo &"Updated {envPath}"

# ===========================================================================
# Status and instructions
# ===========================================================================

proc printDownloadInstructions*() =
  ## Print instructions for manual ERiC download
  let cacheDir = getEricCacheDir()
  echo &"""
================================================================================
                        ERiC Library Download Instructions
================================================================================

The ERiC (ELSTER Rich Client) library is available from the ELSTER developer
portal.

Option 1 - Manual download:
----------------------------
1. Go to: {ElsterDevUrl}
2. Log in with: entwickler / p?cS1B3f
3. Accept the license agreement
4. Download: ERiC-XX.X.X.X-Linux-x86_64.jar
5. Run: viking fetch --file=/path/to/downloaded/ERiC-*.jar

Option 2 - Direct URL (if you know the version):
-------------------------------------------------
  {ElsterDownloadBase}/eric_43/ERiC-43.3.2.0-Linux-x86_64.jar

The fetch command will:
- Extract the archive to: {cacheDir}
- Download test certificates automatically
- Update your .env file with the correct paths

================================================================================
"""

proc printStatus*(installation: EricInstallation) =
  ## Print the status of an ERiC installation
  if installation.valid:
    echo "ERiC Status: INSTALLED"
    echo &"  Version:     {installation.version}"
    echo &"  Library:     {installation.libPath / \"libericapi.so\"}"
    echo &"  Plugins:     {installation.pluginPath}"
  else:
    echo "ERiC Status: NOT INSTALLED or INCOMPLETE"
    if installation.missingFiles.len > 0:
      echo "  Issues:"
      for issue in installation.missingFiles:
        echo &"    - {issue}"
    echo ""
    echo "Run 'viking fetch' to download and install."

proc listAvailableYears*(installation: EricInstallation): seq[int] =
  ## List years for which UStVA plugins are available
  result = @[]
  if not installation.valid:
    return

  for kind, path in walkDir(installation.pluginPath):
    if kind == pcFile:
      let name = path.extractFilename
      if name.startsWith("libcheckUStVA_") and name.endsWith(".so"):
        let yearStr = name[14..^4]
        try:
          result.add(parseInt(yearStr))
        except ValueError:
          discard

  result.sort()

proc listAvailableEstYears*(installation: EricInstallation): seq[int] =
  ## List years for which ESt plugins are available
  result = @[]
  if not installation.valid:
    return

  for kind, path in walkDir(installation.pluginPath):
    if kind == pcFile:
      let name = path.extractFilename
      if name.startsWith("libcheckESt_") and name.endsWith(".so"):
        let yearStr = name[12..^4]
        try:
          result.add(parseInt(yearStr))
        except ValueError:
          discard

  result.sort()

proc listAvailableUstYears*(installation: EricInstallation): seq[int] =
  ## List years for which USt (annual VAT) plugins are available
  result = @[]
  if not installation.valid:
    return

  for kind, path in walkDir(installation.pluginPath):
    if kind == pcFile:
      let name = path.extractFilename
      # Match libcheckUSt_YYYY.so but NOT libcheckUStVA_YYYY.so
      if name.startsWith("libcheckUSt_") and not name.startsWith("libcheckUStVA_") and name.endsWith(".so"):
        let yearStr = name[12..^4]
        try:
          result.add(parseInt(yearStr))
        except ValueError:
          discard

  result.sort()

proc listAvailableEuerYears*(installation: EricInstallation): seq[int] =
  ## List years for which EUER plugins are available
  result = @[]
  if not installation.valid:
    return

  for kind, path in walkDir(installation.pluginPath):
    if kind == pcFile:
      let name = path.extractFilename
      if name.startsWith("libcheckEUER_") and name.endsWith(".so"):
        let yearStr = name[13..^4]
        try:
          result.add(parseInt(yearStr))
        except ValueError:
          discard

  result.sort()

# ===========================================================================
# Auto-download orchestrator
# ===========================================================================

proc fetchEric*(): tuple[installation: EricInstallation, success: bool] =
  ## Auto-download ERiC from download.elster.de
  echo "=== ERiC Library ==="
  echo "Discovering latest ERiC version..."
  echo ""

  let cacheDir = getEricCacheDir()
  createDir(cacheDir)

  let downloads = discoverEricDownloads()

  if downloads.len == 0:
    echo ""
    echo "Could not discover ERiC version automatically."
    echo "Please download manually and use: viking fetch --file=<path>"
    echo ""
    printDownloadInstructions()
    return (EricInstallation(valid: false), false)

  let latest = downloads[^1]
  echo &"  Latest version: {latest.version}"
  let archivePath = cacheDir / latest.filename

  if fileExists(archivePath):
    echo &"  Archive already cached: {archivePath}"
  else:
    echo &"  Downloading {latest.filename}..."
    if not downloadFile(latest.url, archivePath):
      return (EricInstallation(valid: false), false)

  echo ""
  let installation = setupEric(archivePath)
  return (installation, installation.valid)

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--check":
    let existing = findExistingEric()
    if existing.valid:
      printStatus(existing)
    else:
      echo "No ERiC installation found."
  else:
    let (installation, success) = fetchEric()
    if not success:
      quit(1)
