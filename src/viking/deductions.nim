## Deductions TSV parser
## Parses deductions.tsv with compound codes (e.g. vor326, sa140, lena174)

import std/[strutils, tables]
import viking/kzmap

type
  DeductionEntry* = object
    ericCode*: string
    amount*: float
    form*: string        # "vor", "sa", "agb", "kind"
    kidName*: string     # non-empty for child deductions

  DeductionsByForm* = object
    vor*: Table[string, float]    # ERiC code → amount
    sa*: Table[string, float]
    agb*: Table[string, float]
    kids*: Table[string, Table[string, float]]  # kidName → (ERiC code → amount)

func parseDeductions*(content: string, kidNames: seq[string]): DeductionsByForm =
  ## Parse deductions.tsv content and group by form section.
  result.vor = initTable[string, float]()
  result.sa = initTable[string, float]()
  result.agb = initTable[string, float]()
  result.kids = initTable[string, Table[string, float]]()

  if content.strip.len == 0:
    return

  let lines = content.splitLines
  var headerSkipped = false

  for rawLine in lines:
    let line = rawLine.strip
    if line.len == 0 or line.startsWith("#"):
      continue

    let sep = if '\t' in line: '\t' else: ','
    let fields = line.split(sep, maxsplit = 2)
    if fields.len == 0:
      continue

    let firstField = fields[0].strip
    # Skip header row
    if not headerSkipped:
      if firstField.toLowerAscii == "code":
        headerSkipped = true
        continue
      # Check if first field looks like a code (letters+digits)
      var hasLetters = false
      var hasDigits = false
      for c in firstField:
        if c.isAlphaAscii: hasLetters = true
        if c.isDigit: hasDigits = true
      if not (hasLetters and hasDigits):
        headerSkipped = true
        continue
      headerSkipped = true

    if fields.len < 2:
      raise newException(ValueError, "Malformed line (need code and amount): " & line)

    let code = fields[0].strip
    let amountStr = fields[1].strip
    var amount: float
    try:
      amount = parseFloat(amountStr)
    except ValueError:
      raise newException(ValueError, "Invalid amount '" & amountStr & "' for code " & code)

    let resolved = resolveDeductionCode(code, kidNames)
    let ec = resolved.ericCode
    case resolved.form
    of "vor": result.vor[ec] = result.vor.getOrDefault(ec) + amount
    of "sa":  result.sa[ec]  = result.sa.getOrDefault(ec)  + amount
    of "agb": result.agb[ec] = result.agb.getOrDefault(ec) + amount
    of "kind":
      if resolved.kidName notin result.kids:
        result.kids[resolved.kidName] = initTable[string, float]()
      result.kids[resolved.kidName][ec] =
        result.kids[resolved.kidName].getOrDefault(ec) + amount
    else: discard

proc loadDeductions*(path: string, kidNames: seq[string]): DeductionsByForm =
  ## Load and parse a deductions.tsv file.
  let content = readFile(path)
  return parseDeductions(content, kidNames)
