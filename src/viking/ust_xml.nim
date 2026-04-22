## USt XML Generation
## Generates ELSTER XML for Umsatzsteuererklaerung (annual VAT return)
## Uses E50 schema with USt2A form + Anlage UN

import std/[strformat]
import viking/config

type
  UstInput* = object
    steuernummer*: string
    jahr*: int
    income19*: float
    income7*: float
    income0*: float
    has19*: bool
    has7*: bool
    has0*: bool
    vorsteuer*: float
    vorauszahlungen*: float
    besteuerungsart*: string
    name*: string
    strasse*: string
    plz*: string
    ort*: string
    test*: bool
    produktVersion*: string

func generateUst*(input: UstInput): string =
  ## Generate ELSTER XML for annual Umsatzsteuererklaerung (E50 schema)
  let i = input
  let produktVersion = if i.produktVersion != "": i.produktVersion else: "0.1.0"
  let finanzamt = i.steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(i.steuernummer)
  let testmerkerLine = if i.test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  let vat19 = roundCents(i.income19 * 0.19)
  let vat7 = roundCents(i.income7 * 0.07)
  let totalVat = roundCents(vat19 + vat7)
  let totalVorsteuer = roundCents(i.vorsteuer)
  let vorauszahlungenR = roundCents(i.vorauszahlungen)

  # Berech_USt calculation chain (USt 2A form Part III):
  # E3009201 (line 103): USt from taxable revenue = Ums_Sum E3006001
  # E3009801 (line 108): Zwischensumme = sum of lines 103-107
  # E3010201 (line 111): verbleibend = E3009801 (no corrections)
  # E3010301 (line 112): abziehbare Vorsteuer = Abz_VoSt_Sum E3006901
  # E3010601 (line 116): USt/Überschuss = E3010201 - E3010301
  # E3010602 (line 117): anrechenbare Beträge Anlage UN = E3201902
  # E3011101 (line 118): verbleibende USt = E3010601 - E3010602
  # E3011301 (line 119): Vorauszahlungssoll = Anlage UN E3201902
  # E3011401 (line 120): Abschlusszahlung = E3011101 - E3011301
  let zwischensumme = totalVat
  let nachVorsteuer = roundCents(zwischensumme - totalVorsteuer)
  let verbleibendeUst = nachVorsteuer
  let abschluss = roundCents(verbleibendeUst - vorauszahlungenR)

  # Plausibility rules USt_30900/30901 require Ums_Sum/Abz_VoSt_Sum to have
  # siblings: emit the Sum blocks only when there are underlying entries.
  let hasUmsaetze = i.has19 or i.has7
  let hasVorsteuer = totalVorsteuer > 0

  var umsaetzeBlock = ""
  if hasUmsaetze:
    var umsaetze = ""
    if i.has19:
      umsaetze.add(&"""
            <Ums_allg>
              <E3003303>{roundEuro(i.income19)}</E3003303>
              <E3003304>{formatEurDE(vat19)}</E3003304>
            </Ums_allg>""")
    if i.has7:
      umsaetze.add(&"""
            <Ums_erm>
              <E3004401>{roundEuro(i.income7)}</E3004401>
              <E3004402>{formatEurDE(vat7)}</E3004402>
            </Ums_erm>""")
    umsaetze.add(&"""
            <Ums_Sum>
              <E3006001>{formatEurDE(totalVat)}</E3006001>
            </Ums_Sum>""")
    umsaetzeBlock = &"""
            <Umsaetze>
              <Tabelle>{umsaetze}
              </Tabelle>
            </Umsaetze>"""

  var abzVoSt = ""
  if hasVorsteuer:
    abzVoSt = &"""
            <Abz_VoSt>
              <Tabelle>
                <E3006201>{formatEurDE(totalVorsteuer)}</E3006201>
                <Abz_VoSt_Sum>
                  <E3006901>{formatEurDE(totalVorsteuer)}</E3006901>
                </Abz_VoSt_Sum>
              </Tabelle>
            </Abz_VoSt>"""

  # USt_30150 requires Abz_VoSt_Sum → E3009901 transfer; only emit when present.
  let vorstLine = if hasVorsteuer:
    &"\n                <E3009901>{formatEurDE(totalVorsteuer)}</E3009901>"
  else: ""
  let ustLine = if hasUmsaetze:
    &"\n                <E3009201>{formatEurDE(totalVat)}</E3009201>"
  else: ""
  let zwischenLine = if hasUmsaetze:
    &"\n                <E3009801>{formatEurDE(zwischensumme)}</E3009801>"
  else: ""

  # Berech_USt chain requires upstream sums; USt_30907 fires if E3010201 is
  # declared without any 108–110 input. For a pure Nullmeldung omit it; for
  # Vorsteuer-only file the overhang without E3009201/E3009801.
  var berechUst = ""
  if hasUmsaetze or hasVorsteuer:
    berechUst = &"""

            <Berech_USt>
              <Tabelle>{ustLine}{zwischenLine}{vorstLine}
                <E3010201>{formatEurDE(nachVorsteuer)}</E3010201>
                <E3010601>{formatEurDE(nachVorsteuer)}</E3010601>
                <Verbl_USt>
                  <E3011101>{formatEurDE(verbleibendeUst)}</E3011101>
                  <E3011301>{formatEurDE(vorauszahlungenR)}</E3011301>
                </Verbl_USt>
                <Zahl_Erstatt>
                  <E3011401>{formatEurDE(abschluss)}</E3011401>
                </Zahl_Erstatt>
              </Tabelle>
            </Berech_USt>"""

  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterErklaerung</Verfahren>
    <DatenArt>USt</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L"><Ziel>{bundesland}</Ziel></Empfaenger>
    <HerstellerID>{HerstellerId}</HerstellerID>
    <DatenLieferant>{i.name}</DatenLieferant>
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
          <ProduktName>{ProduktName}</ProduktName>
          <ProduktVersion>{produktVersion}</ProduktVersion>
        </Hersteller>
      </NutzdatenHeader>
      <Nutzdaten>
        <E50 xmlns="http://finkonsens.de/elster/elstererklaerung/ust/e50/v{i.jahr}" version="{i.jahr}">
          <USt2A>
            <Allg>
              <Unternehmen>
                <E3000901>{i.name}</E3000901>
                <Adr>
                  <E3001101>{i.strasse}</E3001101>
                  <E3001206>{i.plz}</E3001206>
                  <E3001207>{i.ort}</E3001207>
                </Adr>
              </Unternehmen>
              <Best_Art>
                <E3002203>{i.besteuerungsart}</E3002203>
              </Best_Art>
            </Allg>
{umsaetzeBlock}{abzVoSt}{berechUst}
          </USt2A>
          <Vorsatz>
            <Unterfallart>50</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{i.steuernummer}</StNr>
            <Zeitraum>{i.jahr}</Zeitraum>
            <AbsName>{i.name}</AbsName>
            <AbsStr>{i.strasse}</AbsStr>
            <AbsPlz>{i.plz}</AbsPlz>
            <AbsOrt>{i.ort}</AbsOrt>
            <Copyright>{Copyright}</Copyright>
            <OrdNrArt>S</OrdNrArt>
            <Rueckuebermittlung>
              <Bescheid>2</Bescheid>
            </Rueckuebermittlung>
          </Vorsatz>
        </E50>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""
