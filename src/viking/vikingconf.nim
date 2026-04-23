## viking.conf parser, validator, and auth resolver.
##
## Sections have fixed names; duplicates are permitted (parsecfg loop
## mode). Entities are distinguished by the `name` key and — for
## income sources — by the `typ` key:
##
## * `[steuerzahler]`  — first occurrence is the taxpayer (`Personal`);
##                       a later occurrence with a different `name` is
##                       the co-filing spouse (triggers Zusammen-
##                       veranlagung). `name = Vornamen Nachname`
##                       (last word = Nachname, rest = Vornamen).
## * `[kind]`          — one per child. `name = full name` (first word
##                       lowercased becomes the abzuege prefix).
## * `[einkommen]`     — one per income source, classified via `typ=`:
##                         `typ = freiberuflich` → Anlage S
##                         `typ = gewerbe`       → Anlage G
##                         `typ = kapital`       → Anlage KAP
##                         `typ = rente`         → Anlage R
##                       For `gewerbe`, the section's `name=` may be a
##                       company name; the Rechtsform is inferred from
##                       a trailing legal-form suffix (GmbH, UG, KG,
##                       OHG, GbR, PartG, eK, eG, KGaA, SE, AG,
##                       "GmbH & Co. KG", …). No suffix → Einzelgewerbe.
## * `[auth]`          — signing material.
##
## `loadVikingConf` merges the global and CWD confs (or honours an
## explicit `--conf` path); `validateForX` returns a `seq[string]` of
## human-readable errors per command.
##
## All external-file wiring is explicit — there is no filesystem magic:
##
## * `resolveCertPath` reads `[auth].cert` (path to the .pfx; required).
## * `resolvePin`      resolves exactly one of `[auth].pin` or `[auth].pincmd`.
##   `pin=` is either a path to a plaintext PIN file or the PIN text
##   itself (dispatched via `fileExists` — if the resolved path exists,
##   read; else treat the value as the inline PIN). `pincmd=` is a shell
##   command executed with `confDir` as cwd; stdout is the PIN.
## * `resolveEuerPath` reads the EÜR source's `euer=` key (TSV of
##   income + costs). Optional — unset sources submit zeros with a
##   warning. Presence of the key also marks the source as using
##   Einnahmen-Überschuss accounting (a different key will mark full
##   double-entry once that lands).
## * `resolveDeductionsPath` reads `steuerzahler.abzuege` (TSV path;
##   optional). ESt warns when both the conf key and `--deductions`
##   are absent unless `--force` is passed.
## * `resolveRentePath` reads the rente source's `rente=` key
##   (Anlage R TSV; one row per Rente/Leistung).
##
## Relative paths in all these resolve against the conf's own directory.

import std/[parsecfg, streams, strutils, strformat, os, osproc, sets, tables]
import viking/codes

type
  Personal* = object
    firstname*, lastname*, birthdate*, idnr*, taxnumber*: string
    street*, housenumber*, zip*, city*, iban*: string
    religion*, profession*, kvArt*: string
    year*: int                       ## tax year the conf describes.
                                     ## Required — there's no CLI
                                     ## override; copy the conf dir
                                     ## per year.
    deductions*: string              ## optional TSV path for ESt deductions
                                     ## (vor/sa/agb/per-kid codes). Relative
                                     ## to confDir.
    alleinerziehend*: bool           ## §24b Entlastungsbetrag für
                                     ## Alleinerziehende. Einzelveranlagung
                                     ## only; requires at least one kid
                                     ## with haushalt=a.

  Spouse* = object
    present*: bool
    firstname*, lastname*, birthdate*, idnr*, taxnumber*: string
    street*, housenumber*, zip*, city*: string
    religion*, profession*, kvArt*: string

  Kid* = object
    firstname*, lastname*: string    ## from the section's `name=` key
                                     ## (last word = last, rest = first)
    birthdate*, idnr*: string
    kindschaftsverhaeltnis*: string  ## Person A; default "1" (leibliches Kind)
    kindschaftsverhaeltnisB*: string ## Person B; unset = don't emit K_Verh_B
    parentBName*: string             ## Other parent name, Einzelveranlagung only
                                     ## (E0501103 in K_Verh_and_P/Ang_Pers)
    familienkasse*: string           ## Anlage Kind line 6/7, E0500706
    kindergeld*: float
    verhaeltnisVon*: string          ## Kindschaftsverhältnis start (DD.MM).
                                     ## Default: DD.MM of birthdate if birth
                                     ## year == tax year, else 01.01.
    verhaeltnisBis*: string          ## Kindschaftsverhältnis end (DD.MM);
                                     ## default 31.12.
    wohnsitzVon*, wohnsitzBis*: string
                                     ## Wohnsitz im Inland (DD.MM); default
                                     ## follows verhaeltnisVon/verhaeltnisBis.
    haushalt*: string                ## Kinderbetreuungskosten Haushalt-marker:
                                     ## "a" (Person A), "b" (Person B), or
                                     ## "beide" (default for Zusammenveranlagung).
                                     ## Defaults: Zusammen -> "beide",
                                     ## Einzel -> "a".
    haushaltElternGetrennt*: string  ## Einzelveranlagung only: "1" if the
                                     ## child's parents live in separate
                                     ## households. Default: "1" under
                                     ## Einzelveranlagung, unset otherwise.

  SourceKind* = enum
    skGewerbe    ## Anlage G (Gewerbebetrieb)
    skFreelance  ## Anlage S (Selbstaendige Arbeit)
    skKap        ## Anlage KAP
    skRente      ## Anlage R (Renten / sonstige Leistungen)

  Source* = object
    name*: string              ## display / handle (from section's `name=`
                               ## key, or the `typ` value when no name is
                               ## given)
    kind*: SourceKind
    owner*: string             ## "personal" or "spouse"
    taxnumber*: string         ## override; empty = inherit owner's
    rechtsform*: string
    besteuerungsart*: string
    art*: string               ## Art des Betriebs (EÜR E6000017). Optional;
                               ## default "Dienstleistungen".
    vorauszahlungen*: float    ## EÜR sources only
    euer*: string              ## EÜR data TSV path (income and costs).
                               ## Optional — unset sources submit zeros
                               ## with a warning. Relative paths resolve
                               ## against the conf dir.
    rente*: string             ## Anlage R TSV path. Relative paths resolve
                               ## against the conf dir.
    ## KAP-only:
    gains*, tax*, soli*, kirchensteuer*, sparerPauschbetrag*: float
    auslaendischeQuellensteuer*: float   ## Z.41 anrechenbare ausl. Quellensteuer
    nichtAnrechenbarAqs*: float          ## Z.42 nicht anrechenbare ausl. Quellensteuer
    verlusteAktien*: float               ## Z.23 Verluste Aktienveräußerung
    verlusteSonstige*: float             ## Z.24 sonstige Verluste
    guenstigerpruefung*: bool
    steuerabzug*: bool                   ## KAP: true = gains went through
                                         ## inländischer Steuerabzug (KapESt
                                         ## withheld at source); false = no
                                         ## German withholding. Default: auto
                                         ## — true when tax/soli/kirchensteuer
                                         ## are set, else false.
    steuerabzugSet*: bool                ## whether `steuerabzug` was set
                                         ## explicitly in the conf (vs auto).
    auslaendisch*: bool                  ## KAP: foreign source (Zeile 19
                                         ## "Ausländische Kapitalerträge").
                                         ## Only consulted when the source
                                         ## has no Steuerabzug. Default false
                                         ## (inländisch, Zeile 18).

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

proc setFloat(dst: var float, val: string) =
  ## Parse `val` as float into `dst`. Silently ignores malformed input —
  ## config-key validation catches typos earlier, so a bad number just
  ## keeps the zero default.
  try: dst = parseFloat(val)
  except ValueError: discard

func normalizeDayMonth*(val: string): string =
  ## Accept DD.MM, DD.MM., or DD.MM.YYYY; return zero-padded DD.MM.
  ## Malformed input passes through untouched so ERiC surfaces the error.
  let parts = val.strip.split('.')
  if parts.len < 2: return val.strip
  let d = parts[0].strip
  let m = parts[1].strip
  if d.len == 0 or m.len == 0: return val.strip
  let dd = if d.len == 1: "0" & d else: d
  let mm = if m.len == 1: "0" & m else: m
  dd & "." & mm

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
  of "name":                            discard  ## handled by section dispatch
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
  of "abzuege":                         p.deductions = val
  of "alleinerziehend":                 p.alleinerziehend = parseBool(val)
  of "year", "jahr":
    try: p.year = parseInt(val.strip)
    except ValueError: discard
  else: discard

proc applySpouse(s: var Spouse, key, val: string) =
  case key
  of "name":                            discard
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
  of "name":                      discard
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
  of "kindergeld": setFloat(k.kindergeld, val)
  of "verhaeltnis_von", "verhaeltnisvon": k.verhaeltnisVon = normalizeDayMonth(val)
  of "verhaeltnis_bis", "verhaeltnisbis": k.verhaeltnisBis = normalizeDayMonth(val)
  of "wohnsitz_von", "wohnsitzvon":       k.wohnsitzVon = normalizeDayMonth(val)
  of "wohnsitz_bis", "wohnsitzbis":       k.wohnsitzBis = normalizeDayMonth(val)
  of "haushalt":                          k.haushalt = haushaltMap.resolve(val)
  of "haushalt_eltern_getrennt", "haushaltelterngetrennt":
    # Tri-state: "" (unset/default), "0" (explicit no), "1" (explicit
    # yes). Under Einzelveranlagung the default is "1" (separated), but
    # cohabiting unmarried parents need to override with `= 0`, so we
    # must preserve the distinction between "user said no" and "unset".
    k.haushaltElternGetrennt = (if parseBool(val): "1" else: "0")
  else: discard

proc applyAuth(a: var Auth, key, val: string) =
  case key
  of "cert": a.cert = val
  of "pin": a.pin = val
  of "pincmd": a.pincmd = val
  else: discard

proc applySource(s: var Source, key, val: string) =
  case key
  of "name", "typ":                                       discard
  of "steuernr", "steuernummer", "taxnumber":             s.taxnumber = val
  of "rechtsform":                                        s.rechtsform = rechtsformMap.resolve(val)
  of "versteuerung", "besteuerungsart":
    s.besteuerungsart = besteuerungsartMap.resolve(val)
  of "art":                                               s.art = val
  of "owner":                                             s.owner = val.toLowerAscii
  of "euer":                                              s.euer = val
  of "rente", "renten":                                   s.rente = val
  of "steuerabzug":
    let v = val.strip.toLowerAscii
    s.steuerabzugSet = true
    s.steuerabzug = not (v == "no" or v == "nein" or v == "0" or v == "false")
  of "ausland", "auslaendisch":                           s.auslaendisch = parseBool(val)
  of "vorauszahlungen":                                   setFloat(s.vorauszahlungen, val)
  of "gains":                                             setFloat(s.gains, val)
  of "tax":                                               setFloat(s.tax, val)
  of "soli":                                              setFloat(s.soli, val)
  of "kirchensteuer":                                     setFloat(s.kirchensteuer, val)
  of "pauschbetrag", "sparer_pauschbetrag",
     "sparerpauschbetrag":                                setFloat(s.sparerPauschbetrag, val)
  of "auslaendische_quellensteuer",
     "auslaendischequellensteuer", "aqs":                 setFloat(s.auslaendischeQuellensteuer, val)
  of "nicht_anrechenbar_aqs",
     "nichtanrechenbaraqs":                               setFloat(s.nichtAnrechenbarAqs, val)
  of "verluste_aktien", "verlusteaktien":                 setFloat(s.verlusteAktien, val)
  of "verluste_sonstige", "verlustesonstige":             setFloat(s.verlusteSonstige, val)
  of "guenstigerpruefung":                                s.guenstigerpruefung = parseBool(val)
  else: discard

type
  RawSection = object
    rawName: string
    name: string
    keys: OrderedTable[string, string]

  SectionKind = enum
    sPersonal, sSpouse, sAuth, sKid, sFreelance, sGewerbe, sKap, sRente

proc readSections(path: string): seq[RawSection] =
  ## Parse the INI via parsecfg's loop (`next()`) mode so duplicate
  ## `[section]` headers are preserved — each header-to-header span
  ## becomes its own `RawSection`.
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

func normalizeTyp(val: string): string =
  ## Fold known aliases into one of: "freiberuflich", "gewerbe",
  ## "kapital", "rente". Unknown values pass through so the caller can
  ## report them.
  case val.strip.toLowerAscii
  of "freiberuflich", "freiberuf", "freelance",
     "selbstaendig", "selbststaendig": "freiberuflich"
  of "gewerbe", "gewerbebetrieb", "einzelgewerbe": "gewerbe"
  of "kapital", "kap", "kapitalertrag", "kapitalertraege": "kapital"
  of "rente", "renten", "versorgung":              "rente"
  else:                                            val.strip.toLowerAscii

proc classifyEinkommen(sec: RawSection): tuple[kind: SourceKind, err: string] =
  let raw = sec.keys.getOrDefault("typ", "")
  let t = normalizeTyp(raw)
  case t
  of "freiberuflich": (skFreelance, "")
  of "gewerbe":       (skGewerbe,   "")
  of "kapital":       (skKap,       "")
  of "rente":         (skRente,     "")
  of "":
    (skGewerbe,
     "[einkommen]: `typ` key required " &
     "(expected: freiberuflich, gewerbe, kapital, rente)")
  else:
    (skGewerbe,
     "[einkommen]: unknown typ `" & raw.strip &
     "` (expected: freiberuflich, gewerbe, kapital, rente)")

proc classify(sec: RawSection, conf: VikingConf,
              errors: var seq[string]): tuple[kind: SectionKind, ok: bool] =
  case sec.name
  of "auth":         return (sAuth, true)
  of "steuerzahler":
    let sectionName = sec.keys.getOrDefault("name", "").strip
    if conf.personal.firstname == "" and conf.personal.lastname == "":
      return (sPersonal, true)
    let personalName = (conf.personal.firstname & " " &
                        conf.personal.lastname).strip
    if sectionName != "" and sectionName == personalName:
      return (sPersonal, true)
    if conf.spouse.present:
      let spouseName = (conf.spouse.firstname & " " &
                        conf.spouse.lastname).strip
      if sectionName != "" and sectionName == spouseName:
        return (sSpouse, true)
    return (sSpouse, true)
  of "kind":         return (sKid, true)
  of "einkommen":
    let (k, err) = classifyEinkommen(sec)
    if err != "":
      errors.add(err)
      return (sGewerbe, false)
    let srcKind = case k
      of skFreelance: sFreelance
      of skGewerbe:   sGewerbe
      of skKap:       sKap
      of skRente:     sRente
    return (srcKind, true)
  else:
    errors.add("unknown section `[" & sec.rawName &
               "]` (expected: steuerzahler, kind, einkommen, auth)")
    return (sGewerbe, false)

proc applyPersonalSection(conf: var VikingConf, sec: RawSection) =
  let nm = sec.keys.getOrDefault("name", "").strip
  if nm != "" and conf.personal.lastname == "":
    let (fn, ln) = parseFullName(nm)
    conf.personal.firstname = fn
    conf.personal.lastname = ln
  for k, v in sec.keys: applyPersonal(conf.personal, k, v)

proc applySpouseSection(conf: var VikingConf, sec: RawSection) =
  conf.spouse.present = true
  let nm = sec.keys.getOrDefault("name", "").strip
  if nm != "" and conf.spouse.lastname == "":
    let (fn, ln) = parseFullName(nm)
    conf.spouse.firstname = fn
    conf.spouse.lastname = ln
  for k, v in sec.keys: applySpouse(conf.spouse, k, v)

proc applyKidSection(conf: var VikingConf, sec: RawSection,
                     errors: var seq[string]) =
  let nm = sec.keys.getOrDefault("name", "").strip
  if nm == "":
    errors.add("[kind]: `name` key required (full name, e.g. `name = Max Maier`)")
    return
  let (fn, ln) = parseFullName(nm)
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

proc applySourceSection(conf: var VikingConf, sec: RawSection, kind: SourceKind) =
  ## Handle-name rule:
  ##   * explicit `name=` wins
  ##   * otherwise the handle is the type slug (freiberuf / gewerbe /
  ##     rente); KAP requires an explicit name.
  let explicitName = sec.keys.getOrDefault("name", "").strip
  var handle = explicitName
  if handle == "":
    handle = case kind
      of skFreelance: "freiberuf"
      of skGewerbe:   "gewerbe"
      of skRente:     "rente"
      of skKap:       ""
  let defaultRechtsform = case kind
    of skFreelance: "140"
    of skGewerbe:
      let rf = rechtsformFromName(explicitName)
      if rf != "": rf else: "120"
    else: ""

  var idx = -1
  for i, s in conf.sources:
    if s.kind == kind and s.name == handle:
      idx = i
      break
  if idx < 0:
    var src = Source(name: handle, kind: kind, owner: "personal",
                     rechtsform: defaultRechtsform)
    for k, v in sec.keys: applySource(src, k, v)
    conf.sources.add(src)
  else:
    if conf.sources[idx].rechtsform == "":
      conf.sources[idx].rechtsform = defaultRechtsform
    for k, v in sec.keys: applySource(conf.sources[idx], k, v)

const personalKeys = toHashSet([
  "name",
  "year", "jahr",
  "geburtsdatum", "birthdate",
  "idnr",
  "steuernr", "steuernummer", "taxnumber",
  "strasse", "street",
  "nr", "hausnummer", "housenumber",
  "plz", "zip",
  "ort", "city",
  "iban",
  "religion",
  "beruf", "profession",
  "krankenkasse", "kv_art", "kvart",
  "abzuege",
  "alleinerziehend",
])

const spouseKeys = toHashSet([
  "name",
  "geburtsdatum", "birthdate",
  "idnr",
  "steuernr", "steuernummer", "taxnumber",
  "strasse", "street",
  "nr", "hausnummer", "housenumber",
  "plz", "zip",
  "ort", "city",
  "religion",
  "beruf", "profession",
  "krankenkasse", "kv_art", "kvart",
])

const kidKeys = toHashSet([
  "name",
  "geburtsdatum", "birthdate",
  "idnr",
  "verhaeltnis", "kindschaftsverhaeltnis",
  "personb-verhaeltnis", "personbverhaeltnis",
  "kindschaftsverhaeltnis_b", "kindschaftsverhaeltnisb",
  "personb-name", "personbname", "parent_b_name", "parentbname",
  "familienkasse",
  "kindergeld",
  "verhaeltnis_von", "verhaeltnisvon",
  "verhaeltnis_bis", "verhaeltnisbis",
  "wohnsitz_von", "wohnsitzvon",
  "wohnsitz_bis", "wohnsitzbis",
  "haushalt",
  "haushalt_eltern_getrennt", "haushaltelterngetrennt",
])

const authKeys = toHashSet(["cert", "pin", "pincmd"])

const sourceKeys = toHashSet([
  "name", "typ",
  "steuernr", "steuernummer", "taxnumber",
  "rechtsform",
  "versteuerung", "besteuerungsart",
  "art",
  "owner",
  "euer",
  "rente", "renten",
  "vorauszahlungen",
  "gains", "tax", "soli", "kirchensteuer",
  "pauschbetrag", "sparer_pauschbetrag", "sparerpauschbetrag",
  "auslaendische_quellensteuer", "auslaendischequellensteuer", "aqs",
  "nicht_anrechenbar_aqs", "nichtanrechenbaraqs",
  "verluste_aktien", "verlusteaktien",
  "verluste_sonstige", "verlustesonstige",
  "guenstigerpruefung",
  "steuerabzug",
  "ausland", "auslaendisch",
])

func knownKeys(kind: SectionKind): HashSet[string] =
  case kind
  of sPersonal:                 personalKeys
  of sSpouse:                   spouseKeys
  of sKid:                      kidKeys
  of sAuth:                     authKeys
  of sFreelance, sGewerbe,
     sKap, sRente:              sourceKeys

proc applySection(conf: var VikingConf, sec: RawSection,
                  malformedKeys: HashSet[string],
                  errors: var seq[string]) =
  let (kind, ok) = classify(sec, conf, errors)
  if not ok: return
  let known = knownKeys(kind)
  for k in sec.keys.keys:
    if k in malformedKeys: continue  # already reported as malformed line
    if k notin known:
      errors.add(&"[{sec.rawName}]: unknown key `{k}`")
  case kind
  of sAuth:
    for k, v in sec.keys: applyAuth(conf.auth, k, v)
  of sPersonal:
    applyPersonalSection(conf, sec)
  of sSpouse:
    applySpouseSection(conf, sec)
  of sKid:
    applyKidSection(conf, sec, errors)
  of sFreelance:
    applySourceSection(conf, sec, skFreelance)
  of sGewerbe:
    applySourceSection(conf, sec, skGewerbe)
  of sKap:
    applySourceSection(conf, sec, skKap)
  of sRente:
    applySourceSection(conf, sec, skRente)

proc findMalformedLines(path: string):
    tuple[errors: seq[string], keys: HashSet[string]] =
  ## Flag lines that aren't blank, comment, section header, or `key = value`.
  ## parsecfg silently accepts bare words as empty-value keys; catch them here
  ## and return the set of "would-be" keys so downstream unknown-key reporting
  ## can skip them.
  var lineno = 0
  for rawLine in lines(path):
    inc lineno
    let s = rawLine.strip
    if s.len == 0: continue
    if s[0] == ';' or s[0] == '#': continue
    if s[0] == '[': continue
    if '=' notin s:
      result.errors.add(&"{path}:{lineno}: not a key=value pair: {s}")
      result.keys.incl(s.toLowerAscii)

proc raiseIfErrors(errors: seq[string]) =
  if errors.len > 0:
    raise newException(ValueError, errors.join("\n"))

proc loadSingleFile(path: string): VikingConf =
  result.personal = defaultPersonal()
  result.confDir = path.parentDir
  result.confBase = path.extractFilename.changeFileExt("")
  let (malformed, malformedKeys) = findMalformedLines(path)
  var errors = malformed
  for sec in readSections(path):
    applySection(result, sec, malformedKeys, errors)
  raiseIfErrors(errors)

proc mergeFile(conf: var VikingConf, path: string) =
  conf.confDir = path.parentDir
  conf.confBase = path.extractFilename.changeFileExt("")
  let (malformed, malformedKeys) = findMalformedLines(path)
  var errors = malformed
  for sec in readSections(path):
    applySection(conf, sec, malformedKeys, errors)
  raiseIfErrors(errors)

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

proc resolveRelative(conf: VikingConf, path: string): string =
  ## Absolute paths stay as-is; relative paths resolve against the conf dir.
  if path.isAbsolute: path
  else: conf.confDir / path

proc resolveCertPath*(conf: VikingConf): string =
  ## Cert path from `[auth].cert`. Required — no implicit discovery.
  if conf.auth.cert == "":
    raise newException(ValueError,
      "[auth].cert not set in viking.conf (path to the .pfx signing cert)")
  conf.resolveRelative(conf.auth.cert)

proc resolvePin*(conf: VikingConf): string =
  ## Resolve the PIN from `[auth]`. Exactly one of `pin=` or `pincmd=`
  ## must be set.
  ##
  ## * `pin=` — if the resolved path exists as a file, read it and
  ##   return its contents (plaintext PIN file). Otherwise treat the
  ##   value as the PIN itself (inline; not recommended for real
  ##   submissions since the conf may be checked in).
  ## * `pincmd=` — executed as a shell command with `confDir` as cwd;
  ##   stdout is the PIN. Any shell snippet works (`pass show …`,
  ##   `./viking.pin.sh`, `cat viking.pin`, `security find-generic-
  ##   password -s elster -w`, …).
  if conf.auth.pin != "" and conf.auth.pincmd != "":
    raise newException(ValueError, "[auth]: set pin or pincmd, not both")
  if conf.auth.pin != "":
    let resolved = conf.resolveRelative(conf.auth.pin)
    if fileExists(resolved):
      return readFile(resolved).strip
    return conf.auth.pin.strip
  if conf.auth.pincmd != "":
    let cwd = if conf.confDir != "": conf.confDir else: getCurrentDir()
    let (output, rc) = execCmdEx(conf.auth.pincmd, workingDir = cwd)
    if rc != 0:
      raise newException(IOError,
        "[auth].pincmd failed (exit " & $rc & "): " & output)
    return output.strip
  raise newException(ValueError,
    "[auth]: set pin= (plaintext PIN file path, or the PIN itself) " &
    "or pincmd= (shell command that prints the PIN on stdout)")

## ---- EÜR / Rente TSV resolution ----

proc resolveEuerPath*(conf: VikingConf, src: Source): string =
  ## EÜR TSV path (income + costs) from the source's `euer=` key.
  ## Returns "" when unset — callers warn and submit zeros. The path
  ## is a plain relative or absolute file reference; users copy the
  ## conf per tax year to swap data sets cleanly.
  if src.euer == "": return ""
  conf.resolveRelative(src.euer)

proc resolveDeductionsPath*(conf: VikingConf): string =
  ## Deductions TSV path from the taxpayer section's `abzuege=` key.
  ## Optional — callers fall back to the `--deductions` CLI flag (or
  ## warn with `--force` semantics) when unset.
  if conf.personal.deductions == "": return ""
  conf.resolveRelative(conf.personal.deductions)

proc resolveRentePath*(conf: VikingConf): string =
  ## Anlage R TSV path from the first `[einkommen] typ=rente` source.
  ## Optional — when unset, no Anlage R summary is emitted.
  for s in conf.sources:
    if s.kind == skRente and s.rente != "":
      return conf.resolveRelative(s.rente)
  ""

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
  if p.year == 0:
    result.add("personal.year not set in viking.conf (required: the tax year, e.g. `year = 2025`)")
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
  if src.art.len > 25:
    result.add("source [" & src.name & "].art must be <= 25 characters, got " &
               $src.art.len)

func validateForEst*(conf: VikingConf): seq[string] =
  result = checkPersonal(conf.personal,
    ["firstname", "lastname", "birthdate", "taxnumber", "iban"])
  if conf.personal.kvArt notin ["privat", "gesetzlich"]:
    result.add("personal.kv_art must be 'privat' or 'gesetzlich'")
  if conf.personal.profession.len > 25:
    result.add("personal.beruf must be <= 25 characters, got " &
               $conf.personal.profession.len)
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
