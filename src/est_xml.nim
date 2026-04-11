## ESt XML Generation
## Generates ELSTER XML for Einkommensteuererklarung (income tax return)

import std/[strutils, strformat, math]
import config

proc roundEuro(val: float): int =
  ## Round to full euros
  int(round(val))

proc formatEurDE(val: float): string =
  ## Format amount with German comma decimal separator (e.g. 1234,50)
  let rounded = round(val * 100) / 100
  let s = formatFloat(rounded, ffDecimal, 2)
  s.replace('.', ',')

proc generateEst*(
  steuernummer: string,
  jahr: int,
  profit: float,
  einkunftsart: string,
  herstellerId: string,
  produktName: string,
  vorname: string,
  nachname: string,
  geburtsdatum: string,
  strasse: string,
  hausnummer: string,
  plz: string,
  ort: string,
  iban: string,
  religion: string = "11",
  beruf: string = "",
  krankenversicherung: float = 0.0,
  pflegeversicherung: float = 0.0,
  rentenversicherung: float = 0.0,
  kvArt: string = "privat",
  test: bool,
): string =
  ## Generate ELSTER XML for ESt (Einkommensteuererklarung)

  let finanzamt = steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(steuernummer)
  let testmerkerLine = if test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  let profitEuro = roundEuro(profit)

  # Build Anlage G or Anlage S based on einkunftsart
  var anlage = ""
  if einkunftsart == "2":
    # Anlage G - Gewerbebetrieb
    let taetigkeitStr = if beruf != "": beruf else: "Gewerbebetrieb"
    anlage = &"""
        <G>
          <Person>PersonA</Person>
          <Gew>
            <Einz_U>
              <Betr_1_2>
                <E0800301>{taetigkeitStr}</E0800301>
                <E0800302>{profitEuro}</E0800302>
              </Betr_1_2>
            </Einz_U>
          </Gew>
        </G>"""
  else:
    # Anlage S - Selbstaendige Arbeit
    let taetigkeitStr = if beruf != "": beruf else: "Freiberufliche Taetigkeit"
    anlage = &"""
        <S>
          <Person>PersonA</Person>
          <Gewinn>
            <Freiber_T>
              <E0803101>{taetigkeitStr}</E0803101>
              <E0803202>{profitEuro}</E0803202>
            </Freiber_T>
          </Gewinn>
        </S>"""

  # Build Anlage Vorsorgeaufwand if any insurance amounts provided
  var vorsorge = ""
  let hasVorsorge = krankenversicherung > 0 or pflegeversicherung > 0 or rentenversicherung > 0
  if hasVorsorge:
    var vorParts = ""

    # Retirement insurance (Rentenversicherung)
    if rentenversicherung > 0:
      vorParts.add(&"""
          <AVor>
            <Person>PersonA</Person>
            <E2000601>{roundEuro(rentenversicherung)}</E2000601>
          </AVor>""")

    # Health/nursing insurance
    if krankenversicherung > 0 or pflegeversicherung > 0:
      if kvArt == "gesetzlich":
        # Freiwillig gesetzlich versichert
        var andPers = ""
        if krankenversicherung > 0:
          andPers.add(&"""
              <E2001805>{roundEuro(krankenversicherung)}</E2001805>""")
        if pflegeversicherung > 0:
          andPers.add(&"""
              <E2002105>{roundEuro(pflegeversicherung)}</E2002105>""")
        vorParts.add(&"""
          <Beitr_g_KV_PV_Inl>
            <Person>PersonA</Person>
            <And_Pers>{andPers}
            </And_Pers>
          </Beitr_g_KV_PV_Inl>""")
      else:
        # Privat versichert
        var privParts = ""
        if krankenversicherung > 0:
          privParts.add(&"""
              <E2003104>{roundEuro(krankenversicherung)}</E2003104>""")
        if pflegeversicherung > 0:
          privParts.add(&"""
              <E2003202>{roundEuro(pflegeversicherung)}</E2003202>""")
        vorParts.add(&"""
          <Beitr_p_KV_PV_Inl>
            <Person>PersonA</Person>{privParts}
          </Beitr_p_KV_PV_Inl>""")

    vorsorge = &"""
        <VOR>{vorParts}
        </VOR>"""

  # Optional fields (must follow XSD element order)
  let religionLine = if religion != "": &"""
                <E0100402>{religion}</E0100402>""" else: ""
  let berufLine = if beruf != "": &"""
                <E0100403>{beruf}</E0100403>""" else: ""

  let fullName = nachname & " " & vorname

  let xml = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterErklaerung</Verfahren>
    <DatenArt>ESt</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L"><Ziel>{bundesland}</Ziel></Empfaenger>
    <HerstellerID>{herstellerId}</HerstellerID>
    <DatenLieferant>{fullName}</DatenLieferant>
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
        <E10 xmlns="http://finkonsens.de/elster/elstererklaerung/est/e10/v{jahr}" version="{jahr}">
          <ESt1A>
            <Art_Erkl>
              <E0100001>X</E0100001>
            </Art_Erkl>
            <Allg>
              <A>
                <E0100401>{geburtsdatum}</E0100401>
                <E0100201>{nachname}</E0100201>
                <E0100301>{vorname}</E0100301>{religionLine}{berufLine}
                <E0101104>{strasse}</E0101104>
                <E0101206>{hausnummer}</E0101206>
                <E0100601>{plz}</E0100601>
                <E0100602>{ort}</E0100602>
              </A>
              <BV>
                <E0102102>{iban}</E0102102>
                <Kto_Inh>
                  <E0101601>X</E0101601>
                </Kto_Inh>
              </BV>
            </Allg>
          </ESt1A>{anlage}{vorsorge}
          <Vorsatz>
            <Unterfallart>10</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{steuernummer}</StNr>
            <Zeitraum>{jahr}</Zeitraum>
            <AbsName>{fullName}</AbsName>
            <AbsStr>{strasse} {hausnummer}</AbsStr>
            <AbsPlz>{plz}</AbsPlz>
            <AbsOrt>{ort}</AbsOrt>
            <Copyright>(C) {produktName}</Copyright>
            <OrdNrArt>S</OrdNrArt>
            <Rueckuebermittlung>
              <Bescheid>2</Bescheid>
            </Rueckuebermittlung>
          </Vorsatz>
        </E10>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""

  result = xml
