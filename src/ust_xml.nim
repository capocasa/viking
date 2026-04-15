## USt XML Generation
## Generates ELSTER XML for Umsatzsteuererklaerung (annual VAT return)
## Uses E50 schema with USt2A form + Anlage UN

import std/[strformat]
import config

proc generateUst*(
  steuernummer: string,
  jahr: int,
  income19: float = 0.0,
  income7: float = 0.0,
  income0: float = 0.0,
  has19: bool = false,
  has7: bool = false,
  has0: bool = false,
  vorsteuer: float = 0.0,
  vorauszahlungen: float = 0.0,
  besteuerungsart: string = "2",
  name: string,
  strasse: string,
  plz: string,
  ort: string,
  test: bool,
  produktVersion: string = "0.1.0",
): string =
  ## Generate ELSTER XML for annual Umsatzsteuererklaerung (E50 schema)

  let herstellerId = HerstellerId
  let produktName = ProduktName
  let finanzamt = steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(steuernummer)
  let testmerkerLine = if test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  # Compute VAT
  let vat19 = roundCents(income19 * 0.19)
  let vat7 = roundCents(income7 * 0.07)
  let totalVat = roundCents(vat19 + vat7)
  let totalVorsteuer = roundCents(vorsteuer)
  let vorauszahlungenR = roundCents(vorauszahlungen)

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

  # Build Umsaetze section
  var umsaetze = ""
  if has19:
    umsaetze.add(&"""
            <Ums_allg>
              <E3003303>{roundEuro(income19)}</E3003303>
              <E3003304>{formatEurDE(vat19)}</E3003304>
            </Ums_allg>""")
  if has7:
    umsaetze.add(&"""
            <Ums_erm>
              <E3004401>{roundEuro(income7)}</E3004401>
              <E3004402>{formatEurDE(vat7)}</E3004402>
            </Ums_erm>""")
  umsaetze.add(&"""
            <Ums_Sum>
              <E3006001>{formatEurDE(totalVat)}</E3006001>
            </Ums_Sum>""")

  # Build Abziehbare Vorsteuer section
  var abzVoSt = ""
  if totalVorsteuer > 0:
    abzVoSt = &"""
          <Abz_VoSt>
            <Tabelle>
              <E3006201>{formatEurDE(totalVorsteuer)}</E3006201>
              <Abz_VoSt_Sum>
                <E3006901>{formatEurDE(totalVorsteuer)}</E3006901>
              </Abz_VoSt_Sum>
            </Tabelle>
          </Abz_VoSt>"""
  else:
    abzVoSt = """
          <Abz_VoSt>
            <Tabelle>
              <Abz_VoSt_Sum>
                <E3006901>0,00</E3006901>
              </Abz_VoSt_Sum>
            </Tabelle>
          </Abz_VoSt>"""

  # Vorsteuer line in Berech_USt (line 109: abziehbare Vorsteuer = E3006901)
  let vorstLine = if totalVorsteuer > 0:
    &"\n                <E3009901>{formatEurDE(totalVorsteuer)}</E3009901>"
  else: ""

  let xml = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterErklaerung</Verfahren>
    <DatenArt>USt</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L"><Ziel>{bundesland}</Ziel></Empfaenger>
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
          <ProduktVersion>{produktVersion}</ProduktVersion>
        </Hersteller>
      </NutzdatenHeader>
      <Nutzdaten>
        <E50 xmlns="http://finkonsens.de/elster/elstererklaerung/ust/e50/v{jahr}" version="{jahr}">
          <USt2A>
            <Allg>
              <Unternehmen>
                <E3000901>{name}</E3000901>
                <Adr>
                  <E3001101>{strasse}</E3001101>
                  <E3001206>{plz}</E3001206>
                  <E3001207>{ort}</E3001207>
                </Adr>
              </Unternehmen>
              <Best_Art>
                <E3002203>{besteuerungsart}</E3002203>
              </Best_Art>
            </Allg>
            <Umsaetze>
              <Tabelle>{umsaetze}
              </Tabelle>
            </Umsaetze>{abzVoSt}
            <Berech_USt>
              <Tabelle>
                <E3009201>{formatEurDE(totalVat)}</E3009201>
                <E3009801>{formatEurDE(zwischensumme)}</E3009801>{vorstLine}
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
            </Berech_USt>
          </USt2A>
          <Vorsatz>
            <Unterfallart>50</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{steuernummer}</StNr>
            <Zeitraum>{jahr}</Zeitraum>
            <AbsName>{name}</AbsName>
            <AbsStr>{strasse}</AbsStr>
            <AbsPlz>{plz}</AbsPlz>
            <AbsOrt>{ort}</AbsOrt>
            <Copyright>(C) {produktName}</Copyright>
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

  result = xml
