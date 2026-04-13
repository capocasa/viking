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

type
  ChildData* = object
    vorname*: string
    nachname*: string
    geburtsdatum*: string
    idnr*: string
    betreuungskosten*: float
    schulgeld*: float

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
  zusatzKv: float = 0.0,
  kfzHaftpflicht: float = 0.0,
  unfallversicherung: float = 0.0,
  kirchensteuerGezahlt: float = 0.0,
  kirchensteuerErstattet: float = 0.0,
  spenden: float = 0.0,
  agbKrankheit: float = 0.0,
  kapitalertraege: float = 0.0,
  kapitalertragsteuer: float = 0.0,
  kapSoli: float = 0.0,
  sparerPauschbetrag: float = 0.0,
  guenstigerpruefung: bool = false,
  kinder: seq[ChildData] = @[],
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

  # Build Anlage Vorsorgeaufwand
  var vorsorge = ""
  let sonstigeVorsorge = kfzHaftpflicht + unfallversicherung
  let hasVorsorge = krankenversicherung > 0 or pflegeversicherung > 0 or
                    rentenversicherung > 0 or sonstigeVorsorge > 0 or zusatzKv > 0
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
    if krankenversicherung > 0 or pflegeversicherung > 0 or zusatzKv > 0:
      if kvArt == "gesetzlich":
        # Freiwillig gesetzlich versichert
        var andPers = ""
        if krankenversicherung > 0:
          andPers.add(&"""
              <E2001805>{roundEuro(krankenversicherung)}</E2001805>""")
        if zusatzKv > 0:
          andPers.add(&"""
              <E2002206>{roundEuro(zusatzKv)}</E2002206>""")
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
        if zusatzKv > 0:
          privParts.add(&"""
              <E2003302>{roundEuro(zusatzKv)}</E2003302>""")
        vorParts.add(&"""
          <Beitr_p_KV_PV_Inl>
            <Person>PersonA</Person>{privParts}
          </Beitr_p_KV_PV_Inl>""")

    # Weitere sonstige Vorsorgeaufwendungen (Haftpflicht, Unfall)
    if sonstigeVorsorge > 0:
      vorParts.add(&"""
          <Weit_Sons_VorAW>
            <A_B_LP>
              <U_HP_Ris_Vers>
                <Sum>
                  <E2001803>{roundEuro(sonstigeVorsorge)}</E2001803>
                </Sum>
              </U_HP_Ris_Vers>
            </A_B_LP>
          </Weit_Sons_VorAW>""")

    vorsorge = &"""
        <VOR>{vorParts}
        </VOR>"""

  # Build Anlage Sonderausgaben (SA)
  var sonderausgaben = ""
  let hasSA = kirchensteuerGezahlt > 0 or kirchensteuerErstattet > 0 or spenden > 0
  if hasSA:
    var saParts = ""

    # Kirchensteuer
    if kirchensteuerGezahlt > 0 or kirchensteuerErstattet > 0:
      var kistParts = ""
      if kirchensteuerGezahlt > 0:
        kistParts.add(&"""
            <Gezahlt>
              <Sum>
                <E0107601>{roundEuro(kirchensteuerGezahlt)}</E0107601>
              </Sum>
            </Gezahlt>""")
      if kirchensteuerErstattet > 0:
        kistParts.add(&"""
            <Erstattet>
              <E0107602>{roundEuro(kirchensteuerErstattet)}</E0107602>
            </Erstattet>""")
      saParts.add(&"""
          <KiSt>{kistParts}
          </KiSt>""")

    # Spenden / Zuwendungen
    if spenden > 0:
      saParts.add(&"""
          <Zuw>
            <Sp_MB>
              <Foerd_st_beg_Zw_Inl>
                <Sum_Best>
                  <E0108105>{roundEuro(spenden)}</E0108105>
                </Sum_Best>
              </Foerd_st_beg_Zw_Inl>
            </Sp_MB>
          </Zuw>""")

    sonderausgaben = &"""
        <SA>{saParts}
        </SA>"""

  # Build Anlage Außergewöhnliche Belastungen (AgB)
  var agb = ""
  if agbKrankheit > 0:
    agb = &"""
        <AgB>
          <And_Aufw>
            <Krankh>
              <Sum>
                <E0161304>{roundEuro(agbKrankheit)}</E0161304>
              </Sum>
            </Krankh>
          </And_Aufw>
        </AgB>"""

  # Build Anlage Kind (one per child)
  var kinderXml = ""
  for child in kinder:
    var kindParts = ""

    # Basic child info
    var allgParts = ""
    if child.idnr != "":
      allgParts.add(&"""
              <E0500406>{child.idnr}</E0500406>""")
    allgParts.add(&"""
              <E0500107>{child.vorname}</E0500107>""")
    if child.nachname != "":
      allgParts.add(&"""
              <E0500108>{child.nachname}</E0500108>""")
    allgParts.add(&"""
              <E0500701>{child.geburtsdatum}</E0500701>""")

    kindParts.add(&"""
          <Ang_Kind>
            <Allg>{allgParts}
            </Allg>
            <WS>
              <Inl>
                <E0500703>01.01-31.12</E0500703>
              </Inl>
            </WS>
          </Ang_Kind>""")

    # Kindschaftsverhältnis
    kindParts.add(&"""
          <K_Verh>
            <K_Verh_A>
              <E0500807>1</E0500807>
              <E0500601>01.01-31.12</E0500601>
            </K_Verh_A>
          </K_Verh>""")

    # Kinderbetreuungskosten
    if child.betreuungskosten > 0:
      let betrag = roundEuro(child.betreuungskosten)
      kindParts.add(&"""
          <KBK>
            <Art>
              <Sum>
                <E0506105>{betrag}</E0506105>
              </Sum>
            </Art>
          </KBK>""")

    # Schulgeld
    if child.schulgeld > 0:
      let betrag = roundEuro(child.schulgeld)
      kindParts.add(&"""
          <Schulgeld>
            <Sum>
              <E0505607>{betrag}</E0505607>
            </Sum>
          </Schulgeld>""")

    kinderXml.add(&"""
        <Kind>{kindParts}
        </Kind>""")

  # Build Anlage KAP
  var kap = ""
  let hasKAP = kapitalertraege > 0 or kapitalertragsteuer > 0 or guenstigerpruefung or
               sparerPauschbetrag > 0
  if hasKAP:
    var kapParts = ""

    # Günstigerprüfung
    if guenstigerpruefung:
      kapParts.add(&"""
          <Ant>
            <E1900401>1</E1900401>
          </Ant>""")

    # Kapitalerträge (dem inländischen Steuerabzug unterlegen)
    if kapitalertraege > 0:
      kapParts.add(&"""
          <KapErt_inl_StAbz>
            <Betr_lt_StBesch>
              <E1900701>{roundEuro(kapitalertraege)}</E1900701>
            </Betr_lt_StBesch>
          </KapErt_inl_StAbz>""")

    # Sparer-Pauschbetrag (required when Günstigerprüfung is set)
    if sparerPauschbetrag > 0:
      kapParts.add(&"""
          <Sp_PB>
            <E1901401>{roundEuro(sparerPauschbetrag)}</E1901401>
          </Sp_PB>""")

    # Steuerabzugsbeträge
    if kapitalertragsteuer > 0 or kapSoli > 0:
      var stParts = ""
      if kapitalertragsteuer > 0:
        stParts.add(&"""
              <E1904701>{formatEurDE(kapitalertragsteuer)}</E1904701>""")
      if kapSoli > 0:
        stParts.add(&"""
              <E1904801>{formatEurDE(kapSoli)}</E1904801>""")
      kapParts.add(&"""
          <St_Abz_Betr_Inl_u_Inv_Ert>{stParts}
          </St_Abz_Betr_Inl_u_Inv_Ert>""")

    kap = &"""
        <KAP>
          <Person>PersonA</Person>{kapParts}
        </KAP>"""

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
          </ESt1A>{sonderausgaben}{agb}{kinderXml}{anlage}{kap}{vorsorge}
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
