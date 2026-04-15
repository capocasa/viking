## ESt XML Generation
## Generates ELSTER XML for Einkommensteuererklarung (income tax return)

import std/[strformat, tables]
import viking_conf, deductions, kap, config

type
  EstInput* = object
    conf*: VikingConf
    year*: int
    profits*: seq[float]
    deductions*: DeductionsByForm
    kapTotals*: KapTotals
    test*: bool
    produktVersion*: string

proc generateEst*(input: EstInput): string =
  let tp = input.conf.taxpayer
  let finanzamt = tp.taxnumber[0..3]
  let bundesland = bundeslandFromSteuernummer(tp.taxnumber)
  let testmerkerLine = if input.test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  # Build Anlage G or Anlage S (one block per income source)
  var anlage = ""
  if input.profits.len > 0:
    if tp.income == "2":
      let taetigkeitStr = if tp.profession != "": tp.profession else: "Gewerbebetrieb"
      var blocks = ""
      for profit in input.profits:
        let profitEuro = roundEuro(profit)
        blocks.add(&"""
              <Betr_1_2>
                <E0800301>{taetigkeitStr}</E0800301>
                <E0800302>{profitEuro}</E0800302>
              </Betr_1_2>""")
      anlage = &"""
        <G>
          <Person>PersonA</Person>
          <Gew>
            <Einz_U>{blocks}
            </Einz_U>
          </Gew>
        </G>"""
    else:
      let taetigkeitStr = if tp.profession != "": tp.profession else: "Freiberufliche Taetigkeit"
      var blocks = ""
      for profit in input.profits:
        let profitEuro = roundEuro(profit)
        blocks.add(&"""
            <Freiber_T>
              <E0803101>{taetigkeitStr}</E0803101>
              <E0803202>{profitEuro}</E0803202>
            </Freiber_T>""")
      anlage = &"""
        <S>
          <Person>PersonA</Person>
          <Gewinn>{blocks}
          </Gewinn>
        </S>"""

  # Build Anlage Vorsorgeaufwand (VOR) from deductions table
  var vorsorge = ""
  let vor = input.deductions.vor
  if vor.len > 0:
    var vorParts = ""

    # AVor — Rentenversicherung (E2000601)
    if "E2000601" in vor:
      vorParts.add(&"""
          <AVor>
            <Person>PersonA</Person>
            <E2000601>{roundEuro(vor["E2000601"])}</E2000601>
          </AVor>""")

    # Health/nursing insurance — gesetzlich vs privat
    let hasGesetzlich = "E2001805" in vor or "E2002105" in vor or "E2002206" in vor
    let hasPrivat = "E2003104" in vor or "E2003202" in vor or "E2003302" in vor

    if hasGesetzlich:
      var andPers = ""
      if "E2001805" in vor:
        andPers.add(&"""
              <E2001805>{roundEuro(vor["E2001805"])}</E2001805>""")
      if "E2002105" in vor:
        andPers.add(&"""
              <E2002105>{roundEuro(vor["E2002105"])}</E2002105>""")
      if "E2002206" in vor:
        andPers.add(&"""
              <E2002206>{roundEuro(vor["E2002206"])}</E2002206>""")
      vorParts.add(&"""
          <Beitr_g_KV_PV_Inl>
            <Person>PersonA</Person>
            <And_Pers>{andPers}
            </And_Pers>
          </Beitr_g_KV_PV_Inl>""")

    if hasPrivat:
      var privParts = ""
      if "E2003104" in vor:
        privParts.add(&"""
              <E2003104>{roundEuro(vor["E2003104"])}</E2003104>""")
      if "E2003202" in vor:
        privParts.add(&"""
              <E2003202>{roundEuro(vor["E2003202"])}</E2003202>""")
      if "E2003302" in vor:
        privParts.add(&"""
              <E2003302>{roundEuro(vor["E2003302"])}</E2003302>""")
      vorParts.add(&"""
          <Beitr_p_KV_PV_Inl>
            <Person>PersonA</Person>{privParts}
          </Beitr_p_KV_PV_Inl>""")

    # Weitere sonstige Vorsorgeaufwendungen (E2001803)
    if "E2001803" in vor:
      vorParts.add(&"""
          <Weit_Sons_VorAW>
            <A_B_LP>
              <U_HP_Ris_Vers>
                <Sum>
                  <E2001803>{roundEuro(vor["E2001803"])}</E2001803>
                </Sum>
              </U_HP_Ris_Vers>
            </A_B_LP>
          </Weit_Sons_VorAW>""")

    vorsorge = &"""
        <VOR>{vorParts}
        </VOR>"""

  # Build Anlage Sonderausgaben (SA)
  var sonderausgaben = ""
  let sa = input.deductions.sa
  if sa.len > 0:
    var saParts = ""

    # Kirchensteuer
    let hasKist = "E0107601" in sa or "E0107602" in sa
    if hasKist:
      var kistParts = ""
      if "E0107601" in sa:
        kistParts.add(&"""
            <Gezahlt>
              <Sum>
                <E0107601>{roundEuro(sa["E0107601"])}</E0107601>
              </Sum>
            </Gezahlt>""")
      if "E0107602" in sa:
        kistParts.add(&"""
            <Erstattet>
              <E0107602>{roundEuro(sa["E0107602"])}</E0107602>
            </Erstattet>""")
      saParts.add(&"""
          <KiSt>{kistParts}
          </KiSt>""")

    # Spenden
    if "E0108105" in sa:
      saParts.add(&"""
          <Zuw>
            <Sp_MB>
              <Foerd_st_beg_Zw_Inl>
                <Sum_Best>
                  <E0108105>{roundEuro(sa["E0108105"])}</E0108105>
                </Sum_Best>
              </Foerd_st_beg_Zw_Inl>
            </Sp_MB>
          </Zuw>""")

    sonderausgaben = &"""
        <SA>{saParts}
        </SA>"""

  # Build Anlage Außergewöhnliche Belastungen (AgB)
  var agb = ""
  let agbT = input.deductions.agb
  if "E0161304" in agbT:
    agb = &"""
        <AgB>
          <And_Aufw>
            <Krankh>
              <Sum>
                <E0161304>{roundEuro(agbT["E0161304"])}</E0161304>
              </Sum>
            </Krankh>
          </And_Aufw>
        </AgB>"""

  # Build Anlage Kind (one per child from conf)
  var kinderXml = ""
  for kid in input.conf.kids:
    var kindParts = ""

    # Basic child info
    var allgParts = ""
    if kid.idnr != "":
      allgParts.add(&"""
              <E0500406>{kid.idnr}</E0500406>""")
    allgParts.add(&"""
              <E0500107>{kid.firstname}</E0500107>""")
    if tp.lastname != "":
      allgParts.add(&"""
              <E0500108>{tp.lastname}</E0500108>""")
    allgParts.add(&"""
              <E0500701>{kid.birthdate}</E0500701>""")

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

    # Child-specific deductions from deductions.tsv
    let kidDeductions = if kid.firstname in input.deductions.kids:
                          input.deductions.kids[kid.firstname]
                        else:
                          initTable[string, float]()

    # Kinderbetreuungskosten (E0506105)
    if "E0506105" in kidDeductions:
      let betrag = roundEuro(kidDeductions["E0506105"])
      kindParts.add(&"""
          <KBK>
            <Art>
              <Sum>
                <E0506105>{betrag}</E0506105>
              </Sum>
            </Art>
          </KBK>""")

    # Schulgeld (E0505607)
    if "E0505607" in kidDeductions:
      let betrag = roundEuro(kidDeductions["E0505607"])
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
  var kapXml = ""
  let kt = input.kapTotals
  let kc = input.conf.kap
  let hasKAP = kt.gains > 0 or kt.tax > 0 or kc.guenstigerpruefung or kc.sparerPauschbetrag > 0
  if hasKAP:
    var kapParts = ""

    if kc.guenstigerpruefung:
      kapParts.add(&"""
          <Ant>
            <E1900401>1</E1900401>
          </Ant>""")

    if kt.gains > 0:
      kapParts.add(&"""
          <KapErt_inl_StAbz>
            <Betr_lt_StBesch>
              <E1900701>{roundEuro(kt.gains)}</E1900701>
            </Betr_lt_StBesch>
          </KapErt_inl_StAbz>""")

    if kc.sparerPauschbetrag > 0:
      kapParts.add(&"""
          <Sp_PB>
            <E1901401>{roundEuro(kc.sparerPauschbetrag)}</E1901401>
          </Sp_PB>""")

    if kt.tax > 0 or kt.soli > 0:
      var stParts = ""
      if kt.tax > 0:
        stParts.add(&"""
              <E1904701>{formatEurDE(kt.tax)}</E1904701>""")
      if kt.soli > 0:
        stParts.add(&"""
              <E1904801>{formatEurDE(kt.soli)}</E1904801>""")
      kapParts.add(&"""
          <St_Abz_Betr_Inl_u_Inv_Ert>{stParts}
          </St_Abz_Betr_Inl_u_Inv_Ert>""")

    kapXml = &"""
        <KAP>
          <Person>PersonA</Person>{kapParts}
        </KAP>"""

  # Personal fields
  let religionLine = if tp.religion != "": &"""
                <E0100402>{tp.religion}</E0100402>""" else: ""
  let berufLine = if tp.profession != "": &"""
                <E0100403>{tp.profession}</E0100403>""" else: ""

  let fullName = tp.lastname & " " & tp.firstname
  let produktVersion = if input.produktVersion != "": input.produktVersion else: "0.1.0"

  let xml = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterErklaerung</Verfahren>
    <DatenArt>ESt</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L"><Ziel>{bundesland}</Ziel></Empfaenger>
    <HerstellerID>{HerstellerId}</HerstellerID>
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
          <ProduktName>{ProduktName}</ProduktName>
          <ProduktVersion>{produktVersion}</ProduktVersion>
        </Hersteller>
      </NutzdatenHeader>
      <Nutzdaten>
        <E10 xmlns="http://finkonsens.de/elster/elstererklaerung/est/e10/v{input.year}" version="{input.year}">
          <ESt1A>
            <Art_Erkl>
              <E0100001>X</E0100001>
            </Art_Erkl>
            <Allg>
              <A>
                <E0100401>{tp.birthdate}</E0100401>
                <E0100201>{tp.lastname}</E0100201>
                <E0100301>{tp.firstname}</E0100301>{religionLine}{berufLine}
                <E0101104>{tp.street}</E0101104>
                <E0101206>{tp.housenumber}</E0101206>
                <E0100601>{tp.zip}</E0100601>
                <E0100602>{tp.city}</E0100602>
              </A>
              <BV>
                <E0102102>{tp.iban}</E0102102>
                <Kto_Inh>
                  <E0101601>X</E0101601>
                </Kto_Inh>
              </BV>
            </Allg>
          </ESt1A>{sonderausgaben}{agb}{kinderXml}{anlage}{kapXml}{vorsorge}
          <Vorsatz>
            <Unterfallart>10</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{tp.taxnumber}</StNr>
            <Zeitraum>{input.year}</Zeitraum>
            <AbsName>{fullName}</AbsName>
            <AbsStr>{tp.street} {tp.housenumber}</AbsStr>
            <AbsPlz>{tp.zip}</AbsPlz>
            <AbsOrt>{tp.city}</AbsOrt>
            <Copyright>(C) {ProduktName}</Copyright>
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
