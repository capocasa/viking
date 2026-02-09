## Invoice CSV/TSV parsing and aggregation for UStVA
## Parses invoice lists and aggregates amounts by tax rate

import std/[strutils, options]

type
  Invoice* = object
    amount*: float
    rate*: int
    date*: string
    invoiceId*: string
    description*: string

  InvoiceAggregation* = object
    amount19*: Option[float]
    amount7*: Option[float]
    count*: int

  InvoiceError* = object
    line*: int
    msg*: string

proc detectFormat*(firstLine: string): char =
  ## Returns '\t' if line contains tabs, else ','
  if '\t' in firstLine: '\t' else: ','

proc isHeaderRow*(line: string, sep: char): bool =
  ## True if the first field is not a valid float (i.e. it's a header)
  let fields = line.split(sep, maxsplit = 1)
  if fields.len == 0:
    return true
  try:
    discard parseFloat(fields[0].strip)
    return false
  except ValueError:
    return true

proc parseInvoices*(input: string): (seq[Invoice], seq[InvoiceError]) =
  ## Parse all lines from input, collecting invoices and errors.
  ## Skips empty lines, comment lines (#), and optional header row.
  ## Strips UTF-8 BOM if present.
  var invoices: seq[Invoice] = @[]
  var errors: seq[InvoiceError] = @[]

  var text = input
  # Strip UTF-8 BOM
  if text.len >= 3 and text[0..2] == "\xEF\xBB\xBF":
    text = text[3..^1]

  let lines = text.splitLines
  if lines.len == 0:
    return (invoices, errors)

  # Find first non-empty, non-comment line to detect format
  var sep = ','
  var headerSkipped = false
  for line in lines:
    let stripped = line.strip
    if stripped.len == 0 or stripped.startsWith("#"):
      continue
    sep = detectFormat(stripped)
    if isHeaderRow(stripped, sep):
      headerSkipped = true
    break

  for i, rawLine in lines:
    let lineNum = i + 1
    let line = rawLine.strip
    if line.len == 0 or line.startsWith("#"):
      continue

    # Skip header row (first non-empty, non-comment line if it's a header)
    if headerSkipped:
      headerSkipped = false
      continue

    # Split with maxsplit=4 so description can contain separators
    let fields = line.split(sep, maxsplit = 4)
    if fields.len == 0:
      continue

    var inv: Invoice

    # Column 0: amount (required)
    let amountStr = fields[0].strip
    try:
      inv.amount = parseFloat(amountStr)
    except ValueError:
      errors.add(InvoiceError(line: lineNum, msg: "invalid amount: " & amountStr))
      continue

    # Column 1: rate (optional, default 19)
    if fields.len > 1 and fields[1].strip.len > 0:
      let rateStr = fields[1].strip
      try:
        inv.rate = parseInt(rateStr)
        if inv.rate != 7 and inv.rate != 19:
          errors.add(InvoiceError(line: lineNum, msg: "invalid rate: " & rateStr & " (must be 7 or 19)"))
          continue
      except ValueError:
        errors.add(InvoiceError(line: lineNum, msg: "invalid rate: " & rateStr & " (must be 7 or 19)"))
        continue
    else:
      inv.rate = 19

    # Column 2: date (optional)
    if fields.len > 2 and fields[2].strip.len > 0:
      let dateStr = fields[2].strip
      # Basic YYYY-MM-DD validation
      if dateStr.len != 10 or dateStr[4] != '-' or dateStr[7] != '-':
        errors.add(InvoiceError(line: lineNum, msg: "invalid date: " & dateStr & " (expected YYYY-MM-DD)"))
        continue
      try:
        let parts = dateStr.split('-')
        let y = parseInt(parts[0])
        let m = parseInt(parts[1])
        let d = parseInt(parts[2])
        if y < 2000 or y > 2099 or m < 1 or m > 12 or d < 1 or d > 31:
          errors.add(InvoiceError(line: lineNum, msg: "invalid date: " & dateStr))
          continue
      except ValueError:
        errors.add(InvoiceError(line: lineNum, msg: "invalid date: " & dateStr & " (expected YYYY-MM-DD)"))
        continue
      inv.date = dateStr

    # Column 3: invoice-id (optional)
    if fields.len > 3 and fields[3].strip.len > 0:
      let idStr = fields[3].strip
      if idStr.len > 64:
        errors.add(InvoiceError(line: lineNum, msg: "invoice-id too long: " & $idStr.len & " chars (max 64)"))
        continue
      for c in idStr:
        if not (c.isAlphaNumeric or c == '-' or c == '_'):
          errors.add(InvoiceError(line: lineNum, msg: "invalid invoice-id character: '" & $c & "'"))
          break
      if errors.len > 0 and errors[^1].line == lineNum:
        continue
      inv.invoiceId = idStr

    # Column 4: description (optional, rest-of-line)
    if fields.len > 4:
      let desc = fields[4].strip
      if desc.len > 256:
        errors.add(InvoiceError(line: lineNum, msg: "description too long: " & $desc.len & " chars (max 256)"))
        continue
      inv.description = desc

    invoices.add(inv)

  return (invoices, errors)

proc aggregate*(invoices: seq[Invoice]): InvoiceAggregation =
  ## Sum amounts by rate. Returns Option[float] per rate (none if no invoices at that rate).
  var sum19 = 0.0
  var sum7 = 0.0
  var has19 = false
  var has7 = false

  for inv in invoices:
    case inv.rate
    of 19:
      sum19 += inv.amount
      has19 = true
    of 7:
      sum7 += inv.amount
      has7 = true
    else:
      discard

  result.amount19 = if has19: some(sum19) else: none(float)
  result.amount7 = if has7: some(sum7) else: none(float)
  result.count = invoices.len

proc readInvoiceInput*(path: string): string =
  ## Read invoice data from file or stdin (path "-")
  if path == "-":
    return stdin.readAll
  else:
    return readFile(path)

proc loadAndAggregateInvoices*(path: string): (InvoiceAggregation, bool) =
  ## Top-level entry point: read, parse, aggregate. Prints errors to stderr.
  ## Returns (aggregation, success).
  var input: string
  try:
    input = readInvoiceInput(path)
  except IOError as e:
    stderr.writeLine("Error: Cannot read invoice file: " & e.msg)
    return (InvoiceAggregation(), false)

  let (invoices, errors) = parseInvoices(input)

  if errors.len > 0:
    stderr.writeLine("Invoice parsing errors:")
    for e in errors:
      stderr.writeLine("  line " & $e.line & ": " & e.msg)
    return (InvoiceAggregation(), false)

  if invoices.len == 0:
    # Empty file or header-only is valid: zero amounts
    return (InvoiceAggregation(amount19: none(float), amount7: none(float), count: 0), true)

  let agg = aggregate(invoices)
  return (agg, true)
