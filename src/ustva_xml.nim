## UStVA XML Generation
## Generates ELSTER XML for Umsatzsteuervoranmeldung

import std/[strutils, strformat, math, times, options]

proc roundCents(val: float): float =
  ## Round to 2 decimal places (cents)
  round(val * 100) / 100

proc formatAmount(val: float): string =
  ## Format amount for XML (2 decimal places, no thousands separator)
  formatFloat(roundCents(val), ffDecimal, 2)

proc formatAmountInt(val: float): string =
  ## Format amount as integer (no decimal places) for base amounts
  $int(round(val))

proc generateUstva*(
  steuernummer: string,
  jahr: int,
  zeitraum: string,
  kz81: Option[float] = none(float),
  kz86: Option[float] = none(float),
  herstellerId: string,
  produktName: string,
  name: string,
  strasse: string,
  plz: string,
  ort: string,
): string =
  ## Generate ELSTER XML for Umsatzsteuervoranmeldung
  ##
  ## Parameters:
  ##   steuernummer: Tax number (13 digits, format varies by state)
  ##   jahr: Tax year (e.g., 2025)
  ##   zeitraum: Period - "01"-"12" for monthly, "41"-"44" for quarterly
  ##   kz81: Net amount at 19% rate (Kennzahl 81), none if not specified
  ##   kz86: Net amount at 7% rate (Kennzahl 86), none if not specified
  ##
  ## Returns:
  ##   Complete ELSTER XML document as string

  # Extract amounts (0 if not provided)
  let amt81 = kz81.get(0.0)
  let amt86 = kz86.get(0.0)

  # Calculate VAT amounts
  let vat19 = roundCents(amt81 * 0.19)
  let vat7 = roundCents(amt86 * 0.07)

  # Kz83 is the total VAT (sum of 19% and 7% VAT)
  let kz83 = roundCents(vat19 + vat7)

  # Build Kennzahlen elements - include if explicitly provided (even if 0)
  var kennzahlen = ""

  if kz81.isSome:
    kennzahlen.add(&"              <Kz81>{formatAmountInt(amt81)}</Kz81>\n")

  if kz86.isSome:
    kennzahlen.add(&"              <Kz86>{formatAmountInt(amt86)}</Kz86>\n")

  # Always include Kz83 (total VAT) if any amount was specified
  if kz81.isSome or kz86.isSome:
    kennzahlen.add(&"              <Kz83>{formatAmount(kz83)}</Kz83>\n")

  # Remove trailing newline from kennzahlen
  if kennzahlen.len > 0 and kennzahlen[^1] == '\n':
    kennzahlen = kennzahlen[0..^2]

  # Extract Finanzamt number (first 4 digits of Steuernummer)
  let finanzamt = steuernummer[0..3]

  let xml = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterAnmeldung</Verfahren>
    <DatenArt>UStVA</DatenArt>
    <Vorgang>send-Auth</Vorgang>
    <Testmerker>700000004</Testmerker>
    <HerstellerID>{herstellerId}</HerstellerID>
    <DatenLieferant>{name}</DatenLieferant>
    <Datei>
      <Verschluesselung>CMSEncryptedData</Verschluesselung>
      <Kompression>GZIP</Kompression>
      <TransportSchluessel></TransportSchluessel>
    </Datei>
  </TransferHeader>
  <DatenTeil>
    <Nutzdatenblock>
      <NutzdatenHeader version="11">
        <NutzdatenTicket>1</NutzdatenTicket>
        <Empfaenger id="F">{finanzamt}</Empfaenger>
        <Hersteller>
          <ProduktName>{produktName}</ProduktName>
          <ProduktVersion>0.1.0</ProduktVersion>
        </Hersteller>
      </NutzdatenHeader>
      <Nutzdaten>
        <Anmeldungssteuern version="{jahr}" xmlns="http://finkonsens.de/elster/elsteranmeldung/ustva/v{jahr}">
          <Erstellungsdatum>{now().format("yyyyMMdd")}</Erstellungsdatum>
          <DatenLieferant>
            <Name>{name}</Name>
            <Strasse>{strasse}</Strasse>
            <PLZ>{plz}</PLZ>
            <Ort>{ort}</Ort>
          </DatenLieferant>
          <Steuerfall>
            <Umsatzsteuervoranmeldung>
              <Jahr>{jahr}</Jahr>
              <Zeitraum>{zeitraum}</Zeitraum>
              <Steuernummer>{steuernummer}</Steuernummer>
              <Kz09>{herstellerId}</Kz09>
{kennzahlen}
            </Umsatzsteuervoranmeldung>
          </Steuerfall>
        </Anmeldungssteuern>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""

  result = xml

proc isValidPeriod*(period: string): bool =
  ## Check if period is valid (01-12 for monthly, 41-44 for quarterly)
  if period.len != 2:
    return false

  try:
    let p = parseInt(period)
    # Monthly: 01-12, Quarterly: 41-44
    result = (p >= 1 and p <= 12) or (p >= 41 and p <= 44)
  except ValueError:
    result = false

proc periodDescription*(period: string): string =
  ## Get human-readable description of period
  if not isValidPeriod(period):
    return "Invalid period"

  let p = parseInt(period)
  if p >= 1 and p <= 12:
    const months = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December"]
    result = months[p - 1]
  else:
    result = "Q" & $(p - 40)
