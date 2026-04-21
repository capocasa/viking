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

  # App name for data directory
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
  ## Default data directory for viking: platform-specific user data dir.
  ## (~/.local/share/viking on Linux, ~/Library/Application Support/viking on
  ## macOS, %APPDATA%/viking on Windows.) `VIKING_DATA_DIR` env var overrides
  ## (used by CI). Callers with a --data-dir value should use that directly.
  let envDir = getEnv("VIKING_DATA_DIR")
  if envDir != "":
    return envDir
  result = appdirs.getDataDir().string / AppName

proc getEricDataDir*(dataDir: string = ""): string =
  ## ERiC install directory under the given data dir (or the default one).
  (if dataDir != "": dataDir else: getAppDataDir()) / "eric"

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
  ## Selectively extract the ERiC jar: keep the current-platform tree only.
  ## Drops docs/, samples/, include/, other platforms, and anything else.
  if not fileExists(archivePath):
    stderr.writeLine &"Error: File not found: {archivePath}"
    return false
  try:
    if dirExists(destPath):
      removeDir(destPath)
    createDir(destPath.parentDir)
    createDir(destPath)
    let reader = openZipArchive(archivePath)
    defer: reader.close()
    let platform = PlatformDirPrefix
    for entry in reader.walkFiles:
      # Entries look like "ERiC-43.4.6.0/Linux-x86_64/lib/libericapi.so".
      # Keep entries under <root>/<Platform>-* (the current platform's tree).
      let parts = entry.split('/')
      if parts.len < 3: continue
      if not parts[1].startsWith(platform): continue
      let outPath = destPath / entry
      createDir(outPath.parentDir)
      writeFile(outPath, reader.extractFile(entry))
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

proc setupEric*(archivePath: string, installDir: string): EricInstallation =
  ## Extract and set up ERiC from an archive file into installDir (the
  ## `<data-dir>/eric` directory).
  if not extractArchive(archivePath, installDir):
    result.valid = false
    result.missingFiles = @["Failed to extract archive"]
    return

  let ericDir = findExtractedEricDir(installDir)
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

# ===========================================================================
# Existing installation lookup
# ===========================================================================

proc findExistingEric*(ericDir: string): EricInstallation =
  ## Look for an existing ERiC installation in the given ericDir
  ## (typically `<data-dir>/eric`).
  if not dirExists(ericDir):
    result.valid = false
    return

  for kind, path in walkDir(ericDir):
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

proc findExistingEricIn*(ericDir: string): EricInstallation {.inline.} =
  ## Alias for use by config.nim.
  findExistingEric(ericDir)

# ===========================================================================
# Status and instructions
# ===========================================================================

proc printDownloadInstructions*(dataDir: string) =
  ## Print instructions for manual ERiC download
  let ericDir = getEricDataDir(dataDir)
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

The fetch command will extract only the current platform's files to:
  {ericDir}

For sandbox testing, also download ELSTER's test certificates from:
  https://download.elster.de/download/schnittstellen/Test_Zertifikate.zip
(PIN for all test certs: 123456)

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

proc fetchEric*(dataDir: string): tuple[installation: EricInstallation, success: bool] =
  ## Auto-download ERiC from download.elster.de into `<dataDir>/eric`.
  let ericDir = getEricDataDir(dataDir)
  createDir(ericDir)

  let downloads = discoverEricDownloads()

  if downloads.len == 0:
    stderr.writeLine "Could not discover ERiC version automatically."
    stderr.writeLine "Please download manually and use: viking fetch --file=<path>"
    printDownloadInstructions(dataDir)
    return (EricInstallation(valid: false), false)

  let latest = downloads[^1]
  let archivePath = getTempDir() / latest.filename

  if not downloadFile(latest.url, archivePath):
    return (EricInstallation(valid: false), false)

  let installation = setupEric(archivePath, ericDir)
  return (installation, installation.valid)
