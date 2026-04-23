## KZ (Kennzahl) → ERiC XML element code mapping
## Maps (form prefix, Kennzahl) pairs to ERiC XML element codes.
## Kennzahlen come from the annotated tax form images (Vordrucke).

import std/[strutils, tables]

type
  FormField* = object
    form*: string      # "vor", "sa", "agb", "kind"
    kz*: int           # Kennzahl from paper form
    code*: string      # ERiC XML element (e.g. "E2001805")

  ParsedCode* = object
    prefix*: string    # form prefix or kid name (lowercase)
    kz*: int           # Kennzahl
    suffix*: string    # optional suffix after "_", e.g. "eigen"

const fieldMap*: seq[FormField] = @[
  # Anlage Vorsorgeaufwand (VOR)
  FormField(form: "vor", kz: 300, code: "E2000601"),   # Rentenversicherung
  FormField(form: "vor", kz: 326, code: "E2001805"),   # KV gesetzl. And_Pers
  FormField(form: "vor", kz: 329, code: "E2002105"),   # Pflegeversicherung gesetzl.
  FormField(form: "vor", kz: 338, code: "E2002206"),   # Zusatzbeitrag KV gesetzl.
  FormField(form: "vor", kz: 316, code: "E2003104"),   # KV privat
  FormField(form: "vor", kz: 319, code: "E2003202"),   # Pflegeversicherung privat
  FormField(form: "vor", kz: 328, code: "E2003302"),   # Zusatzbeitrag KV privat
  FormField(form: "vor", kz: 502, code: "E2001803"),   # Haftpflicht/Unfall (sonstige)

  # Sonderausgaben (SA)
  FormField(form: "sa", kz: 140, code: "E0107601"),    # Kirchensteuer gezahlt
  FormField(form: "sa", kz: 141, code: "E0107602"),    # Kirchensteuer erstattet
  FormField(form: "sa", kz: 131, code: "E0108105"),    # Spenden

  # Außergewöhnliche Belastungen (AgB)
  FormField(form: "agb", kz: 187, code: "E0161304"),   # Krankheitskosten

  # §35a Hauptvordruck — haushaltsnah / handwerker (Sum codes; the
  # renderer mirrors each into a single-entry Einz block alongside Sum)
  FormField(form: "hhn", kz: 71,  code: "E0104109"),   # Minijob-Beschaeftigung
  FormField(form: "hhn", kz: 72,  code: "E0107208"),   # SVB + haushaltsnahe DL
  FormField(form: "hwk", kz: 73,  code: "E0111215"),   # Handwerkerleistungen

  # Anlage Kind (used with kid firstname prefix)
  FormField(form: "kind", kz: 174, code: "E0506105"),  # Kinderbetreuungskosten Sum
  FormField(form: "kind", kz: 176, code: "E0505607"),  # Schulgeld Sum
]

const kindSuffixMap*: seq[tuple[kz: int, suffix: string, code: string]] = @[
  # Einzelveranlagung "selbst getragen" companion codes:
  (174, "eigen", "E0506604"),   # KBK, Elt_k_ZV/Kosten/Sum
  (176, "eigen", "E0504505"),   # Schulgeld, Elt_k_ZV
]

const knownFormPrefixes* = ["vor", "sa", "agb", "hhn", "hwk"]

# Build lookup tables at compile time
func buildFormLookup(): Table[string, string] =
  result = initTable[string, string]()
  for f in fieldMap:
    let key = f.form & ":" & $f.kz
    result[key] = f.code

func buildKindSuffixLookup(): Table[string, string] =
  result = initTable[string, string]()
  for e in kindSuffixMap:
    result[$e.kz & ":" & e.suffix] = e.code

const formLookup = buildFormLookup()
const kindSuffixLookup = buildKindSuffixLookup()

func parseCompoundCode*(code: string): ParsedCode =
  ## Parse a compound code like "vor326", "lena174" or "celeste176_eigen"
  ## into prefix + KZ (+ optional suffix). Splits at the letter→digit
  ## boundary; an underscore terminates the Kennzahl and opens the suffix.
  ## Case-insensitive.
  var i = 0
  let lower = code.toLowerAscii
  while i < lower.len and not lower[i].isDigit:
    inc i
  if i == 0 or i == lower.len:
    raise newException(ValueError, "Invalid code format: " & code & " (expected letters followed by digits)")
  let prefix = lower[0 ..< i]
  var j = i
  while j < lower.len and lower[j].isDigit:
    inc j
  let kzStr = lower[i ..< j]
  var suffix = ""
  if j < lower.len:
    if lower[j] != '_':
      raise newException(ValueError, "Invalid Kennzahl in code: " & code)
    suffix = lower[j + 1 ..< lower.len]
    if suffix.len == 0:
      raise newException(ValueError, "Empty suffix after '_' in code: " & code)
  var kz: int
  try:
    kz = parseInt(kzStr)
  except ValueError:
    raise newException(ValueError, "Invalid Kennzahl in code: " & code)
  result = ParsedCode(prefix: prefix, kz: kz, suffix: suffix)

func lookupCode*(form: string, kz: int): string =
  ## Look up the ERiC XML element code for a (form, kz) pair.
  ## Returns empty string if not found.
  let key = form & ":" & $kz
  if key in formLookup:
    return formLookup[key]
  return ""

func isKnownFormPrefix*(prefix: string): bool =
  prefix in knownFormPrefixes

func resolveDeductionCode*(code: string, kidNames: seq[string]): tuple[ericCode: string, form: string, kidName: string] =
  ## Resolve a deductions.tsv code to its ERiC element code.
  ## Returns (ericCode, form, kidName). kidName is non-empty only for child deductions.
  let parsed = parseCompoundCode(code)

  if isKnownFormPrefix(parsed.prefix):
    if parsed.suffix != "":
      raise newException(ValueError,
        "Suffix '_" & parsed.suffix & "' not supported for form " & parsed.prefix)
    let ericCode = lookupCode(parsed.prefix, parsed.kz)
    if ericCode == "":
      raise newException(ValueError, "Unknown Kennzahl " & $parsed.kz & " for form " & parsed.prefix)
    return (ericCode, parsed.prefix, "")

  # Check if prefix matches a kid name
  for name in kidNames:
    if name.toLowerAscii == parsed.prefix:
      var ericCode = ""
      if parsed.suffix != "":
        let key = $parsed.kz & ":" & parsed.suffix
        if key in kindSuffixLookup:
          ericCode = kindSuffixLookup[key]
        else:
          raise newException(ValueError,
            "Unknown suffix '_" & parsed.suffix & "' for Anlage Kind Kz " & $parsed.kz)
      else:
        ericCode = lookupCode("kind", parsed.kz)
      if ericCode == "":
        raise newException(ValueError, "Unknown Kennzahl " & $parsed.kz & " for Anlage Kind")
      return (ericCode, "kind", name)

  # Build helpful error message
  var knownKids = ""
  if kidNames.len > 0:
    knownKids = ". Known kids: " & kidNames.join(", ")
  raise newException(ValueError, "Unknown prefix \"" & parsed.prefix &
    "\". Known forms: " & knownFormPrefixes.join(", ") & knownKids)
