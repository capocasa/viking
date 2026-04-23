## ESt XML Generation
## Generates ELSTER XML for Einkommensteuererklarung (income tax return)

import std/[strformat, strutils, tables]
import viking/[vikingconf, deductions, kap, config, rente]

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
    rente*: seq[RenteSummary]
    test*: bool
    produktVersion*: string

  RenteEmitWarning* = object
    zahler*: string
    reason*: string

func isDomestic(land: string): bool =
  let l = land.strip.toUpperAscii
  l == "" or l == "DE"

proc classifyRente*(summaries: seq[RenteSummary]):
    tuple[domesticLeibr, foreignLeibr, foreignKapital: seq[RenteSummary],
          warnings: seq[RenteEmitWarning]] =
  ## Partition rente rows into the three XML buckets we support. Cases we
  ## can't route (gefördert, domestic Kapitalleistungen, unknown art) get a
  ## warning and are left out of the XML — the filer still sees the log
  ## summary and can file those lines manually.
  for s in summaries:
    let r = s.row
    let dom = isDomestic(r.herkunftsland)
    if r.gefoerdert:
      result.warnings.add RenteEmitWarning(zahler: r.zahler,
        reason: "gefördert (Riester/Rürup/bAV) — manuell in Anlage R-AV/bAV eintragen")
      continue
    case r.art
    of "leibrente", "rente":
      if dom: result.domesticLeibr.add s
      else: result.foreignLeibr.add s
    of "kapital", "kapitalleistung", "einmalzahlung",
       "freizuegigkeit", "freizuegigkeitskonto":
      if dom:
        result.warnings.add RenteEmitWarning(zahler: r.zahler,
          reason: "inländische Kapitalleistung (§22 Nr. 5 Satz 2) — manuell eintragen")
      else:
        result.foreignKapital.add s
    else:
      result.warnings.add RenteEmitWarning(zahler: r.zahler,
        reason: "unbekannte art `" & r.art & "` — manuell eintragen")

func generateEst*(input: EstInput): string =
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
      for code in ["E2001805", "E2002105", "E2002206"]:
        if code in vor:
          andPers.add(&"""
              <{code}>{roundEuro(vor[code])}</{code}>""")
      vorParts.add(&"""
          <Beitr_g_KV_PV_Inl>
            <Person>PersonA</Person>
            <And_Pers>{andPers}
            </And_Pers>
          </Beitr_g_KV_PV_Inl>""")

    if hasPrivat:
      var privParts = ""
      for code in ["E2003104", "E2003202", "E2003302"]:
        if code in vor:
          privParts.add(&"""
              <{code}>{roundEuro(vor[code])}</{code}>""")
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

  # §35a Haushaltsnahe Beschäftigung / Dienstleistungen / Handwerker.
  # The renderer always emits a single-entry Einz row alongside Sum so
  # ERiC plausi 2019_101170001/002 (require at least one Einzelposten)
  # passes. Users who need per-bill detail can still aggregate ahead of
  # time — we only see totals via abzuege.tsv.
  var ha35a = ""
  block:
    var parts = ""
    let hhn = input.deductions.hhn
    let hwk = input.deductions.hwk
    if "E0104109" in hhn:
      let b = roundEuro(hhn["E0104109"])
      parts.add(&"""
            <Minijobs>
              <Einz>
                <E0104206>Minijob</E0104206>
                <E0104108>{b}</E0104108>
              </Einz>
              <Sum>
                <E0104109>{b}</E0104109>
              </Sum>
            </Minijobs>""")
    if "E0107208" in hhn:
      let b = roundEuro(hhn["E0107208"])
      parts.add(&"""
            <Hhn_BV_DL>
              <Einz>
                <E0107206>Haushaltsnahe Dienstleistung</E0107206>
                <E0107207>{b}</E0107207>
              </Einz>
              <Sum>
                <E0107208>{b}</E0107208>
              </Sum>
            </Hhn_BV_DL>""")
    if "E0111215" in hwk:
      let b = roundEuro(hwk["E0111215"])
      parts.add(&"""
            <Handw_L>
              <Einz>
                <E0111217>Handwerkerleistung</E0111217>
                <E0111214>{b}</E0111214>
              </Einz>
              <Sum>
                <E0111215>{b}</E0111215>
              </Sum>
            </Handw_L>""")
    if parts.len > 0:
      ha35a = &"""
        <HA_35a>
          <St_Erm>{parts}
          </St_Erm>
        </HA_35a>"""

  # Build Anlage Kind (one per child from conf)
  var kinderXml = ""
  for kid in input.conf.kids:
    var kindParts = ""

    # Date ranges for Kindschaftsverhältnis and Wohnsitz im Inland.
    # Kindschaftsverhältnis start defaults to DD.MM of birthdate when
    # the child was born in the tax year, else 01.01. End defaults to
    # 31.12. Wohnsitz defaults to the resolved Kindschaftsverhältnis
    # range (aging-out / adoption-out / death typically ends household
    # residence too). Each of the four edges is independently overridable
    # via verhaeltnis_von/_bis and wohnsitz_von/_bis.
    let kvhVon = block:
      if kid.verhaeltnisVon != "": kid.verhaeltnisVon
      else:
        let parts = kid.birthdate.split('.')
        if parts.len == 3 and parts[2].strip == $input.year:
          let d = parts[0].strip
          let m = parts[1].strip
          let dd = if d.len == 1: "0" & d else: d
          let mm = if m.len == 1: "0" & m else: m
          dd & "." & mm
        else: "01.01"
    let kvhBis = if kid.verhaeltnisBis != "": kid.verhaeltnisBis else: "31.12"
    let wohnVon = if kid.wohnsitzVon != "": kid.wohnsitzVon else: kvhVon
    let wohnBis = if kid.wohnsitzBis != "": kid.wohnsitzBis else: kvhBis
    let kvhRange = kvhVon & "-" & kvhBis
    let wohnRange = wohnVon & "-" & wohnBis

    # Basic child info. E0500108 (Nachname) is optional — only emit when
    # the kid's explicit last name differs from the taxpayer's. A 1-word
    # section header ("[Louise]") leaves kid.lastname empty and implies
    # the taxpayer's surname, so the field stays out. For 2+ words, last
    # word is the surname; same-as-taxpayer is allowed but not emitted.
    var allgParts = ""
    if kid.idnr != "":
      allgParts.add(&"""
              <E0500406>{kid.idnr}</E0500406>""")
    allgParts.add(&"""
              <E0500107>{kid.firstname}</E0500107>""")
    if kid.lastname != "" and kid.lastname != p.lastname:
      allgParts.add(&"""
              <E0500108>{kid.lastname}</E0500108>""")
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
                <E0500703>{wohnRange}</E0500703>
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
              <E0500601>{kvhRange}</E0500601>
            </K_Verh_A>"""
    if input.conf.spouse.present and kid.kindschaftsverhaeltnisB != "":
      kVerhParts.add(&"""
            <K_Verh_B>
              <E0500808>{kid.kindschaftsverhaeltnisB}</E0500808>
              <E0500805>{kvhRange}</E0500805>
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
                <E0501903>{kvhRange}</E0501903>
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

    # Build each Kind child block separately, then concatenate in the
    # XSD's required order at the end. XSD sequence (relevant subset):
    # Ang_Kind, K_Verh, …, EfA*, …, Schulgeld?, …, KBK?. Getting this
    # wrong trips ERIC_IO_READER_SCHEMA_VALIDIERUNGSFEHLER (610301200)
    # on --output-pdf.

    # Kinderbetreuungskosten (E0506105). Einzelveranlagung and/or
    # separated-parents scenarios require the <Ang_HH> Haushalt block
    # inside <KBK> (ERiC plausi 100500005 otherwise). Under
    # Einzelveranlagung ERiC also wants an Eltern-keine-Zusammen-veranlagung
    # <Elt_k_ZV><Kosten><Sum>E0506604 "selbst getragen" figure — see the
    # celeste174_eigen companion key handling below.
    var kbkBlock = ""
    if "E0506105" in kidDeductions:
      let betrag = roundEuro(kidDeductions["E0506105"])
      let defaultHaushalt =
        if input.conf.spouse.present: "beide"
        else: "a"
      let haushalt = if kid.haushalt != "": kid.haushalt else: defaultHaushalt
      let getrennt =
        if kid.haushaltElternGetrennt != "": kid.haushaltElternGetrennt
        elif input.conf.spouse.present: ""
        else: "1"
      var hhBlock = ""
      if haushalt == "beide" and getrennt != "1":
        hhBlock = &"""
            <Ang_HH>
              <Gem_HH_Elt>
                <E0504807>{kvhRange}</E0504807>
                <E0504808>{kvhRange}</E0504808>
              </Gem_HH_Elt>
            </Ang_HH>"""
      elif haushalt == "a":
        hhBlock = &"""
            <Ang_HH>
              <K_gem_HH_Elt>
                <E0505201>{kvhRange}</E0505201>
                <E0505202>{kvhRange}</E0505202>
              </K_gem_HH_Elt>
            </Ang_HH>"""
      # haushalt == "b" (kid in other parent's household) — no filer-side
      # emission; KBK deduction wouldn't normally be claimed in that case.
      var ekzvBlock = ""
      let eigenKey = "E0506604"
      if eigenKey in kidDeductions and not input.conf.spouse.present:
        let eigen = roundEuro(kidDeductions[eigenKey])
        # ERiC rule Kind_Kinderbetreuungskosten_10050054 rejects the bare
        # Sum: we need at least one Einz row listing the individual
        # selbst-getragen outlay. The Einz under <Kosten> uses
        # E0506606 (Zeitraum) + E0506605 (Betrag); Sum is E0506604.
        ekzvBlock = &"""
            <Elt_k_ZV>
              <Kosten>
                <Einz>
                  <E0506606>{kvhRange}</E0506606>
                  <E0506605>{eigen}</E0506605>
                </Einz>
                <Sum>
                  <E0506604>{eigen}</E0506604>
                </Sum>
              </Kosten>
            </Elt_k_ZV>"""
      kbkBlock = &"""
          <KBK>
            <Art>
              <Einz>
                <E0506101>Kinderbetreuung</E0506101>
                <E0506103>{kvhRange}</E0506103>
                <E0506104>{betrag}</E0506104>
              </Einz>
              <Sum>
                <E0506105>{betrag}</E0506105>
              </Sum>
            </Art>{hhBlock}{ekzvBlock}
          </KBK>"""

    # Schulgeld. ERiC plausi 100500043 wants at least one Einzelposten
    # alongside the Sum — we map the single conf-level total into one
    # Einz row (E0505606) so the Gesamtsumme matches. Under
    # Einzelveranlagung, ERiC plausi 100500031 additionally needs the
    # "selbst getragen" Anteil; fed via the <kidname>176_eigen conf key
    # (maps to E0504505 in <Elt_k_ZV>).
    var schulgeldBlock = ""
    if "E0505607" in kidDeductions:
      let betrag = roundEuro(kidDeductions["E0505607"])
      var eigenPart = ""
      if "E0504505" in kidDeductions and not input.conf.spouse.present:
        eigenPart = &"""
            <Elt_k_ZV>
              <E0504505>{roundEuro(kidDeductions["E0504505"])}</E0504505>
            </Elt_k_ZV>"""
      # XSD sequence inside Einz is (E0505606?, E0504405?) — name
      # first, amount second. Swapping these trips schema validation
      # (610301200 "not allowed for content model").
      schulgeldBlock = &"""
          <Schulgeld>
            <Einz>
              <E0505606>Schule</E0505606>
              <E0504405>{betrag}</E0504405>
            </Einz>
            <Sum>
              <E0505607>{betrag}</E0505607>
            </Sum>{eigenPart}
          </Schulgeld>"""

    # §24b Entlastungsbetrag für Alleinerziehende. Emitted once per kid
    # that lives in the filer's household (haushalt=a or inferred under
    # Einzelveranlagung). Zusammenveranlagung never qualifies.
    var efaBlock = ""
    if p.alleinerziehend and not input.conf.spouse.present:
      let hh = if kid.haushalt != "": kid.haushalt else: "a"
      if hh == "a":
        efaBlock = &"""
          <EfA>
            <E0503701>1</E0503701>
          </EfA>"""

    # Append in XSD order: EfA, Schulgeld, KBK.
    kindParts.add(efaBlock)
    kindParts.add(schulgeldBlock)
    kindParts.add(kbkBlock)

    kinderXml.add(&"""
        <Kind>{kindParts}
        </Kind>""")

  # Build Anlage KAP
  var kapXml = ""
  let kt = input.kapTotals
  let hasKAP = kt.gains > 0 or kt.gainsOhneStAbz > 0 or kt.gainsAusland > 0 or
               kt.tax > 0 or kt.guenstigerpruefung or
               kt.sparerPauschbetrag > 0 or kt.kirchensteuer > 0 or
               kt.auslaendischeQuellensteuer > 0 or kt.nichtAnrechenbarAqs > 0 or
               kt.verlusteAktien != 0 or kt.verlusteSonstige != 0
  if hasKAP:
    var kapParts = ""

    if kt.guenstigerpruefung:
      kapParts.add(&"""
          <Ant>
            <E1900401>1</E1900401>
          </Ant>""")

    if kt.gains > 0 or kt.verlusteAktien != 0 or kt.verlusteSonstige != 0 or
       kt.auslaendischeQuellensteuer > 0 or kt.nichtAnrechenbarAqs > 0:
      var betrParts = ""
      if kt.gains > 0:
        betrParts.add(&"""
              <E1900701>{roundEuro(kt.gains)}</E1900701>""")
      if kt.verlusteAktien != 0:
        betrParts.add(&"""
              <E1900804>{roundEuro(kt.verlusteAktien)}</E1900804>""")
      if kt.verlusteSonstige != 0:
        betrParts.add(&"""
              <E1900901>{roundEuro(kt.verlusteSonstige)}</E1900901>""")
      if kt.auslaendischeQuellensteuer > 0:
        betrParts.add(&"""
              <E1901201>{formatEurDE(kt.auslaendischeQuellensteuer)}</E1901201>""")
      if kt.nichtAnrechenbarAqs > 0:
        betrParts.add(&"""
              <E1901301>{formatEurDE(kt.nichtAnrechenbarAqs)}</E1901301>""")
      kapParts.add(&"""
          <KapErt_inl_StAbz>
            <Betr_lt_StBesch>{betrParts}
            </Betr_lt_StBesch>
          </KapErt_inl_StAbz>""")

    # Sp_PB/E1901401 = SPB already used against Z.7 income. ERiC rule
    # 192021 rejects it when the only gains are ohne Steuerabzug
    # (Z.18/Z.19), so gate on kt.gains > 0. XSD sequence puts Sp_PB
    # before KapErt_kein_inl_StAbz, both after KapErt_inl_StAbz.
    if kt.sparerPauschbetrag > 0 and kt.gains > 0:
      kapParts.add(&"""
          <Sp_PB>
            <E1901401>{roundEuro(kt.sparerPauschbetrag)}</E1901401>
          </Sp_PB>""")

    # Gains without inländischer Steuerabzug — Zeile 18 (inländisch) /
    # Zeile 19 (ausländisch). For foreign interest, cashback, PSA-less
    # IBKR dividends, etc.: no German withholding, so the domestic
    # Betr_lt_StBesch (Zeile 7) would be wrong.
    if kt.gainsOhneStAbz > 0 or kt.gainsAusland > 0:
      var keinStParts = ""
      if kt.gainsOhneStAbz > 0:
        keinStParts.add(&"""
            <E1901501>{roundEuro(kt.gainsOhneStAbz)}</E1901501>""")
      if kt.gainsAusland > 0:
        keinStParts.add(&"""
            <E1901702>{roundEuro(kt.gainsAusland)}</E1901702>""")
      kapParts.add(&"""
          <KapErt_kein_inl_StAbz>{keinStParts}
          </KapErt_kein_inl_StAbz>""")

    # XSD sequence inside St_Abz_Betr_Inl_u_Inv_Ert is
    # (E1904701, E1904901, E1904801, …). Code meanings per schema:
    #   E1904701 = Kapitalertragsteuer
    #   E1904901 = Solidaritätszuschlag
    #   E1904801 = Kirchensteuer zur KapESt
    if kt.tax > 0 or kt.soli > 0 or kt.kirchensteuer > 0:
      var stParts = ""
      if kt.tax > 0:
        stParts.add(&"""
              <E1904701>{formatEurDE(kt.tax)}</E1904701>""")
      if kt.soli > 0:
        stParts.add(&"""
              <E1904901>{formatEurDE(kt.soli)}</E1904901>""")
      if kt.kirchensteuer > 0:
        stParts.add(&"""
              <E1904801>{formatEurDE(kt.kirchensteuer)}</E1904801>""")
      kapParts.add(&"""
          <St_Abz_Betr_Inl_u_Inv_Ert>{stParts}
          </St_Abz_Betr_Inl_u_Inv_Ert>""")

    kapXml = &"""
        <KAP>
          <Person>PersonA</Person>{kapParts}
        </KAP>"""

  # Anlage R / R_AUS (Renten, sonstige Leistungen).
  # Buckets per classifyRente:
  #   * domestic Leibrente (gefoerdert=false)       → <R>/Leibr_priv
  #   * foreign Leibrente (gefoerdert=false)        → <R_AUS>/Leibr_priv
  #   * foreign Kapital/Freizügigkeit (gefoerdert=f)→ <R_AUS>/Leist_bAV (E1823901)
  # gefoerdert (Riester/Rürup/bAV) and domestic Kapitalleistungen fall out
  # via warnings and must be entered manually.
  let classified = classifyRente(input.rente)
  var anlageR = ""
  if classified.domesticLeibr.len > 0:
    var einz = ""
    for s in classified.domesticLeibr:
      let r = s.row
      var parts = &"""
                <E1801601>{roundEuro(r.betrag)}</E1801601>"""
      if r.zahlungAm != "":
        parts.add(&"""
                <E1801701>{r.zahlungAm}</E1801701>""")
      einz.add(&"""
              <Einz>{parts}
              </Einz>""")
    anlageR = &"""
        <R>
          <Person>PersonA</Person>
          <Leibr_priv>{einz}
          </Leibr_priv>
        </R>"""

  var anlageRAus = ""
  if classified.foreignLeibr.len > 0 or classified.foreignKapital.len > 0:
    var body = ""
    if classified.foreignLeibr.len > 0:
      var einz = ""
      for s in classified.foreignLeibr:
        let r = s.row
        var parts = ""
        if r.herkunftsland != "":
          parts.add(&"""
                <E1821402>{r.herkunftsland}</E1821402>""")
        parts.add(&"""
                <E1821301>{roundEuro(r.betrag)}</E1821301>""")
        if r.zahlungAm != "":
          parts.add(&"""
                <E1821401>{r.zahlungAm}</E1821401>""")
        einz.add(&"""
              <Einz>{parts}
              </Einz>""")
      body.add(&"""
          <Leibr_priv>{einz}
          </Leibr_priv>""")
    if classified.foreignKapital.len > 0:
      var einz = ""
      for s in classified.foreignKapital:
        let r = s.row
        var parts = ""
        if r.herkunftsland != "":
          parts.add(&"""
                <E1823101>{r.herkunftsland}</E1823101>""")
        parts.add(&"""
                <E1823901>{roundEuro(r.betrag)}</E1823901>""")
        einz.add(&"""
              <Einz>{parts}
              </Einz>""")
      body.add(&"""
          <Leist_bAV>{einz}
          </Leist_bAV>""")
    anlageRAus = &"""
        <R_AUS>
          <Person>PersonA</Person>{body}
        </R_AUS>"""

  # Personal fields
  let religionLine = if p.religion != "": &"""
                <E0100402>{p.religion}</E0100402>""" else: ""
  let berufLine = if p.profession != "": &"""
                <E0100403>{p.profession}</E0100403>""" else: ""

  let fullName = p.lastname & " " & p.firstname
  let produktVersion = if input.produktVersion != "": input.produktVersion else: "0.1.0"

  result = &"""<?xml version="1.0" encoding="UTF-8"?>
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
          </ESt1A>{sonderausgaben}{agb}{ha35a}{kinderXml}{anlageG}{anlageS}{kapXml}{anlageR}{anlageRAus}{vorsorge}
          <Vorsatz>
            <Unterfallart>10</Unterfallart>
            <Vorgang>01</Vorgang>
            <StNr>{p.taxnumber}</StNr>
            <Zeitraum>{input.year}</Zeitraum>
            <AbsName>{fullName}</AbsName>
            <AbsStr>{p.street} {p.housenumber}</AbsStr>
            <AbsPlz>{p.zip}</AbsPlz>
            <AbsOrt>{p.city}</AbsOrt>
            <Copyright>{Copyright}</Copyright>
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
