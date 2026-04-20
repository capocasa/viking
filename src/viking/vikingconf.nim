## viking.conf parser, validator, and auth resolver.
##
## Sections are classified by name and by key markers (no `income =` needed):
##
## * first non-reserved section (or one whose name matches an already-set
##   personal name) → `Personal` (the taxpayer); section name = Vornamen
##   Nachname (last word = Nachname, rest = Vornamen).
## * `[auth]`                        → signing material (reserved)
## * `[freiberuf]`                   → Anlage S source (rechtsform freiberuf)
## * `[gewerbe]`                     → Anlage G Einzelgewerbe
## * has `verhaeltnis` key           → `Kid`; section name = full name
## * has `guenstigerpruefung`/`pauschbetrag` key → Anlage KAP source
## * section name ends with a Rechtsform suffix (GmbH, UG, KG, OHG, GbR,
##   PartG, eK, eG, KGaA, SE, GmbH & Co. KG, …) → Anlage G with that
##   Rechtsform. No suffix → Einzelgewerbe.
## * any remaining section with an `idnr` key → `Spouse` (triggers
##   Zusammenveranlagung); section name = spouse's full name.
##
## `loadVikingConf` merges the global and CWD confs (or honours an explicit
## `--conf` path); `validateForX` returns a `seq[string]` of human-readable
## errors per command. `resolveCertPath` / `resolvePinPath` / `readPin`
## locate signing material per the rules described in the user docs.

import std/[parsecfg, streams, strutils, os, osproc, tables]
import viking/codes

type
  Personal* = object
    firstname*, lastname*, birthdate*, idnr*, taxnumber*: string
    street*, housenumber*, zip*, city*, iban*: string
    religion*, profession*, kvArt*: string

  Spouse* = object
    present*: bool
    firstname*, lastname*, birthdate*, idnr*, taxnumber*: string
    street*, housenumber*, zip*, city*: string
    religion*, profession*, kvArt*: string

  Kid* = object
    firstname*, lastname*: string    ## from section name (last word = last)
    birthdate*, idnr*: string
    kindschaftsverhaeltnis*: string  ## Person A; default "1" (leibliches Kind)
    kindschaftsverhaeltnisB*: string ## Person B; unset = don't emit K_Verh_B
    parentBName*: string             ## Other parent name, Einzelveranlagung only
                                     ## (E0501103 in K_Verh_and_P/Ang_Pers)
    familienkasse*: string           ## Anlage Kind line 6/7, E0500706
    kindergeld*: float

  SourceKind* = enum
    skGewerbe    ## Anlage G (Gewerbebetrieb)
    skFreelance  ## Anlage S (Selbstaendige Arbeit)
    skKap        ## Anlage KAP

  Source* = object
    name*: string              ## from section name
    kind*: SourceKind
    owner*: string             ## "personal" or "spouse"
    taxnumber*: string         ## override; empty = inherit owner's
    rechtsform*: string
    besteuerungsart*: string
    vorauszahlungen*: float    ## EÜR sources only
    ## KAP-only:
    gains*, tax*, soli*, kirchensteuer*, sparerPauschbetrag*: float
    guenstigerpruefung*: bool

  Auth* = object
    ## Raw [auth] values from the conf; paths not yet resolved.
    cert*: string    ## optional cert path, absolute or relative to confDir
    pin*: string     ## optional plaintext pin file path
    pincmd*: string  ## optional executable pin-command file path

  VikingConf* = object
    personal*: Personal
    spouse*: Spouse
    kids*: seq[Kid]
    sources*: seq[Source]
    auth*: Auth
    confDir*: string           ## dir of the last loaded conf (for default resolution)
    confBase*: string          ## basename (no extension) of the last loaded conf

func defaultPersonal(): Personal =
  result.religion = "11"
  result.kvArt = "privat"

func parseBool(val: string): bool =
  let v = val.strip.toLowerAscii
  v == "1" or v == "true" or v == "yes"

func parseFullName(name: string): tuple[firstname, lastname: string] =
  ## "Hans Maier" → ("Hans", "Maier"). "Hans Peter Maier" → ("Hans Peter", "Maier").
  let words = name.strip.splitWhitespace
  if words.len == 0: return ("", "")
  if words.len == 1: return (words[0], "")
  result.firstname = words[0 .. ^2].join(" ")
  result.lastname = words[^1]

func rechtsformFromName(name: string): string =
  ## Numeric rechtsform code from a trailing legal-form suffix in the section
  ## name. "" = no suffix recognised (caller defaults to Einzelgewerbe / 120).
  let words = name.strip.splitWhitespace
  if words.len == 0: return ""
  if words.len >= 4:
    let last4 = words[^4 .. ^1].join(" ").toLowerAscii
    case last4
    of "gmbh & co. kg":  return "230"
    of "gmbh & co. ohg": return "240"
    of "ag & co. kg":    return "250"
    of "ag & co. ohg":   return "260"
    else: discard
  case words[^1].toLowerAscii
  of "kgaa":  "320"
  of "gmbh":  "350"
  of "partg": "140"
  of "ohg":   "210"
  of "gbr":   "270"
  of "kg":    "220"
  of "ag":    "310"
  of "ug":    "370"
  of "se":    "360"
  of "eg":    "490"
  of "ek":    "120"
  else:       ""

proc applyPersonal(p: var Personal, key, val: string) =
  case key
  of "geburtsdatum", "birthdate":       p.birthdate = val
  of "idnr":                            p.idnr = val
  of "steuernr", "steuernummer", "taxnumber":
                                        p.taxnumber = val
  of "strasse", "street":               p.street = val
  of "nr", "hausnummer", "housenumber": p.housenumber = val
  of "plz", "zip":                      p.zip = val
  of "ort", "city":                     p.city = val
  of "iban":                            p.iban = val
  of "religion":                        p.religion = religionMap.resolve(val)
  of "beruf", "profession":             p.profession = val
  of "krankenkasse", "kv_art", "kvart": p.kvArt = val
  else: discard

proc applySpouse(s: var Spouse, key, val: string) =
  case key
  of "geburtsdatum", "birthdate":       s.birthdate = val
  of "idnr":                            s.idnr = val
  of "steuernr", "steuernummer", "taxnumber":
                                        s.taxnumber = val
  of "strasse", "street":               s.street = val
  of "nr", "hausnummer", "housenumber": s.housenumber = val
  of "plz", "zip":                      s.zip = val
  of "ort", "city":                     s.city = val
  of "religion":                        s.religion = religionMap.resolve(val)
  of "beruf", "profession":             s.profession = val
  of "krankenkasse", "kv_art", "kvart": s.kvArt = val
  else: discard

proc applyKid(k: var Kid, key, val: string) =
  case key
  of "geburtsdatum", "birthdate": k.birthdate = val
  of "idnr":                      k.idnr = val
  of "verhaeltnis", "kindschaftsverhaeltnis":
    k.kindschaftsverhaeltnis = kindschaftsverhaeltnisMap.resolve(val)
  of "personb-verhaeltnis", "personbverhaeltnis",
     "kindschaftsverhaeltnis_b", "kindschaftsverhaeltnisb":
    k.kindschaftsverhaeltnisB = kindschaftsverhaeltnisMap.resolve(val)
  of "personb-name", "personbname", "parent_b_name", "parentbname":
    k.parentBName = val
  of "familienkasse": k.familienkasse = val
  of "kindergeld":
    try: k.kindergeld = parseFloat(val)
    except ValueError: discard
  else: discard

proc applyAuth(a: var Auth, key, val: string) =
  case key
  of "cert": a.cert = val
  of "pin": a.pin = val
  of "pincmd": a.pincmd = val
  else: discard

proc applySource(s: var Source, key, val: string) =
  case key
  of "steuernr", "steuernummer", "taxnumber": s.taxnumber = val
  of "rechtsform": s.rechtsform = rechtsformMap.resolve(val)
  of "versteuerung", "besteuerungsart":
    s.besteuerungsart = besteuerungsartMap.resolve(val)
  of "owner": s.owner = val.toLowerAscii
  of "vorauszahlungen":
    try: s.vorauszahlungen = parseFloat(val)
    except ValueError: discard
  of "gains":
    try: s.gains = parseFloat(val)
    except ValueError: discard
  of "tax":
    try: s.tax = parseFloat(val)
    except ValueError: discard
  of "soli":
    try: s.soli = parseFloat(val)
    except ValueError: discard
  of "kirchensteuer":
    try: s.kirchensteuer = parseFloat(val)
    except ValueError: discard
  of "pauschbetrag", "sparer_pauschbetrag", "sparerpauschbetrag":
    try: s.sparerPauschbetrag = parseFloat(val)
    except ValueError: discard
  of "guenstigerpruefung":
    s.guenstigerpruefung = parseBool(val)
  else: discard

type
  RawSection = object
    rawName: string
    name: string
    keys: OrderedTable[string, string]

  SectionKind = enum
    sPersonal, sSpouse, sAuth, sKid, sFreelance, sGewerbe, sKap, sCompany

proc readSections(path: string): seq[RawSection] =
  ## Parse the INI into raw sections preserving key order and duplicates of [<name>].
  ## Each distinct section occurrence is a separate RawSection; callers merge.
  let stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(IOError, "Cannot open config file: " & path)
  defer: stream.close()

  var parser: CfgParser
  open(parser, stream, path)
  defer: close(parser)

  var current: RawSection
  var inSection = false
  while true:
    let event = parser.next()
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      if inSection:
        result.add(current)
      current = RawSection(rawName: event.section,
                           name: event.section.toLowerAscii,
                           keys: initOrderedTable[string, string]())
      inSection = true
    of cfgKeyValuePair:
      if inSection:
        current.keys[event.key.toLowerAscii] = event.value
    of cfgOption:
      discard
    of cfgError:
      raise newException(ValueError, "Config parse error: " & event.msg)
  if inSection:
    result.add(current)

proc classify(sec: RawSection, conf: VikingConf): SectionKind =
  case sec.name
  of "auth":      return sAuth
  of "freiberuf": return sFreelance
  of "gewerbe":   return sGewerbe
  else: discard
  if "verhaeltnis" in sec.keys or "kindschaftsverhaeltnis" in sec.keys:
    return sKid
  if "guenstigerpruefung" in sec.keys or
     "pauschbetrag" in sec.keys or
     "sparer_pauschbetrag" in sec.keys:
    return sKap
  if rechtsformFromName(sec.rawName) != "":
    return sCompany
  if conf.personal.lastname == "" and conf.personal.firstname == "":
    return sPersonal
  let fullName = (conf.personal.firstname & " " & conf.personal.lastname).strip
  if fullName.toLowerAscii == sec.name:
    return sPersonal
  # A later person-named section with an IdNr is the co-filing spouse
  # (Zusammenveranlagung). An IdNr is only issued to natural persons, so
  # companies/sources never carry one.
  if "idnr" in sec.keys:
    return sSpouse
  sCompany  # fallback: Einzelgewerbe named after owner

proc applyPersonalSection(conf: var VikingConf, sec: RawSection) =
  if conf.personal.lastname == "":
    let (fn, ln) = parseFullName(sec.rawName)
    conf.personal.firstname = fn
    conf.personal.lastname = ln
  for k, v in sec.keys: applyPersonal(conf.personal, k, v)

proc applySpouseSection(conf: var VikingConf, sec: RawSection) =
  conf.spouse.present = true
  if conf.spouse.lastname == "":
    let (fn, ln) = parseFullName(sec.rawName)
    conf.spouse.firstname = fn
    conf.spouse.lastname = ln
  for k, v in sec.keys: applySpouse(conf.spouse, k, v)

proc applyKidSection(conf: var VikingConf, sec: RawSection) =
  let (fn, ln) = parseFullName(sec.rawName)
  var kidIdx = -1
  for i, k in conf.kids:
    if k.firstname == fn and k.lastname == ln:
      kidIdx = i
      break
  if kidIdx < 0:
    var kid = Kid(firstname: fn, lastname: ln, kindschaftsverhaeltnis: "1")
    for k, v in sec.keys: applyKid(kid, k, v)
    conf.kids.add(kid)
  else:
    for k, v in sec.keys: applyKid(conf.kids[kidIdx], k, v)

proc applySourceSection(conf: var VikingConf, sec: RawSection, kind: SourceKind,
                        name: string, defaultRechtsform: string) =
  var idx = -1
  for i, s in conf.sources:
    if s.name == name:
      idx = i
      break
  if idx < 0:
    var src = Source(name: name, kind: kind, owner: "personal",
                     rechtsform: defaultRechtsform)
    for k, v in sec.keys: applySource(src, k, v)
    conf.sources.add(src)
  else:
    conf.sources[idx].kind = kind
    if conf.sources[idx].rechtsform == "":
      conf.sources[idx].rechtsform = defaultRechtsform
    for k, v in sec.keys: applySource(conf.sources[idx], k, v)

proc applySection(conf: var VikingConf, sec: RawSection) =
  case classify(sec, conf)
  of sAuth:
    for k, v in sec.keys: applyAuth(conf.auth, k, v)
  of sPersonal:
    applyPersonalSection(conf, sec)
  of sSpouse:
    applySpouseSection(conf, sec)
  of sKid:
    applyKidSection(conf, sec)
  of sFreelance:
    applySourceSection(conf, sec, skFreelance, sec.name, "140")
  of sGewerbe:
    applySourceSection(conf, sec, skGewerbe, sec.name, "120")
  of sKap:
    applySourceSection(conf, sec, skKap, sec.rawName, "")
  of sCompany:
    let rf = rechtsformFromName(sec.rawName)
    let code = if rf != "": rf else: "120"
    applySourceSection(conf, sec, skGewerbe, sec.rawName, code)

proc loadSingleFile(path: string): VikingConf =
  result.personal = defaultPersonal()
  result.confDir = path.parentDir
  result.confBase = path.extractFilename.changeFileExt("")
  for sec in readSections(path):
    applySection(result, sec)

proc mergeFile(conf: var VikingConf, path: string) =
  conf.confDir = path.parentDir
  conf.confBase = path.extractFilename.changeFileExt("")
  for sec in readSections(path):
    applySection(conf, sec)

proc globalConfPath*(): string =
  ## XDG-aware path of the global conf
  ## (`$XDG_CONFIG_HOME/viking/viking.conf`, falling back to
  ## `~/.config/viking/viking.conf`).
  let xdg = getEnv("XDG_CONFIG_HOME")
  let base = if xdg != "": xdg else: getHomeDir() / ".config"
  base / "viking" / "viking.conf"

proc findConfPaths*(explicit: string): seq[string] =
  ## Return the ordered list of conf files to load (global first, CWD last).
  ## If `explicit` is non-empty, it wins and no others are consulted.
  if explicit != "":
    if not fileExists(explicit):
      raise newException(IOError, "Config file not found: " & explicit)
    return @[explicit]
  let global = globalConfPath()
  let cwd = getCurrentDir() / "viking.conf"
  if fileExists(global): result.add(global)
  if fileExists(cwd): result.add(cwd)

proc loadVikingConf*(explicit: string = ""): VikingConf =
  ## Load and merge viking.conf files per the search chain.
  ## CWD overrides values in global.
  let paths = findConfPaths(explicit)
  if paths.len == 0:
    raise newException(IOError,
      "No viking.conf found (tried ./viking.conf and " & globalConfPath() & ")")
  result = loadSingleFile(paths[0])
  for i in 1 ..< paths.len:
    mergeFile(result, paths[i])

## ---- Auth resolution ----

const PinExtensions* = [".pin", ".pin.sh", ".pin.ps1", ".pin.cmd", ".pin.bat", ".pin.exe"]

proc resolveRelative(conf: VikingConf, path: string): string =
  ## Absolute paths stay as-is; relative paths resolve against the conf dir.
  if path.isAbsolute: path
  else: conf.confDir / path

proc resolveCertPath*(conf: VikingConf): string =
  ## Cert path: [auth].cert, else <confBase>.pfx next to the conf.
  let raw = if conf.auth.cert != "": conf.auth.cert
            else: conf.confBase & ".pfx"
  conf.resolveRelative(raw)

proc resolvePinPath*(conf: VikingConf): string =
  ## Explicit pin/pincmd win. Otherwise scan <confBase>.pin{,.sh,.ps1,.cmd,.bat,.exe}
  ## next to the conf. Exactly one must exist; zero or >1 is an error.
  if conf.auth.pin != "" and conf.auth.pincmd != "":
    raise newException(ValueError,
      "[auth]: set pin or pincmd, not both")
  if conf.auth.pin != "":
    return conf.resolveRelative(conf.auth.pin)
  if conf.auth.pincmd != "":
    return conf.resolveRelative(conf.auth.pincmd)
  var found: seq[string]
  for ext in PinExtensions:
    let p = conf.confDir / (conf.confBase & ext)
    if fileExists(p):
      found.add(p)
  if found.len == 0:
    raise newException(IOError,
      "no pin file found next to " & (conf.confDir / conf.confBase) &
      "; expected one of " & PinExtensions.join(", ") &
      ", or set [auth] pin=/pincmd= in viking.conf")
  if found.len > 1:
    raise newException(ValueError,
      "multiple pin files found: " & found.join(", ") &
      "; set [auth] pin= or pincmd= explicitly")
  found[0]

proc readPin*(path: string): string =
  ## Read the pin by dispatching on file extension. Plain `.pin` is read;
  ## `.pin.sh`/`.ps1`/`.cmd`/`.bat`/`.exe` are executed, stdout is the pin.
  let name = path.toLowerAscii
  type Mode = enum mPlain, mSh, mPs1, mCmdBat, mExe
  let mode =
    if name.endsWith(".pin.sh"): mSh
    elif name.endsWith(".pin.ps1"): mPs1
    elif name.endsWith(".pin.cmd") or name.endsWith(".pin.bat"): mCmdBat
    elif name.endsWith(".pin.exe"): mExe
    elif name.endsWith(".pin"): mPlain
    else:
      raise newException(ValueError, "unsupported pin file extension: " & path)
  case mode
  of mPlain:
    result = readFile(path).strip
  of mSh:
    let (output, rc) = execCmdEx("sh " & path.quoteShell)
    if rc != 0:
      raise newException(IOError, "pin command failed (exit " & $rc & "): " & output)
    result = output.strip
  of mPs1:
    let (output, rc) = execCmdEx("powershell -NoProfile -File " & path.quoteShell)
    if rc != 0:
      raise newException(IOError, "pin command failed (exit " & $rc & "): " & output)
    result = output.strip
  of mCmdBat:
    let (output, rc) = execCmdEx("cmd /c " & path.quoteShell)
    if rc != 0:
      raise newException(IOError, "pin command failed (exit " & $rc & "): " & output)
    result = output.strip
  of mExe:
    let (output, rc) = execCmdEx(path.quoteShell)
    if rc != 0:
      raise newException(IOError, "pin command failed (exit " & $rc & "): " & output)
    result = output.strip

## ---- Accessors ----

func effectiveTaxnumber*(conf: VikingConf, src: Source): string =
  ## Source's taxnumber if set, else its owner's.
  if src.taxnumber != "": return src.taxnumber
  if src.owner == "spouse": conf.spouse.taxnumber
  else: conf.personal.taxnumber

func findSource*(conf: VikingConf, name: string): int =
  ## -1 if not found.
  for i, s in conf.sources:
    if s.name == name: return i
  -1

func getSource*(conf: VikingConf, name: string): Source =
  let i = conf.findSource(name)
  if i < 0:
    raise newException(ValueError, "source not defined in viking.conf: " & name)
  conf.sources[i]

func sourcesOfKind*(conf: VikingConf, kinds: set[SourceKind]): seq[Source] =
  for s in conf.sources:
    if s.kind in kinds: result.add(s)

func euerSources*(conf: VikingConf): seq[Source] =
  conf.sourcesOfKind({skGewerbe, skFreelance})

func kapSources*(conf: VikingConf): seq[Source] =
  conf.sourcesOfKind({skKap})

func kidFirstnames*(conf: VikingConf): seq[string] =
  ## First given word (lowercased) of each kid — used as deduction prefix.
  for kid in conf.kids:
    let words = kid.firstname.splitWhitespace
    if words.len > 0: result.add(words[0].toLowerAscii)

## ---- Validation ----

func isNotEmpty(x: string): bool = x.strip.len > 0

proc checkPersonal(p: Personal, required: openArray[string]): seq[string] =
  for f in required:
    let v = case f
      of "firstname": p.firstname
      of "lastname": p.lastname
      of "birthdate": p.birthdate
      of "idnr": p.idnr
      of "taxnumber": p.taxnumber
      of "street": p.street
      of "housenumber": p.housenumber
      of "zip": p.zip
      of "city": p.city
      of "iban": p.iban
      else: ""
    if not v.isNotEmpty:
      result.add("personal." & f & " not set in viking.conf")
    elif f == "taxnumber" and v.len != 13:
      result.add("personal.taxnumber must be 13 digits, got " & $v.len)

proc checkSource(conf: VikingConf, src: Source, required: openArray[string]): seq[string] =
  for f in required:
    let v = case f
      of "taxnumber": conf.effectiveTaxnumber(src)
      of "rechtsform": src.rechtsform
      of "besteuerungsart": src.besteuerungsart
      else: ""
    if not v.isNotEmpty:
      var msg = "source [" & src.name & "]." & f & " not set"
      case f
      of "rechtsform": msg &= "; " & rechtsformMap.listing
      of "besteuerungsart": msg &= "; " & besteuerungsartMap.listing
      else: discard
      result.add(msg)
    elif f == "taxnumber" and v.len != 13:
      result.add("source [" & src.name & "].taxnumber must be 13 digits, got " & $v.len)

func validateForEst*(conf: VikingConf): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "birthdate", "taxnumber", "iban"])
  if conf.personal.kvArt notin ["privat", "gesetzlich"]:
    result.add("personal.kv_art must be 'privat' or 'gesetzlich'")
  for src in conf.euerSources:
    result.add(checkSource(conf, src, ["taxnumber", "rechtsform"]))

func validateForUstva*(conf: VikingConf, src: Source): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "street", "zip", "city"])
  result.add(checkSource(conf, src, ["taxnumber"]))

func validateForUst*(conf: VikingConf, src: Source): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "street", "zip", "city"])
  result.add(checkSource(conf, src, ["taxnumber", "besteuerungsart"]))

func validateForEuer*(conf: VikingConf, src: Source): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "street", "zip", "city"])
  result.add(checkSource(conf, src, ["taxnumber", "rechtsform"]))

func validateForNachricht*(conf: VikingConf): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "taxnumber", "street", "housenumber", "zip", "city"])

func validateForBankverbindung*(conf: VikingConf): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "birthdate", "idnr", "taxnumber"])

func validateForAbholung*(conf: VikingConf): seq[string] =
  result = checkPersonal(conf.personal, ["firstname", "lastname"])
