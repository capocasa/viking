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

  # Anlage Kind (used with kid firstname prefix)
  FormField(form: "kind", kz: 174, code: "E0506105"),  # Kinderbetreuungskosten
  FormField(form: "kind", kz: 176, code: "E0505607"),  # Schulgeld
]

const knownFormPrefixes* = ["vor", "sa", "agb"]

# Build lookup tables at compile time
proc buildFormLookup(): Table[string, string] =
  result = initTable[string, string]()
  for f in fieldMap:
    let key = f.form & ":" & $f.kz
    result[key] = f.code

const formLookup = buildFormLookup()

proc parseCompoundCode*(code: string): ParsedCode =
  ## Parse a compound code like "vor326" or "lena174" into prefix + KZ.
  ## Splits at the letter→digit boundary. Case-insensitive.
  var i = 0
  let lower = code.toLowerAscii
  while i < lower.len and not lower[i].isDigit:
    inc i
  if i == 0 or i == lower.len:
    raise newException(ValueError, "Invalid code format: " & code & " (expected letters followed by digits)")
  let prefix = lower[0 ..< i]
  let kzStr = lower[i ..< lower.len]
  var kz: int
  try:
    kz = parseInt(kzStr)
  except ValueError:
    raise newException(ValueError, "Invalid Kennzahl in code: " & code)
  result = ParsedCode(prefix: prefix, kz: kz)

proc lookupCode*(form: string, kz: int): string =
  ## Look up the ERiC XML element code for a (form, kz) pair.
  ## Returns empty string if not found.
  let key = form & ":" & $kz
  if key in formLookup:
    return formLookup[key]
  return ""

proc isKnownFormPrefix*(prefix: string): bool =
  prefix in knownFormPrefixes

proc resolveDeductionCode*(code: string, kidNames: seq[string]): tuple[ericCode: string, form: string, kidName: string] =
  ## Resolve a deductions.tsv code to its ERiC element code.
  ## Returns (ericCode, form, kidName). kidName is non-empty only for child deductions.
  let parsed = parseCompoundCode(code)

  if isKnownFormPrefix(parsed.prefix):
    let ericCode = lookupCode(parsed.prefix, parsed.kz)
    if ericCode == "":
      raise newException(ValueError, "Unknown Kennzahl " & $parsed.kz & " for form " & parsed.prefix)
    return (ericCode, parsed.prefix, "")

  # Check if prefix matches a kid name
  for name in kidNames:
    if name.toLowerAscii == parsed.prefix:
      let ericCode = lookupCode("kind", parsed.kz)
      if ericCode == "":
        raise newException(ValueError, "Unknown Kennzahl " & $parsed.kz & " for Anlage Kind")
      return (ericCode, "kind", name)

  # Build helpful error message
  var knownKids = ""
  if kidNames.len > 0:
    knownKids = ". Known kids: " & kidNames.join(", ")
  raise newException(ValueError, "Unknown prefix \"" & parsed.prefix &
    "\". Known forms: " & knownFormPrefixes.join(", ") & knownKids)
