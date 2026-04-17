## Alphanumeric (German-word) aliases for numeric ELSTER codes.
## Covers income, rechtsform, besteuerungsart, religion,
## kindschaftsverhaeltnis and UStVA period. Numerics still work
## (with or without leading zeros); resolve() returns the canonical
## numeric the schema expects, or raises ValueError listing the words.

import std/[strutils]

type
  CodeEntry* = object
    word*: string          ## canonical word ("" if numeric-only known code)
    number*: string        ## ELSTER numeric value (already padded per schema)
    desc*: string          ## short description
    aliases*: seq[string]  ## additional words mapping to the same number

  CodeMap* = object
    field*: string
    entries*: seq[CodeEntry]

func norm(s: string): string = s.strip.toLowerAscii

func numericMatches(canonical, typed: string): bool =
  if canonical == typed: return true
  try: return parseInt(canonical) == parseInt(typed)
  except ValueError: return false

func listing*(m: CodeMap): string =
  var words: seq[string]
  for e in m.entries:
    if e.word.len > 0: words.add(e.word)
  if words.len == 0:
    return "valid: (numeric)"
  "valid: " & words.join(", ")

func resolve*(m: CodeMap, input: string): string =
  ## Normalize input (word, alias, or numeric) to the canonical ELSTER
  ## numeric. Raises ValueError on empty/unknown.
  let n = norm(input)
  if n.len == 0:
    raise newException(ValueError, m.field & " is empty; " & m.listing)
  for e in m.entries:
    if n == e.word: return e.number
    for a in e.aliases:
      if n == a: return e.number
  for e in m.entries:
    if numericMatches(e.number, n): return e.number
  raise newException(ValueError,
    m.field & " = \"" & input & "\": unknown; " & m.listing)

func tryResolve*(m: CodeMap, input: string): string =
  ## Like resolve but returns "" on failure. For optional fields.
  try: m.resolve(input)
  except ValueError: ""

# ---- Mappings ----

const incomeMap* = CodeMap(field: "income", entries: @[
  CodeEntry(word: "gewerbe", number: "2", desc: "Gewerbebetrieb (Anlage G)"),
  CodeEntry(word: "freiberuf", number: "3",
            desc: "Selbstaendige Arbeit (Anlage S)",
            aliases: @["selbst", "freelance"]),
  CodeEntry(word: "kap", number: "kap",
            desc: "Kapitalvermoegen (Anlage KAP)"),
])

const besteuerungsartMap* = CodeMap(field: "besteuerungsart", entries: @[
  CodeEntry(word: "soll", number: "1",
            desc: "vereinbarten Entgelten (Soll-Versteuerung)"),
  CodeEntry(word: "ist",  number: "2",
            desc: "vereinnahmten Entgelten (Ist-Versteuerung)"),
  CodeEntry(word: "teilist", number: "3",
            desc: "vereinnahmten nur fuer einzelne Unternehmensteile",
            aliases: @["teil-ist", "teil_ist"]),
])

const kindschaftsverhaeltnisMap* = CodeMap(
  field: "kindschaftsverhaeltnis", entries: @[
    CodeEntry(word: "leiblich", number: "1",
              desc: "leibliches Kind / Adoptivkind",
              aliases: @["adoptiv"]),
    CodeEntry(word: "pflege",   number: "2", desc: "Pflegekind"),
    CodeEntry(word: "enkel",    number: "3",
              desc: "Enkelkind / Stiefkind",
              aliases: @["stief"]),
  ])

const rechtsformMap* = CodeMap(field: "rechtsform", entries: @[
  # Natural persons / sole operators
  CodeEntry(word: "hausgewerbe", number: "110",
            desc: "Hausgewerbetreibende oder gleichgestellte Person"),
  CodeEntry(word: "einzel", number: "120",
            desc: "Sonstige Einzelgewerbetreibende"),
  CodeEntry(word: "landforst", number: "130", desc: "Land- oder Forstwirt"),
  CodeEntry(word: "freiberuf", number: "140",
            desc: "Angehoerige freier Berufe"),
  CodeEntry(word: "selbst", number: "150",
            desc: "Sonstige selbstaendig taetige Personen"),
  CodeEntry(word: "beteiligung", number: "160",
            desc: "Beteiligungen an gewerblichen Personengesellschaften"),
  CodeEntry(word: "person", number: "190",
            desc: "Sonstige natuerliche Person"),
  # Partnerships
  CodeEntry(word: "atypisch", number: "200",
            desc: "Atypisch stille Gesellschaft"),
  CodeEntry(word: "ohg", number: "210", desc: "Offene Handelsgesellschaft"),
  CodeEntry(word: "kg",  number: "220", desc: "Kommanditgesellschaft"),
  CodeEntry(word: "gmbhkg",  number: "230", desc: "GmbH und Co. KG"),
  CodeEntry(word: "gmbhohg", number: "240", desc: "GmbH und Co. OHG"),
  CodeEntry(word: "agkg",    number: "250", desc: "AG und Co. KG"),
  CodeEntry(word: "agohg",   number: "260", desc: "AG und Co. OHG"),
  CodeEntry(word: "gbr", number: "270",
            desc: "Gesellschaft buergerlichen Rechts"),
  CodeEntry(word: "ewiv", number: "280",
            desc: "Europ. wirtschaftliche Interessenvereinigung"),
  CodeEntry(word: "sonstperson", number: "290",
            desc: "sonstige Personengesellschaft"),
  # Corporations
  CodeEntry(word: "ag",   number: "310", desc: "Aktiengesellschaft"),
  CodeEntry(word: "kgaa", number: "320", desc: "KGaA"),
  CodeEntry(word: "gmbh", number: "350",
            desc: "Gesellschaft mit beschraenkter Haftung"),
  CodeEntry(word: "se", number: "360",
            desc: "Europaeische Gesellschaft (SE)"),
  CodeEntry(word: "ug", number: "370",
            desc: "Unternehmergesellschaft (haftungsbeschraenkt)"),
  # Cooperatives / insurance / other legal persons
  CodeEntry(word: "sce", number: "450",
            desc: "Europaeische Genossenschaft (SCE)"),
  CodeEntry(word: "genossenschaft", number: "490",
            desc: "sonstige Genossenschaft"),
  CodeEntry(word: "vvag", number: "510",
            desc: "Versicherungsverein auf Gegenseitigkeit"),
  CodeEntry(word: "jp_priv", number: "590",
            desc: "sonstige juristische Person priv. Rechts"),
  CodeEntry(word: "verein", number: "621",
            desc: "Nichtrechtsfaehiger Verein"),
  # Public-law entities
  CodeEntry(word: "gebiets", number: "810", desc: "Gebietskoerperschaft"),
  CodeEntry(word: "relgesell", number: "820",
            desc: "oeffentlich-rechtl. Religionsgesellschaft"),
  CodeEntry(word: "jp_oeff", number: "834",
            desc: "sonstige juristische Person oeffentl. Rechts"),
  # Foreign
  CodeEntry(word: "ausl_kap", number: "910",
            desc: "auslaendische Koerperschaft (KStG § 1 Abs.1 Nr.1)"),
  CodeEntry(word: "ausl_person", number: "920",
            desc: "auslaendische Personengesellschaft"),
])

const religionMap* = CodeMap(field: "religion", entries: @[
  CodeEntry(word: "keine", number: "11",
            desc: "nicht kirchensteuerpflichtig",
            aliases: @["none", "konfessionslos"]),
  CodeEntry(word: "ev", number: "02", desc: "Evangelisch",
            aliases: @["evangelisch"]),
  CodeEntry(word: "rk", number: "03", desc: "Roemisch-katholisch",
            aliases: @["katholisch", "roem_kath"]),
  CodeEntry(word: "altkath", number: "04", desc: "Altkatholisch"),
  CodeEntry(word: "ev_ref", number: "05", desc: "Evangelisch-reformiert"),
  CodeEntry(word: "franz_ref", number: "07",
            desc: "Franzoesisch-reformiert"),
  CodeEntry(word: "sonstige", number: "10", desc: "Sonstige"),
  CodeEntry(number: "12",
            desc: "Israelitische Religionsgemeinschaft Wuerttemberg"),
  CodeEntry(number: "13", desc: "Freireligioese Landesgemeinde Baden"),
  CodeEntry(number: "14", desc: "Freireligioese Landesgemeinde Pfalz"),
  CodeEntry(number: "15", desc: "Freireligioese Gemeinde Mainz"),
  CodeEntry(number: "16", desc: "Freie Religionsgemeinschaft Alzey"),
  CodeEntry(number: "17", desc: "Freireligioese Gemeinde Offenbach"),
  CodeEntry(number: "18", desc: "Juedische Gemeinde Frankfurt (Hessen)"),
  CodeEntry(number: "19", desc: "Juedische Gemeinden Hessen"),
  CodeEntry(number: "20", desc: "Ev.-ref. Kirche Bueckeburg"),
  CodeEntry(number: "21", desc: "Ev.-ref. Kirche Stadthagen"),
  CodeEntry(number: "24", desc: "Juedische Gemeinde Hamburg"),
  CodeEntry(number: "25", desc: "Israelitische Religionsgemeinschaft Baden"),
  CodeEntry(number: "26",
            desc: "Landesverband isr. Kultusgemeinden Bayern"),
  CodeEntry(number: "27",
            desc: "Juedische Kultusgemeinden Bad Kreuznach/Koblenz"),
  CodeEntry(number: "28", desc: "Israelitisch (Saarland)"),
  CodeEntry(number: "29", desc: "Nordrhein-Westfalen: Israelitisch"),
])

const periodMap* = CodeMap(field: "period", entries: @[
  CodeEntry(word: "jan", number: "01", desc: "Januar/January"),
  CodeEntry(word: "feb", number: "02", desc: "Februar/February"),
  CodeEntry(word: "mar", number: "03", desc: "Maerz/March"),
  CodeEntry(word: "apr", number: "04", desc: "April"),
  CodeEntry(word: "mai", number: "05", desc: "Mai/May", aliases: @["may"]),
  CodeEntry(word: "jun", number: "06", desc: "Juni/June"),
  CodeEntry(word: "jul", number: "07", desc: "Juli/July"),
  CodeEntry(word: "aug", number: "08", desc: "August"),
  CodeEntry(word: "sep", number: "09", desc: "September"),
  CodeEntry(word: "okt", number: "10", desc: "Oktober/October",
            aliases: @["oct"]),
  CodeEntry(word: "nov", number: "11", desc: "November"),
  CodeEntry(word: "dez", number: "12", desc: "Dezember/December",
            aliases: @["dec"]),
  CodeEntry(word: "q1", number: "41", desc: "Quarter 1 (Jan-Mar)"),
  CodeEntry(word: "q2", number: "42", desc: "Quarter 2 (Apr-Jun)"),
  CodeEntry(word: "q3", number: "43", desc: "Quarter 3 (Jul-Sep)"),
  CodeEntry(word: "q4", number: "44", desc: "Quarter 4 (Oct-Dec)"),
])
