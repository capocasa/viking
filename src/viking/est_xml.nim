## ESt XML Generation
## Generates ELSTER XML for Einkommensteuererklarung (income tax return)

import std/[strformat, strutils, tables]
import viking/[vikingconf, deductions, kap, config]

type
  ProfitEntry* = object
    label*: string   ## taetigkeit description (source profession or section name)
    profit*: float

  EstInput* = object
    conf*: VikingConf
    year*: int
    gewerbeProfits*: seq[ProfitEntry]
    freelanceProfits*: seq[ProfitEntry]
    kapTotals*: KapTotals
    deductions*: DeductionsByForm
    test*: bool
    produktVersion*: string

proc generateEst*(input: EstInput): string =
  let p = input.conf.personal
  let finanzamt = p.taxnumber[0..3]
  let bundesland = bundeslandFromSteuernummer(p.taxnumber)
  let testmerkerLine = if input.test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  # Anlage G (Gewerbebetrieb)
  var anlageG = ""
  if input.gewerbeProfits.len > 0:
    var blocks = ""
    for e in input.gewerbeProfits:
      let label = if e.label != "": e.label else: "Gewerbebetrieb"
      let profitEuro = roundEuro(e.profit)
      blocks.add(&"""
              <Betr_1_2>
                <E0800301>{label}</E0800301>
                <E0800302>{profitEuro}</E0800302>
              </Betr_1_2>""")
    anlageG = &"""
        <G>
          <Person>PersonA</Person>
          <Gew>
            <Einz_U>{blocks}
            </Einz_U>
          </Gew>
        </G>"""

  # Anlage S (Selbständige Arbeit)
  var anlageS = ""
  if input.freelanceProfits.len > 0:
    var blocks = ""
    for e in input.freelanceProfits:
      let label = if e.label != "": e.label else: "Freiberufliche Taetigkeit"
      let profitEuro = roundEuro(e.profit)
      blocks.add(&"""
            <Freiber_T>
              <E0803101>{label}</E0803101>
              <E0803202>{profitEuro}</E0803202>
            </Freiber_T>""")
    anlageS = &"""
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
    if p.lastname != "":
      allgParts.add(&"""
              <E0500108>{p.lastname}</E0500108>""")
    allgParts.add(&"""
              <E0500701>{kid.birthdate}</E0500701>""")
    if kid.familienkasse != "":
      allgParts.add(&"""
              <E0500706>{kid.familienkasse}</E0500706>""")

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

    # Kindschaftsverhältnis — A is the filer (Anlage Kind line 10
    # left, Kz 02). B is either:
    #   - the co-filing spouse (Zusammenveranlagung): K_Verh_B with
    #     E0500808 + E0500805. ERiC rule 5075 rejects K_Verh_B on
    #     Einzelveranlagung, so emit only when [spouse] is present.
    #   - the non-co-filing other parent (Einzelveranlagung):
    #     K_Verh_and_P/Ang_Pers with E0501103 (name), E0501903
    #     (Dauer) and E0501106 (Art). Required together by plausi
    #     rule 100500001; omitting them trips rule 100500048 ("nur
    #     ein Kindschaftsverhältnis … angegeben").
    let kvhA = if kid.kindschaftsverhaeltnis != "": kid.kindschaftsverhaeltnis else: "1"
    var kVerhParts = &"""
            <K_Verh_A>
              <E0500807>{kvhA}</E0500807>
              <E0500601>01.01-31.12</E0500601>
            </K_Verh_A>"""
    if input.conf.spouse.present and kid.kindschaftsverhaeltnisB != "":
      kVerhParts.add(&"""
            <K_Verh_B>
              <E0500808>{kid.kindschaftsverhaeltnisB}</E0500808>
              <E0500805>01.01-31.12</E0500805>
            </K_Verh_B>""")
    elif not input.conf.spouse.present and kid.parentBName != "":
      # E0501106 enum: only "1" (leiblich/Adoptiv) or "2" (Pflege).
      # kindschaftsverhaeltnis_b "3" (Enkel/Stief) doesn't map here;
      # fall back to "1" in that case.
      let kvhB = if kid.kindschaftsverhaeltnisB in ["1", "2"]: kid.kindschaftsverhaeltnisB
                 else: "1"
      kVerhParts.add(&"""
            <K_Verh_and_P>
              <Ang_Pers>
                <E0501103>{kid.parentBName}</E0501103>
                <E0501903>01.01-31.12</E0501903>
                <E0501106>{kvhB}</E0501106>
              </Ang_Pers>
            </K_Verh_and_P>""")
    kindParts.add(&"""
          <K_Verh>{kVerhParts}
          </K_Verh>""")

    # Child-specific deductions from deductions.tsv (matched on first word,
    # lowercased — mirrors the deduction-code prefix like `max174`).
    let kidKey = block:
      let words = kid.firstname.splitWhitespace
      if words.len > 0: words[0].toLowerAscii else: ""
    let kidDeductions = if kidKey in input.deductions.kids:
                          input.deductions.kids[kidKey]
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
  let hasKAP = kt.gains > 0 or kt.tax > 0 or kt.guenstigerpruefung or kt.sparerPauschbetrag > 0
  if hasKAP:
    var kapParts = ""

    if kt.guenstigerpruefung:
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

    if kt.sparerPauschbetrag > 0:
      kapParts.add(&"""
          <Sp_PB>
            <E1901401>{roundEuro(kt.sparerPauschbetrag)}</E1901401>
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
  let religionLine = if p.religion != "": &"""
                <E0100402>{p.religion}</E0100402>""" else: ""
  let berufLine = if p.profession != "": &"""
                <E0100403>{p.profession}</E0100403>""" else: ""

  let fullName = p.lastname & " " & p.firstname
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
                <E0100401>{p.birthdate}</E0100401>
                <E0100201>{p.lastname}</E0100201>
                <E0100301>{p.firstname}</E0100301>{religionLine}{berufLine}
                <E0101104>{p.street}</E0101104>
                <E0101206>{p.housenumber}</E0101206>
                <E0100601>{p.zip}</E0100601>
                <E0100602>{p.city}</E0100602>
              </A>
              <BV>
                <E0102102>{p.iban}</E0102102>
                <Kto_Inh>
                  <E0101601>X</E0101601>
                </Kto_Inh>
              </BV>
            </Allg>
          </ESt1A>{sonderausgaben}{agb}{kinderXml}{anlageG}{anlageS}{kapXml}{vorsorge}
          <Vorsatz>
            <Unterfallart>10</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{p.taxnumber}</StNr>
            <Zeitraum>{input.year}</Zeitraum>
            <AbsName>{fullName}</AbsName>
            <AbsStr>{p.street} {p.housenumber}</AbsStr>
            <AbsPlz>{p.zip}</AbsPlz>
            <AbsOrt>{p.city}</AbsOrt>
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
