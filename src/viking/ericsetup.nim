## ERiC Library Setup Tool
## Downloads, extracts, and configures the ERiC library for viking

import std/[os, strutils, strformat, httpclient, algorithm]
import zippy/ziparchives
from std/appdirs import nil

when defined(windows):
  const
    EricLibDir* = "dll"
    EricPluginDir* = "plugins"
else:
  const
    EricLibDir* = "lib"
    EricPluginDir* = "plugins2"

# Required library files (platform-specific)
when defined(macosx):
  const
    DynlibExt* = ".dylib"
    RequiredLibs = ["libericapi.dylib", "libericxerces.dylib", "libeSigner.dylib"]
    EricApiLib* = "libericapi.dylib"
    PlatformDirPrefix = "Darwin"
    PluginPrefix* ="libcheck"
elif defined(windows):
  const
    DynlibExt* = ".dll"
    RequiredLibs = ["ericapi.dll", "ericxerces.dll", "eSigner.dll"]
    EricApiLib* = "ericapi.dll"
    PlatformDirPrefix = "Windows"
    PluginPrefix* ="check"
else:
  const
    DynlibExt* = ".so"
    RequiredLibs = ["libericapi.so", "libericxerces.so", "libeSigner.so"]
    EricApiLib* = "libericapi.so"
    PlatformDirPrefix = "Linux"
    PluginPrefix* ="libcheck"

const
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

proc getAppDataDir*(): string =
  ## Get the data directory. Honors VIKING_DATA_DIR env var,
  ## falls back to OS-appropriate data dir (~/.local/share/viking on Linux,
  ## ~/Library/Application Support/viking on macOS, %APPDATA%/viking on Windows)
  result = getEnv("VIKING_DATA_DIR")
  if result == "":
    result = appdirs.getDataDir().string / AppName

proc getEricDataDir*(): string =
  ## Get the ERiC-specific data directory
  getAppDataDir() / "eric"

proc getCertDataDir*(): string =
  ## Get the certificate data directory
  getAppDataDir() / "certificates"

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
# Version lookup (hardcoded — TODO: proper lookup, see .claude/state.md)
# ===========================================================================

const
  EricMajor = 43
  EricMinor = 3
  EricPatch = 2

proc discoverEricDownloads*(): seq[EricDownload] =
  let platform = getEricPlatform()
  let version = &"{EricMajor}.{EricMinor}.{EricPatch}.0"
  let filename = &"ERiC-{version}-{platform}.jar"
  let url = &"{ElsterDownloadBase}/eric_{EricMajor}/{filename}"
  result = @[EricDownload(version: version, url: url, filename: filename)]

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
    basePath / getEricPlatform() / EricLibDir,
    basePath,
  ]

  for p in possibleLibPaths:
    if dirExists(p) and fileExists(p / EricApiLib):
      libPath = p
      break

  if libPath == "":
    result.missingFiles.add("Could not find lib directory with " & EricApiLib)
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

proc extractArchive*(archivePath: string, destPath: string): bool =
  ## Extract JAR/ZIP archive using zippy (pure Nim, cross-platform)
  if not fileExists(archivePath):
    stderr.writeLine &"Error: File not found: {archivePath}"
    return false
  try:
    if dirExists(destPath):
      removeDir(destPath)
    createDir(destPath.parentDir)
    ziparchives.extractAll(archivePath, destPath)
    return true
  except ZippyError as e:
    stderr.writeLine &"Error extracting archive: {e.msg}"
    return false
  except OSError as e:
    stderr.writeLine &"Error extracting archive (OS): {e.msg}"
    return false

proc findExtractedEricDir*(basePath: string): string =
  ## Find the actual ERiC directory after extraction (may be nested)
  for kind, path in walkDir(basePath):
    if kind == pcDir:
      let name = path.extractFilename
      if name.startsWith("ERiC-"):
        # Check if there's a platform subdirectory
        for subKind, subPath in walkDir(path):
          if subKind == pcDir and subPath.extractFilename.contains(PlatformDirPrefix):
            return subPath
        return path
  return basePath

proc setupEric*(archivePath: string, installDir: string = ""): EricInstallation =
  ## Extract and set up ERiC from an archive file (JAR/ZIP/tar.gz)
  let targetDir = if installDir == "": getEricDataDir() else: installDir

  if not extractArchive(archivePath, targetDir):
    result.valid = false
    result.missingFiles = @["Failed to extract archive"]
    return

  let ericDir = findExtractedEricDir(targetDir)
  result = checkEricInstallation(ericDir)

  if result.valid:
    if fileExists(archivePath):
      removeFile(archivePath)
  else:
    stderr.writeLine "ERiC installation has issues:"
    for issue in result.missingFiles:
      stderr.writeLine &"  - {issue}"

# ===========================================================================
# File download helpers
# ===========================================================================

proc downloadFile*(url: string, destPath: string): bool =
  ## Download a file from URL to destination path
  try:
    let client = newHttpClient()
    defer: client.close()
    var lastPct = -1
    stderr.write(&"  {url.split(\"/\")[^1]} ")
    stderr.flushFile()
    client.onProgressChanged = proc(total, progress, speed: BiggestInt) {.closure.} =
      if total > 0:
        let pct = int(progress * 100 div total)
        if pct div 10 > lastPct div 10:
          lastPct = pct
          stderr.write(&"{pct}% ")
          stderr.flushFile()
      elif progress > 0 and progress mod (5 * 1024 * 1024) < 65536:
        stderr.write(".")
        stderr.flushFile()
    client.downloadFile(url, destPath)
    stderr.write("\n")
    return true
  except:
    stderr.writeLine ""
    stderr.writeLine &"Error downloading {url}: {getCurrentExceptionMsg()}"
    return false

proc extractZip*(zipPath: string, destPath: string, specificFile: string = ""): bool =
  ## Extract a ZIP file, optionally extracting only a specific file
  if not fileExists(zipPath):
    stderr.writeLine &"Error: ZIP file not found: {zipPath}"
    return false
  createDir(destPath)
  try:
    if specificFile == "":
      ziparchives.extractAll(zipPath, destPath)
    else:
      let reader = openZipArchive(zipPath)
      defer: reader.close()
      let target = specificFile.extractFilename
      for path in reader.walkFiles:
        if path.extractFilename == target:
          writeFile(destPath / target, reader.extractFile(path))
          break
    return true
  except ZippyError as e:
    stderr.writeLine &"Error extracting ZIP: {e.msg}"
    return false

# ===========================================================================
# ZIP inspection
# ===========================================================================

proc findPfxInZip*(zipPath: string): seq[string] =
  ## List .pfx certificate files inside a ZIP archive
  result = @[]
  try:
    let reader = openZipArchive(zipPath)
    defer: reader.close()
    for path in reader.walkFiles:
      if path.toLowerAscii.endsWith(".pfx"):
        result.add(path)
  except ZippyError:
    discard

# ===========================================================================
# Certificate download
# ===========================================================================

proc downloadTestCertificates*(): tuple[certPath: string, pin: string, success: bool] =
  ## Download ELSTER test certificates
  let cacheDir = getCertDataDir()
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
    return (best, TestCertPin, true)

  # Download
  if not downloadFile(TestCertUrl, zipPath):
    return ("", "", false)

  # Find .pfx files in the ZIP (don't hardcode names)
  let pfxFiles = findPfxInZip(zipPath)
  if pfxFiles.len == 0:
    stderr.writeLine "Error: No .pfx files found in certificate archive"
    removeFile(zipPath)
    return ("", "", false)

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
    return (best, TestCertPin, true)

  stderr.writeLine "Error: Certificate file not found after extraction"
  return ("", "", false)

# ===========================================================================
# Existing installation lookup
# ===========================================================================

proc findExistingEric*(): EricInstallation =
  ## Look for existing ERiC installation in data directory
  let cacheDir = getEricDataDir()
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
  let logPath = getTempDir() / "eric_logs"
  result = &"""
# ERiC Library Configuration (auto-generated by viking fetch)
VIKING_ERIC_LIB_PATH={installation.libPath / EricApiLib}
VIKING_ERIC_PLUGIN_PATH={installation.pluginPath}
VIKING_ERIC_LOG_PATH={logPath}
"""

  if certPath != "":
    result.add(&"\n# Test Certificate (from ELSTER)\nVIKING_CERT_PATH={certPath}\n")
  else:
    result.add("\n# Certificate Configuration\nVIKING_CERT_PATH=/path/to/certificate.pfx\n")

  if certPin != "":
    result.add(&"VIKING_CERT_PIN={certPin}\n")
  else:
    result.add("VIKING_CERT_PIN=your-certificate-pin\n")

  result.add("\n# Personal data goes in viking.conf (see 'viking init')\n")

proc updateEnvFile*(installation: EricInstallation, certPath: string = "", certPin: string = "", envPath: string = ".env") =
  ## Update or create .env file with ERiC configuration
  var content = ""
  var existingLines: seq[string] = @[]

  if fileExists(envPath):
    content = readFile(envPath)
    existingLines = content.splitLines()

    var foundLib, foundPlugin, foundLog, foundCert, foundPin = false

    for i, line in existingLines:
      if line.startsWith("VIKING_ERIC_LIB_PATH="):
        existingLines[i] = &"VIKING_ERIC_LIB_PATH={installation.libPath / EricApiLib}"
        foundLib = true
      elif line.startsWith("VIKING_ERIC_PLUGIN_PATH="):
        existingLines[i] = &"VIKING_ERIC_PLUGIN_PATH={installation.pluginPath}"
        foundPlugin = true
      elif line.startsWith("VIKING_ERIC_LOG_PATH="):
        foundLog = true
      elif line.startsWith("VIKING_CERT_PATH=") and certPath != "":
        existingLines[i] = &"VIKING_CERT_PATH={certPath}"
        foundCert = true
      elif line.startsWith("VIKING_CERT_PIN=") and certPin != "":
        existingLines[i] = &"VIKING_CERT_PIN={certPin}"
        foundPin = true

    if not foundLib:
      existingLines.add(&"VIKING_ERIC_LIB_PATH={installation.libPath / EricApiLib}")
    if not foundPlugin:
      existingLines.add(&"VIKING_ERIC_PLUGIN_PATH={installation.pluginPath}")
    if not foundLog:
      existingLines.add("VIKING_ERIC_LOG_PATH=" & getTempDir() / "eric_logs")
    if not foundCert and certPath != "":
      existingLines.add(&"VIKING_CERT_PATH={certPath}")
    if not foundPin and certPin != "":
      existingLines.add(&"VIKING_CERT_PIN={certPin}")

    content = existingLines.join("\n")
  else:
    content = generateEnvConfig(installation, certPath, certPin)

  writeFile(envPath, content)

# ===========================================================================
# Status and instructions
# ===========================================================================

proc printDownloadInstructions*() =
  ## Print instructions for manual ERiC download
  let dataDir = getEricDataDir()
  stderr.writeLine &"""
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
4. Download: ERiC-XX.X.X.X-{getEricPlatform()}.jar
5. Run: viking fetch --file=/path/to/downloaded/ERiC-*.jar

Option 2 - Direct URL (if you know the version):
-------------------------------------------------
  {ElsterDownloadBase}/eric_43/ERiC-43.3.2.0-{getEricPlatform()}.jar

The fetch command will:
- Extract the archive to: {dataDir}
- Download test certificates automatically
- Update your .env file with the correct paths

================================================================================
"""

proc printStatus*(installation: EricInstallation) =
  ## Print the status of an ERiC installation (called by --check)
  if installation.valid:
    echo "ERiC Status: INSTALLED"
    echo &"  Version:     {installation.version}"
    echo &"  Library:     {installation.libPath / EricApiLib}"
    echo &"  Plugins:     {installation.pluginPath}"
  else:
    stderr.writeLine "ERiC Status: NOT INSTALLED or INCOMPLETE"
    if installation.missingFiles.len > 0:
      stderr.writeLine "  Issues:"
      for issue in installation.missingFiles:
        stderr.writeLine &"    - {issue}"
    stderr.writeLine ""
    stderr.writeLine "Run 'viking fetch' to download and install."

proc listAvailableYears*(installation: EricInstallation): seq[int] =
  ## List years for which UStVA plugins are available
  result = @[]
  if not installation.valid:
    return

  for kind, path in walkDir(installation.pluginPath):
    if kind == pcFile:
      let name = path.extractFilename
      let uStVAPrefix = PluginPrefix & "UStVA_"
      if name.startsWith(uStVAPrefix) and name.endsWith(DynlibExt):
        let yearStr = name[uStVAPrefix.len ..^ (DynlibExt.len + 1)]
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
      let eStPrefix = PluginPrefix & "ESt_"
      if name.startsWith(eStPrefix) and name.endsWith(DynlibExt):
        let yearStr = name[eStPrefix.len ..^ (DynlibExt.len + 1)]
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
      let uStPrefix = PluginPrefix & "USt_"
      let uStVAPrefix2 = PluginPrefix & "UStVA_"
      if name.startsWith(uStPrefix) and not name.startsWith(uStVAPrefix2) and name.endsWith(DynlibExt):
        let yearStr = name[uStPrefix.len ..^ (DynlibExt.len + 1)]
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
      let euerPrefix = PluginPrefix & "EUER_"
      if name.startsWith(euerPrefix) and name.endsWith(DynlibExt):
        let yearStr = name[euerPrefix.len ..^ (DynlibExt.len + 1)]
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
  let dataDir = getEricDataDir()
  createDir(dataDir)

  let downloads = discoverEricDownloads()

  if downloads.len == 0:
    stderr.writeLine "Could not discover ERiC version automatically."
    stderr.writeLine "Please download manually and use: viking fetch --file=<path>"
    printDownloadInstructions()
    return (EricInstallation(valid: false), false)

  let latest = downloads[^1]
  let archivePath = getTempDir() / latest.filename

  if not downloadFile(latest.url, archivePath):
    return (EricInstallation(valid: false), false)

  let installation = setupEric(archivePath)
  return (installation, installation.valid)
