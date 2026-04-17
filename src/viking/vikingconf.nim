## viking.conf parser
## Reserved sections: [personal], [spouse]. All other sections are inferred
## by their fields: has `income` -> income source; has `kindschaftsverhaeltnis`
## -> kid; neither/both -> error.

import std/[parsecfg, streams, strutils, os, tables]
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
    firstname*: string   ## from section name
    birthdate*, idnr*: string
    kindschaftsverhaeltnis*: string  ## default "1" (leibliches Kind)
    kindergeld*: float

  SourceKind* = enum
    skGewerbe    ## income = 2  (Anlage G)
    skFreelance  ## income = 3  (Anlage S)
    skKap        ## income = kap (Anlage KAP)

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

  VikingConf* = object
    personal*: Personal
    spouse*: Spouse
    kids*: seq[Kid]
    sources*: seq[Source]

const SourceOnlyFields = [
  "taxnumber", "rechtsform", "besteuerungsart", "vorauszahlungen",
  "gains", "tax", "soli", "kirchensteuer",
  "sparer_pauschbetrag", "sparerpauschbetrag", "guenstigerpruefung"
]

func defaultPersonal(): Personal =
  result.religion = "11"
  result.kvArt = "privat"

func parseBool(val: string): bool =
  let v = val.strip.toLowerAscii
  v == "1" or v == "true" or v == "yes"

proc applyPersonal(p: var Personal, key, val: string) =
  case key
  of "firstname": p.firstname = val
  of "lastname": p.lastname = val
  of "birthdate": p.birthdate = val
  of "idnr": p.idnr = val
  of "taxnumber": p.taxnumber = val
  of "street": p.street = val
  of "housenumber": p.housenumber = val
  of "zip": p.zip = val
  of "city": p.city = val
  of "iban": p.iban = val
  of "religion": p.religion = religionMap.resolve(val)
  of "profession": p.profession = val
  of "kv_art", "kvart": p.kvArt = val
  else: discard

proc applySpouse(s: var Spouse, key, val: string) =
  case key
  of "firstname": s.firstname = val
  of "lastname": s.lastname = val
  of "birthdate": s.birthdate = val
  of "idnr": s.idnr = val
  of "taxnumber": s.taxnumber = val
  of "street": s.street = val
  of "housenumber": s.housenumber = val
  of "zip": s.zip = val
  of "city": s.city = val
  of "religion": s.religion = religionMap.resolve(val)
  of "profession": s.profession = val
  of "kv_art", "kvart": s.kvArt = val
  else: discard

proc applyKid(k: var Kid, key, val: string) =
  case key
  of "birthdate": k.birthdate = val
  of "idnr": k.idnr = val
  of "kindschaftsverhaeltnis":
    k.kindschaftsverhaeltnis = kindschaftsverhaeltnisMap.resolve(val)
  of "kindergeld":
    try: k.kindergeld = parseFloat(val)
    except ValueError: discard
  else: discard

proc applySource(s: var Source, key, val: string) =
  case key
  of "taxnumber": s.taxnumber = val
  of "rechtsform": s.rechtsform = rechtsformMap.resolve(val)
  of "besteuerungsart": s.besteuerungsart = besteuerungsartMap.resolve(val)
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
  of "sparer_pauschbetrag", "sparerpauschbetrag":
    try: s.sparerPauschbetrag = parseFloat(val)
    except ValueError: discard
  of "guenstigerpruefung":
    s.guenstigerpruefung = parseBool(val)
  else: discard

type
  RawSection = object
    name: string
    keys: OrderedTable[string, string]

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
      current = RawSection(name: event.section.toLowerAscii,
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

proc classifyAndApply(conf: var VikingConf, sec: RawSection) =
  ## Handle one raw section, dispatching by name or inferring from fields.
  case sec.name
  of "personal":
    for k, v in sec.keys: applyPersonal(conf.personal, k, v)
  of "spouse":
    conf.spouse.present = true
    for k, v in sec.keys: applySpouse(conf.spouse, k, v)
  else:
    let hasIncome = "income" in sec.keys
    let hasKindschaft = "kindschaftsverhaeltnis" in sec.keys
    if hasIncome and hasKindschaft:
      raise newException(ValueError,
        "section [" & sec.name & "]: has both 'income' and 'kindschaftsverhaeltnis'; must be one or the other")
    if hasIncome:
      var src = Source(name: sec.name, owner: "personal")
      let incomeVal = incomeMap.resolve(sec.keys.getOrDefault("income"))
      case incomeVal
      of "2": src.kind = skGewerbe
      of "3": src.kind = skFreelance
      of "kap": src.kind = skKap
      else: discard
      for k, v in sec.keys:
        if k != "income": applySource(src, k, v)
      conf.sources.add(src)
    elif hasKindschaft:
      var kid = Kid(firstname: sec.name, kindschaftsverhaeltnis: "1")
      for k, v in sec.keys: applyKid(kid, k, v)
      conf.kids.add(kid)
    else:
      # Check for source-only fields without income to catch typos
      for f in SourceOnlyFields:
        if f in sec.keys:
          raise newException(ValueError,
            "section [" & sec.name & "]: has '" & f & "' but no 'income'")
      raise newException(ValueError,
        "section [" & sec.name & "]: unclassified; needs 'income' (source) or 'kindschaftsverhaeltnis' (kid)")

proc mergeSection(conf: var VikingConf, sec: RawSection) =
  ## Apply a section to an existing conf, overriding per-field.
  case sec.name
  of "personal":
    for k, v in sec.keys: applyPersonal(conf.personal, k, v)
  of "spouse":
    conf.spouse.present = true
    for k, v in sec.keys: applySpouse(conf.spouse, k, v)
  else:
    # Check if source with this name already exists
    var idx = -1
    for i, s in conf.sources:
      if s.name == sec.name:
        idx = i
        break
    if idx >= 0:
      for k, v in sec.keys:
        if k != "income": applySource(conf.sources[idx], k, v)
      if "income" in sec.keys:
        case incomeMap.resolve(sec.keys["income"])
        of "2": conf.sources[idx].kind = skGewerbe
        of "3": conf.sources[idx].kind = skFreelance
        of "kap": conf.sources[idx].kind = skKap
        else: discard
      return
    var kidIdx = -1
    for i, k in conf.kids:
      if k.firstname == sec.name:
        kidIdx = i
        break
    if kidIdx >= 0:
      for k, v in sec.keys: applyKid(conf.kids[kidIdx], k, v)
      return
    classifyAndApply(conf, sec)

proc loadSingleFile(path: string): VikingConf =
  result.personal = defaultPersonal()
  for sec in readSections(path):
    classifyAndApply(result, sec)

proc mergeFile(conf: var VikingConf, path: string) =
  for sec in readSections(path):
    mergeSection(conf, sec)

proc globalConfPath*(): string =
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
  for kid in conf.kids: result.add(kid.firstname)

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
