## Invoice CSV/TSV parsing and aggregation for UStVA
## Parses invoice lists and aggregates amounts by tax rate
# TODO: replace float with a distinct int cents type for exact arithmetic

import std/[strutils, options]
import viking/[config, log]

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
    amount0*: Option[float]

  EuerAggregation* = object
    incomeNet*: float        ## Sum of positive amounts (net, excl. VAT)
    incomeVat*: float        ## VAT collected on income
    expenseNet*: float       ## Sum of abs(negative amounts) (net, excl. VAT)
    expenseVorsteuer*: float ## Input VAT on expenses

  UstAggregation* = object
    income19*: float         ## Net income at 19%
    income7*: float          ## Net income at 7%
    income0*: float          ## Net income at 0%
    vorsteuer*: float        ## Input VAT from expenses
    has19*: bool
    has7*: bool
    has0*: bool

  InvoiceError* = object
    line*: int
    msg*: string

func detectFormat*(firstLine: string): char =
  ## Returns '\t' if line contains tabs, else ','
  if '\t' in firstLine: '\t' else: ','

func isHeaderRow*(line: string, sep: char): bool =
  ## True if the first field is not a valid float (i.e. it's a header)
  let fields = line.split(sep, maxsplit = 1)
  if fields.len == 0:
    return true
  try:
    discard parseFloat(fields[0].strip)
    return false
  except ValueError:
    return true

func parseInvoices*(input: string): (seq[Invoice], seq[InvoiceError]) =
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

    # Column 1: rate (optional, default 19). Accepts "7" or "7%".
    if fields.len > 1 and fields[1].strip.len > 0:
      var rateStr = fields[1].strip
      if rateStr.endsWith("%"):
        rateStr = rateStr[0 ..< rateStr.len - 1].strip
      try:
        inv.rate = parseInt(rateStr)
        if inv.rate notin [-1, 0, 7, 19]:
          errors.add(InvoiceError(line: lineNum, msg: "invalid rate: " & rateStr & " (must be -1, 0, 7 or 19)"))
          continue
      except ValueError:
        errors.add(InvoiceError(line: lineNum, msg: "invalid rate: " & rateStr & " (must be -1, 0, 7 or 19)"))
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
      var badChar = '\0'
      for c in idStr:
        if not (c.isAlphaNumeric or c == '-' or c == '_'):
          badChar = c
          break
      if badChar != '\0':
        errors.add(InvoiceError(line: lineNum, msg: "invalid invoice-id character: '" & $badChar & "'"))
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

func aggregate*(invoices: seq[Invoice]): InvoiceAggregation =
  ## Sum amounts by rate. Returns Option[float] per rate (none if no invoices at that rate).
  var sum19 = 0.0
  var sum7 = 0.0
  var sum0 = 0.0
  var has19 = false
  var has7 = false
  var has0 = false

  for inv in invoices:
    case inv.rate
    of 19:
      sum19 += inv.amount
      has19 = true
    of 7:
      sum7 += inv.amount
      has7 = true
    of 0:
      sum0 += inv.amount
      has0 = true
    else:
      discard

  result.amount19 = if has19: some(sum19) else: none(float)
  result.amount7 = if has7: some(sum7) else: none(float)
  result.amount0 = if has0: some(sum0) else: none(float)

func monthsForPeriod*(period: string): seq[int] =
  ## Return which months (1-12) a period covers.
  let p = parseInt(period)
  if p >= 1 and p <= 12:
    result = @[p]
  else:
    # Quarterly: 41=Q1(1-3), 42=Q2(4-6), 43=Q3(7-9), 44=Q4(10-12)
    let startMonth = (p - 41) * 3 + 1
    result = @[startMonth, startMonth + 1, startMonth + 2]

func filterByPeriod*(invoices: seq[Invoice], year: int, period: string): seq[Invoice] =
  ## Filter invoices to those matching the given year and period.
  ## Invoices without a date are excluded.
  let months = monthsForPeriod(period)
  let yearStr = $year
  for inv in invoices:
    if inv.date.len == 0:
      continue
    # date is YYYY-MM-DD, already validated
    let parts = inv.date.split('-')
    if parts.len >= 2 and parts[0] == yearStr and parseInt(parts[1]) in months:
      result.add(inv)

proc readInvoiceInput*(path: string): string =
  ## Read invoice data from file or stdin (path "-")
  if path == "-":
    return stdin.readAll
  else:
    return readFile(path)

func aggregateForEuer*(invoices: seq[Invoice]): EuerAggregation =
  ## Split invoices into income (positive) and expenses (negative) for EÜR.
  ## Positive amounts = income, negative amounts = expenses. rate = -1 is
  ## "nicht steuerbar" (EÜR-only): counts toward income/expense with no VAT.
  for inv in invoices:
    let rate = if inv.rate < 0: 0.0 else: inv.rate.float / 100.0
    if inv.amount >= 0:
      result.incomeNet += inv.amount
      result.incomeVat += roundCents(inv.amount * rate)
    else:
      result.expenseNet += abs(inv.amount)
      result.expenseVorsteuer += roundCents(abs(inv.amount) * rate)

proc loadAndAggregateInvoices*(path: string, year: int = 0, period: string = ""): (InvoiceAggregation, bool) =
  ## Top-level entry point: read, parse, optionally filter by period, aggregate.
  ## Prints errors to stderr. Returns (aggregation, success).
  var input: string
  try:
    input = readInvoiceInput(path)
  except IOError as e:
    err("Error: Cannot read invoice file: " & e.msg)
    return (InvoiceAggregation(), false)

  let (invoices, errors) = parseInvoices(input)

  if errors.len > 0:
    err("Invoice parsing errors:")
    for e in errors:
      err("  line " & $e.line & ": " & e.msg)
    return (InvoiceAggregation(), false)

  if invoices.len == 0:
    return (InvoiceAggregation(), true)

  var filtered = invoices
  if year > 0 and period != "":
    # Check if any invoices have dates - only filter if at least one does
    var dated = 0
    var undated = 0
    for inv in invoices:
      if inv.date.len > 0: inc dated
      else: inc undated
    if dated > 0:
      if undated > 0:
        err("Warning: " & $undated & " invoice(s) without date excluded from period filter")
      filtered = filterByPeriod(invoices, year, period)

  (aggregate(filtered), true)

proc loadAndAggregateForEuer*(path: string): (EuerAggregation, bool) =
  ## Top-level entry point for EÜR: read, parse, aggregate by income/expense.
  var input: string
  try:
    input = readInvoiceInput(path)
  except IOError as e:
    err("Error: Cannot read invoice file: " & e.msg)
    return (EuerAggregation(), false)

  let (invoices, errors) = parseInvoices(input)

  if errors.len > 0:
    err("Invoice parsing errors:")
    for e in errors:
      err("  line " & $e.line & ": " & e.msg)
    return (EuerAggregation(), false)

  if invoices.len == 0:
    return (EuerAggregation(), true)

  let agg = aggregateForEuer(invoices)
  return (agg, true)

func aggregateForUst*(invoices: seq[Invoice]): UstAggregation =
  ## Split invoices into income by rate and expense Vorsteuer for annual USt.
  ## rate = -1 is "nicht steuerbar" — skipped (EÜR-only; see aggregateForEuer).
  for inv in invoices:
    if inv.rate < 0:
      continue
    let rate = inv.rate.float / 100.0
    if inv.amount >= 0:
      case inv.rate
      of 19:
        result.income19 += inv.amount
        result.has19 = true
      of 7:
        result.income7 += inv.amount
        result.has7 = true
      of 0:
        result.income0 += inv.amount
        result.has0 = true
      else: discard
    else:
      result.vorsteuer += roundCents(abs(inv.amount) * rate)

proc loadAndAggregateForUst*(path: string): (UstAggregation, bool) =
  ## Top-level entry point for annual USt: read, parse, aggregate.
  var input: string
  try:
    input = readInvoiceInput(path)
  except IOError as e:
    err("Error: Cannot read invoice file: " & e.msg)
    return (UstAggregation(), false)

  let (invoices, errors) = parseInvoices(input)

  if errors.len > 0:
    err("Invoice parsing errors:")
    for e in errors:
      err("  line " & $e.line & ": " & e.msg)
    return (UstAggregation(), false)

  if invoices.len == 0:
    return (UstAggregation(), true)

  let agg = aggregateForUst(invoices)
  return (agg, true)
