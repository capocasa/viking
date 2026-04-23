## Anlage R (Renten und sonstige Leistungen, §22 EStG) — TSV loader +
## Ertragsanteil lookup.
##
## Scope: MVP surface for the Swiss Freizügigkeit case and related
## cross-border payouts — one TSV row per payout, referenced from an
## `[einkommen] typ=rente` source's `rente = rente.tsv`. Viking logs a
## structured summary per
## row (gross, Ertragsanteil %, computed taxable amount) and emits
## Anlage R / R_AUS XML for the routable cases (see classifyRente in
## est_xml.nim): domestic Leibrente → `<R>/Leibr_priv`, foreign
## Leibrente → `<R_AUS>/Leibr_priv`, foreign Kapital/Freizügigkeit
## (nicht gefördert) → `<R_AUS>/Leist_bAV` (Kennzahl E1823901).
## Gefördert (Riester/Rürup/bAV) and domestic Kapitalleistungen still
## surface as warnings — those must be added via ELSTER Online or a
## Sonstige Nachricht until the Anlage R-AV/bAV emitter lands.
##
## TSV columns (tab-separated, header row required, order-sensitive):
##
##   art  zahler  betrag  zahlung_am  gefoerdert  ertragsanteil_prozent
##   lebensalter_beginn  herkunftsland
##
## Accepted `art` values: leibrente, kapital, einmalzahlung,
## freizuegigkeit, riester, ruerup. `gefoerdert` takes yes/no/1/0.
## `herkunftsland` is an ISO 2-letter country code.

import std/[strutils]

type
  RenteRow* = object
    art*: string               ## lowercased
    zahler*: string
    betrag*: float             ## gross amount in EUR
    zahlungAm*: string         ## payment date (DD.MM.YYYY)
    gefoerdert*: bool
    ertragsanteilProzent*: float  ## explicit override (0 = unset)
    lebensalterBeginn*: int       ## age at Rentenbeginn (0 = unset)
    herkunftsland*: string        ## ISO 2-letter, e.g. "CH"

  RenteSummary* = object
    row*: RenteRow
    taxable*: float               ## steuerpflichtiger Betrag (in EUR)
    ertragsanteilProzent*: float  ## % of gross that is taxable
    note*: string                 ## human-readable explanation

const RenteColumns* = [
  "art", "zahler", "betrag", "zahlung_am", "gefoerdert",
  "ertragsanteil_prozent", "lebensalter_beginn", "herkunftsland",
]

func parseBool(val: string): bool =
  let v = val.strip.toLowerAscii
  v == "1" or v == "yes" or v == "ja" or v == "true"

proc parseRow(fields: seq[string], lineno: int): RenteRow =
  if fields.len != RenteColumns.len:
    raise newException(ValueError,
      "line " & $lineno & ": expected " & $RenteColumns.len &
      " tab-separated columns (" & RenteColumns.join(", ") &
      "), got " & $fields.len)
  result.art = fields[0].strip.toLowerAscii
  result.zahler = fields[1].strip
  try:
    if fields[2].strip.len > 0:
      result.betrag = parseFloat(fields[2].strip)
  except ValueError:
    raise newException(ValueError,
      "line " & $lineno & ": `betrag` is not a number: " & fields[2])
  result.zahlungAm = fields[3].strip
  result.gefoerdert = parseBool(fields[4])
  let pct = fields[5].strip
  if pct.len > 0:
    try: result.ertragsanteilProzent = parseFloat(pct)
    except ValueError:
      raise newException(ValueError,
        "line " & $lineno & ": `ertragsanteil_prozent` is not a number: " & pct)
  let age = fields[6].strip
  if age.len > 0:
    try: result.lebensalterBeginn = parseInt(age)
    except ValueError:
      raise newException(ValueError,
        "line " & $lineno & ": `lebensalter_beginn` is not an integer: " & age)
  result.herkunftsland = fields[7].strip.toUpperAscii

proc loadRente*(path: string): seq[RenteRow] =
  ## Load a rente TSV. Empty lines and comment lines (leading `#`) are
  ## skipped. The header row is validated against `RenteColumns`.
  var lineno = 0
  var headerSeen = false
  for rawLine in lines(path):
    inc lineno
    let line = rawLine.strip
    if line.len == 0 or line.startsWith("#"): continue
    let fields = rawLine.split('\t')
    if not headerSeen:
      headerSeen = true
      # Tolerate whitespace/case differences in header cells.
      var normalized: seq[string]
      for f in fields: normalized.add(f.strip.toLowerAscii)
      if normalized != @RenteColumns:
        raise newException(ValueError,
          path & ": header must be `" & RenteColumns.join("\t") & "`")
      continue
    result.add(parseRow(fields, lineno))

func ertragsanteilFromAge*(age: int): float =
  ## §22 Nr. 1 Satz 3 a bb EStG Ertragsanteils-Tabelle (abridged — the
  ## entries most relevant to a Leibrente starting between 50 and 85).
  ## Returns a percentage (e.g. 18.0 for 18 %). Out-of-range ages fall
  ## back to the nearest tabulated value.
  if age <= 0: return 0.0
  if age < 50: return 30.0
  if age < 55: return 26.0      # 50–54
  if age < 60: return 22.0      # 55–59
  if age < 63: return 20.0      # 60–62
  if age < 65: return 18.0      # 63–64
  if age < 67: return 17.0      # 65–66
  if age < 70: return 15.0      # 67–69
  if age < 73: return 13.0      # 70–72
  if age < 76: return 11.0      # 73–75
  if age < 81: return 9.0       # 76–80
  if age < 86: return 7.0       # 81–85
  return 5.0                    # 86+

proc summarize*(row: RenteRow): RenteSummary =
  ## Compute the taxable portion for a single rente row.
  ##
  ## Decision tree (FR #9 MVP scope):
  ## - gefoerdert=true (Riester, Rürup, gefördertes bAV-Kapital, …)
  ##   → §22 Nr. 5 Satz 1: fully taxable (Ertragsanteil = 100 %).
  ## - explicit ertragsanteil_prozent → use as-is.
  ## - art = leibrente / rente, gefoerdert=false
  ##   → §22 Nr. 1 Satz 3 a bb: Ertragsanteil from age table.
  ## - art = kapital / freizuegigkeit / einmalzahlung, gefoerdert=false
  ##   → §22 Nr. 5 Satz 2: Ertragsanteil only; without an override
  ##     viking can't compute the split — the note asks the filer to
  ##     supply `ertragsanteil_prozent` or `lebensalter_beginn`.
  result.row = row
  let gross = row.betrag

  if row.gefoerdert:
    result.ertragsanteilProzent = 100.0
    result.taxable = gross
    result.note = "§22 Nr. 5 Satz 1 EStG: voll steuerpflichtig (gefördert)"
    return

  if row.ertragsanteilProzent > 0:
    result.ertragsanteilProzent = row.ertragsanteilProzent
    result.taxable = gross * row.ertragsanteilProzent / 100.0
    result.note = "Ertragsanteil-Override aus rente.tsv"
    return

  case row.art
  of "leibrente", "rente":
    let pct = ertragsanteilFromAge(row.lebensalterBeginn)
    result.ertragsanteilProzent = pct
    result.taxable = gross * pct / 100.0
    result.note = "§22 Nr. 1 Satz 3 a bb EStG: Ertragsanteil aus Tabelle (Lebensalter " &
                  $row.lebensalterBeginn & ")"
  of "kapital", "kapitalleistung", "einmalzahlung",
     "freizuegigkeit", "freizuegigkeitskonto":
    result.ertragsanteilProzent = 0.0
    result.taxable = 0.0
    result.note = "§22 Nr. 5 Satz 2 EStG: nur Ertragsanteil steuerbar — " &
                  "setze `ertragsanteil_prozent` oder `lebensalter_beginn` " &
                  "in rente.tsv, oder prüfe den Anteil händisch."
  else:
    result.ertragsanteilProzent = 0.0
    result.taxable = 0.0
    result.note = "unbekannte Art `" & row.art & "` — keine Steuerberechnung"

proc summarizeAll*(rows: seq[RenteRow]): seq[RenteSummary] =
  for r in rows: result.add(summarize(r))

func totalTaxable*(summaries: seq[RenteSummary]): float =
  for s in summaries: result += s.taxable
