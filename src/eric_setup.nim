## ERiC Library Setup Tool
## Downloads, extracts, and configures the ERiC library for viking

import std/[os, osproc, strutils, strformat, httpclient, streams, algorithm, uri, tables]

const
  EricLibDir* = "lib"
  EricPluginDir* = "plugins2"

  # Required library files
  RequiredLibs = ["libericapi.so", "libericxerces.so", "libeSigner.so"]

  # ELSTER Developer Portal (shared credentials for developer access)
  ElsterLoginUrl = "https://www.elster.de/elsterweb/entwickler/login"
  ElsterEricPageUrl = "https://www.elster.de/elsterweb/entwickler/infoseite/eric"
  ElsterDevUsername = "entwickler"
  ElsterDevPassword = "p?cS1B3f"

  # Direct download base
  ElsterDownloadBase = "https://download.elster.de/download/schnittstellen"

  # ELSTER URLs (for instructions)
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

  PortalClient = object
    client: HttpClient
    cookies: string

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
# HTML parsing helpers (simple, no external deps)
# ===========================================================================

proc extractAttr(tag, attr: string): string =
  ## Extract an attribute value from an HTML tag string
  let lowerTag = tag.toLowerAscii
  let lowerAttr = attr.toLowerAscii
  for quote in ["\"", "'"]:
    let pattern = lowerAttr & "=" & quote
    let pos = lowerTag.find(pattern)
    if pos >= 0:
      let start = pos + pattern.len
      let endPos = tag.find(quote[0], start)
      if endPos >= 0:
        return tag[start..<endPos]
  return ""

proc findInputTags(html: string): seq[string] =
  ## Find all <input ...> tags in HTML
  result = @[]
  var i = 0
  let lower = html.toLowerAscii
  while i < lower.len:
    let pos = lower.find("<input", i)
    if pos < 0: break
    let endPos = html.find(">", pos)
    if endPos < 0: break
    result.add(html[pos..endPos])
    i = endPos + 1

proc findHiddenInputs(html: string): seq[tuple[name, value: string]] =
  ## Extract hidden form fields from HTML
  result = @[]
  for tag in findInputTags(html):
    if extractAttr(tag, "type").toLowerAscii == "hidden":
      let name = extractAttr(tag, "name")
      if name != "":
        result.add((name, extractAttr(tag, "value")))

proc findFormAction(html: string): string =
  ## Find the action URL of the first <form> tag
  let lower = html.toLowerAscii
  let pos = lower.find("<form")
  if pos < 0: return ""
  let endPos = html.find(">", pos)
  if endPos < 0: return ""
  return extractAttr(html[pos..endPos], "action")

proc findDownloadLinks(html: string, pattern: string): seq[string] =
  ## Find all href values containing the given pattern
  result = @[]
  var i = 0
  let lower = html.toLowerAscii
  let lowerPattern = pattern.toLowerAscii
  while i < lower.len:
    let hrefPos = lower.find("href=", i)
    if hrefPos < 0: break
    if hrefPos + 5 >= html.len:
      break
    let quoteChar = html[hrefPos + 5]
    if quoteChar notin {'"', '\''}:
      i = hrefPos + 5
      continue
    let urlStart = hrefPos + 6
    let urlEnd = html.find(quoteChar, urlStart)
    if urlEnd < 0:
      i = urlStart
      continue
    let url = html[urlStart..<urlEnd]
    if lowerPattern in url.toLowerAscii:
      result.add(url)
    i = urlEnd + 1

proc resolveUrl(base, location: string): string =
  ## Resolve a possibly-relative URL against a base URL
  if location.startsWith("http"):
    return location
  let u = parseUri(base)
  let host = if u.port != "": u.hostname & ":" & u.port else: u.hostname
  if location.startsWith("/"):
    return u.scheme & "://" & host & location
  let lastSlash = u.path.rfind("/")
  let basePath = if lastSlash >= 0: u.path[0..lastSlash] else: "/"
  return u.scheme & "://" & host & basePath & location

# ===========================================================================
# Cookie-aware HTTP client for portal access
# ===========================================================================

proc newPortalClient(): PortalClient =
  result.client = newHttpClient()
  result.client.headers = newHttpHeaders({"User-Agent": "viking/0.1.0"})
  result.cookies = ""

proc close(pc: PortalClient) =
  pc.client.close()

proc extractSetCookies(resp: Response): string =
  ## Extract Set-Cookie values from response headers
  try:
    var parts: seq[string] = @[]
    for cookie in resp.headers.table.getOrDefault("set-cookie"):
      let value = cookie.split(";")[0].strip()
      if value != "":
        parts.add(value)
    return parts.join("; ")
  except:
    return ""

proc addCookies(pc: var PortalClient, resp: Response) =
  let newCookies = extractSetCookies(resp)
  if newCookies != "":
    if pc.cookies != "": pc.cookies.add("; ")
    pc.cookies.add(newCookies)

proc portalGet(pc: var PortalClient, url: string): Response =
  if pc.cookies != "":
    pc.client.headers["Cookie"] = pc.cookies
  result = pc.client.get(url)
  pc.addCookies(result)

proc portalPost(pc: var PortalClient, url, body: string): Response =
  pc.client.headers["Content-Type"] = "application/x-www-form-urlencoded"
  if pc.cookies != "":
    pc.client.headers["Cookie"] = pc.cookies
  result = pc.client.post(url, body = body)
  pc.addCookies(result)

proc portalDownload(pc: PortalClient, url, destPath: string) =
  if pc.cookies != "":
    pc.client.headers["Cookie"] = pc.cookies
  pc.client.downloadFile(url, destPath)

# ===========================================================================
# Portal login and download discovery
# ===========================================================================

proc loginDeveloperPortal(): PortalClient =
  ## Login to ELSTER developer portal, return authenticated client
  result = newPortalClient()

  # GET login page for session cookies and hidden form fields
  let getResp = result.portalGet(ElsterLoginUrl)
  let loginPage = getResp.body

  # Build form data: hidden fields first, then credentials
  var formParts: seq[string] = @[]
  for (name, value) in findHiddenInputs(loginPage):
    formParts.add(encodeUrl(name) & "=" & encodeUrl(value))
  formParts.add("username=" & encodeUrl(ElsterDevUsername))
  formParts.add("password=" & encodeUrl(ElsterDevPassword))

  # Determine POST target
  var postUrl = ElsterLoginUrl
  let action = findFormAction(loginPage)
  if action != "":
    postUrl = resolveUrl(ElsterLoginUrl, action)

  # POST credentials
  let postResp = result.portalPost(postUrl, formParts.join("&"))
  if postResp.code.int >= 400:
    raise newException(IOError, "Login failed: HTTP " & $postResp.code)

proc discoverEricDownloads(pc: var PortalClient): seq[EricDownload] =
  ## Scrape the ELSTER portal for ERiC download links
  result = @[]
  let resp = pc.portalGet(ElsterEricPageUrl)
  let links = findDownloadLinks(resp.body, "ERiC-")

  for href in links:
    let lower = href.toLowerAscii
    if "linux" in lower and "x86_64" in lower:
      var dl: EricDownload
      dl.url = if href.startsWith("http"): href
               else: resolveUrl(ElsterEricPageUrl, href)
      dl.filename = dl.url.split("/")[^1].split("?")[0]
      # Extract version from filename: ERiC-43.1.2.0-Linux-x86_64.jar
      let parts = dl.filename.split("-")
      if parts.len >= 2:
        dl.version = parts[1]
      result.add(dl)

  result.sort(proc(a, b: EricDownload): int = cmp(a.version, b.version))

proc tryDirectDiscovery(): seq[EricDownload] =
  ## Try to discover ERiC downloads via directory listing on download.elster.de
  result = @[]
  let client = newHttpClient()
  client.timeout = 10000
  defer: client.close()

  for base in [ElsterDownloadBase, ElsterDownloadBase & "/eric"]:
    try:
      let resp = client.get(base & "/")
      if resp.code == Http200:
        let links = findDownloadLinks(resp.body, "ERiC-")
        for href in links:
          let lower = href.toLowerAscii
          if "linux" in lower and "x86_64" in lower:
            var dl: EricDownload
            dl.url = resolveUrl(base & "/", href)
            dl.filename = dl.url.split("/")[^1].split("?")[0]
            let parts = dl.filename.split("-")
            if parts.len >= 2:
              dl.version = parts[1]
            result.add(dl)
        if result.len > 0:
          result.sort(proc(a, b: EricDownload): int = cmp(a.version, b.version))
          return
    except:
      discard

# ===========================================================================
# Version detection
# ===========================================================================

proc findEricVersion*(path: string): string =
  ## Try to extract version from directory name or version file
  let dirName = path.extractFilename
  # ERiC directories are typically named like "ERiC-41.2.10.0-Linux-x86_64"
  if dirName.startsWith("ERiC-"):
    let parts = dirName.split("-")
    if parts.len >= 2:
      return parts[1]

  # Check parent directory name
  let parentName = path.parentDir.extractFilename
  if parentName.startsWith("ERiC-"):
    let parts = parentName.split("-")
    if parts.len >= 2:
      return parts[1]

  # Try to find version.txt or similar
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

  # Find the lib directory (might be directly in basePath or in a subdirectory)
  var libPath = ""
  var pluginPath = ""

  # Check common structures
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

  # Check for required libraries
  for lib in RequiredLibs:
    if not fileExists(libPath / lib):
      result.missingFiles.add("Missing library: " & lib)

  # Find plugins directory
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

  # Create destination directory
  createDir(destPath)

  # Try unzip first, then jar
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
  # JAR extraction often creates a directory like ERiC-XX.X.X.X/Linux-x86_64/
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

  # Find the actual ERiC directory (may be nested after extraction)
  let ericDir = findExtractedEricDir(targetDir)
  echo &"Found ERiC installation at: {ericDir}"

  result = checkEricInstallation(ericDir)

  if result.valid:
    echo "ERiC installation verified successfully!"
    echo &"  Version: {result.version}"
    echo &"  Library path: {result.libPath}"
    echo &"  Plugin path: {result.pluginPath}"
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
    echo &"Downloading {url}..."
    let client = newHttpClient()
    defer: client.close()
    client.downloadFile(url, destPath)
    echo &"  Saved to {destPath}"
    return true
  except:
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

  # Check if we already have a .pfx file
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.toLowerAscii.endsWith(".pfx"):
      echo &"Test certificate already exists at {path}"
      return (path, TestCertPin, true)

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

  # Extract all .pfx files
  for pfx in pfxFiles:
    discard extractZip(zipPath, cacheDir, pfx)

  removeFile(zipPath)

  # Return the first .pfx found
  for kind, path in walkDir(cacheDir):
    if kind == pcFile and path.toLowerAscii.endsWith(".pfx"):
      echo &"Test certificate: {path}"
      echo &"PIN: {TestCertPin}"
      return (path, TestCertPin, true)

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

  # Look for ERiC directories
  for kind, path in walkDir(cacheDir):
    if kind == pcDir:
      let installation = checkEricInstallation(path)
      if installation.valid:
        return installation

      # Check subdirectories
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

    # Update existing values
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
  ## Print instructions for downloading ERiC
  let cacheDir = getEricCacheDir()
  echo &"""
================================================================================
                        ERiC Library Download Instructions
================================================================================

The ERiC (ELSTER Rich Client) library must be downloaded from the official
ELSTER developer portal.

Steps:
------
1. Go to: https://www.elster.de/elsterweb/entwickler/infoseite/eric

2. Log in with the shared developer credentials:
   Username: entwickler
   Password: p?cS1B3f

3. Download the ERiC package for Linux:
   - Look for: ERiC-XX.X.X.X-Linux-x86_64.jar
   - For 2025 tax year: ERiC 43.x or higher is required

4. Once downloaded, run:
   viking fetch --file=/path/to/downloaded/ERiC-XX.X.X.X-Linux-x86_64.jar

The fetch command will:
- Extract the archive to: {cacheDir}
- Download test certificates automatically
- Update your .env file with the correct paths

Required Libraries:
------------------
- libericapi.so     (main API library)
- libericxerces.so  (XML processing)
- libeSigner.so     (signing/encryption)
- plugins2/         (validation plugins)

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
        let yearStr = name[14..^4]  # Extract year from libcheckUStVA_YYYY.so
        try:
          let year = parseInt(yearStr)
          result.add(year)
        except ValueError:
          discard

  result.sort()

# ===========================================================================
# Auto-download orchestrator
# ===========================================================================

proc fetchEric*(): tuple[installation: EricInstallation, success: bool] =
  ## Auto-download ERiC from ELSTER developer portal
  echo "=== ERiC Library ==="
  echo "Attempting automatic download from ELSTER developer portal..."
  echo ""

  let cacheDir = getEricCacheDir()
  createDir(cacheDir)

  var downloads: seq[EricDownload] = @[]
  var pc: PortalClient
  var loggedIn = false

  # Step 1: Try portal login + scrape download page
  try:
    echo "  Logging into developer portal..."
    pc = loginDeveloperPortal()
    loggedIn = true
    echo "  Login successful."
    echo "  Discovering available versions..."
    downloads = discoverEricDownloads(pc)
    if downloads.len > 0:
      echo &"  Found {downloads.len} version(s):"
      for dl in downloads:
        echo &"    - {dl.filename} (v{dl.version})"
  except:
    echo &"  Portal access failed: {getCurrentExceptionMsg()}"

  # Step 2: Fallback - try direct discovery via directory listing
  if downloads.len == 0:
    echo "  Trying direct download discovery..."
    downloads = tryDirectDiscovery()
    if downloads.len > 0:
      echo &"  Found {downloads.len} version(s) via direct listing."

  # Step 3: Give up if nothing found
  if downloads.len == 0:
    echo ""
    echo "Could not find ERiC download automatically."
    echo "Please download manually and use: viking fetch --file=<path>"
    echo ""
    printDownloadInstructions()
    return (EricInstallation(valid: false), false)

  # Step 4: Download the latest version
  let latest = downloads[^1]
  let archivePath = cacheDir / latest.filename

  if fileExists(archivePath):
    echo &"  Archive already cached: {archivePath}"
  else:
    echo &"  Downloading {latest.filename}..."
    try:
      if loggedIn:
        pc.portalDownload(latest.url, archivePath)
      else:
        let client = newHttpClient()
        defer: client.close()
        client.downloadFile(latest.url, archivePath)
      echo &"  Saved to {archivePath}"
    except:
      echo &"  Download failed: {getCurrentExceptionMsg()}"
      return (EricInstallation(valid: false), false)

  if loggedIn:
    pc.close()

  # Step 5: Extract and verify
  echo ""
  let installation = setupEric(archivePath)
  return (installation, installation.valid)

when isMainModule:
  # Standalone testing
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
