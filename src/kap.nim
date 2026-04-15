## KAP TSV parser
## Parses kap.tsv with capital gains data from broker statements.

import std/strutils

type
  KapTotals* = object
    gains*: float
    tax*: float
    soli*: float
    kirchensteuer*: float

proc parseKapTsv*(content: string): KapTotals =
  ## Parse kap.tsv content. Sums all rows for aggregate totals.
  ## Columns: gains, tax, soli, kirchensteuer (last two optional)
  if content.strip.len == 0:
    return

  let lines = content.splitLines
  var headerSkipped = false

  for rawLine in lines:
    let line = rawLine.strip
    if line.len == 0 or line.startsWith("#"):
      continue

    let sep = if '\t' in line: '\t' else: ','
    let fields = line.split(sep)
    if fields.len == 0:
      continue

    let firstField = fields[0].strip
    # Skip header row
    if not headerSkipped:
      if firstField.toLowerAscii == "gains":
        headerSkipped = true
        continue
      # Try to parse as float — if it fails, it's a header
      try:
        discard parseFloat(firstField)
      except ValueError:
        headerSkipped = true
        continue
      headerSkipped = true

    if fields.len < 2:
      raise newException(ValueError, "Malformed kap.tsv line (need at least gains and tax): " & line)

    try:
      result.gains += parseFloat(fields[0].strip)
    except ValueError:
      raise newException(ValueError, "Invalid gains value: " & fields[0].strip)

    try:
      result.tax += parseFloat(fields[1].strip)
    except ValueError:
      raise newException(ValueError, "Invalid tax value: " & fields[1].strip)

    if fields.len > 2 and fields[2].strip.len > 0:
      try:
        result.soli += parseFloat(fields[2].strip)
      except ValueError:
        raise newException(ValueError, "Invalid soli value: " & fields[2].strip)

    if fields.len > 3 and fields[3].strip.len > 0:
      try:
        result.kirchensteuer += parseFloat(fields[3].strip)
      except ValueError:
        raise newException(ValueError, "Invalid kirchensteuer value: " & fields[3].strip)

proc loadKapTsv*(path: string): KapTotals =
  let content = readFile(path)
  return parseKapTsv(content)
