## EÜR XML Generation
## Generates ELSTER XML for Einnahmenüberschussrechnung (profit/loss statement)

import std/[strformat]
import viking/config

type
  EuerInput* = object
    steuernummer*: string
    jahr*: int
    incomeNet*: float
    incomeVat*: float
    expenseNet*: float
    expenseVorsteuer*: float
    rechtsform*: string
    einkunftsart*: string
    name*: string
    strasse*: string
    plz*: string
    ort*: string
    test*: bool
    produktVersion*: string

proc generateEuer*(input: EuerInput): string =
  ## Generate ELSTER XML for EÜR (Einnahmenüberschussrechnung)

  let steuernummer = input.steuernummer
  let jahr = input.jahr
  let incomeNet = input.incomeNet
  let incomeVat = input.incomeVat
  let expenseNet = input.expenseNet
  let expenseVorsteuer = input.expenseVorsteuer
  let name = input.name
  let strasse = input.strasse
  let plz = input.plz
  let ort = input.ort
  let rechtsform = input.rechtsform
  let einkunftsart = input.einkunftsart
  let produktVersion = if input.produktVersion != "": input.produktVersion else: "0.1.0"
  let finanzamt = steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(steuernummer)
  let testmerkerLine = if input.test: "\n    <Testmerker>700000004</Testmerker>" else: ""
  let herstellerId = HerstellerId
  let produktName = ProduktName

  # Compute totals
  let totalIncome = roundCents(incomeNet + incomeVat)
  let totalExpense = roundCents(expenseNet + expenseVorsteuer)
  let profit = roundCents(totalIncome - totalExpense)

  let xml = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="http://www.elster.de/elsterxml/schema/v11">
  <TransferHeader version="11">
    <Verfahren>ElsterErklaerung</Verfahren>
    <DatenArt>EUER</DatenArt>
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
        <E77 xmlns="http://finkonsens.de/elster/elstererklaerung/euer/e77/v{jahr}" version="{jahr}">
          <EUER>
            <Allg>
              <E6000016>{name}</E6000016>
              <E6000017>Dienstleistungen</E6000017>
              <E6000602>{rechtsform}</E6000602>
              <E6000603>{einkunftsart}</E6000603>
              <E6000604>1</E6000604>
              <E6000019>2</E6000019>
            </Allg>
            <BEin>
              <USt_StPflicht>
                <Sum>
                  <E6000401>{formatEurDE(incomeNet)}</E6000401>
                </Sum>
              </USt_StPflicht>
              <USt_Vereinnahmt_Unentgeltl>
                <Sum>
                  <E6000601>{formatEurDE(incomeVat)}</E6000601>
                </Sum>
              </USt_Vereinnahmt_Unentgeltl>
              <GesamtSum>
                <E6001201>{formatEurDE(totalIncome)}</E6001201>
              </GesamtSum>
            </BEin>
            <BAus>
              <Sonst_unbeschraenkt>
                <Vorsteuer>
                  <Sum>
                    <E6005001>{formatEurDE(expenseVorsteuer)}</E6005001>
                  </Sum>
                </Vorsteuer>
                <Sonst_unbeschr_abziehbar>
                  <Sum>
                    <E6004901>{formatEurDE(expenseNet)}</E6004901>
                  </Sum>
                </Sonst_unbeschr_abziehbar>
              </Sonst_unbeschraenkt>
              <Summe_BAus>
                <E6005301>{formatEurDE(totalExpense)}</E6005301>
              </Summe_BAus>
            </BAus>
            <Ermittlung_Gewinn>
              <Uebertrag>
                <E6005501>{formatEurDE(totalIncome)}</E6005501>
                <E6005601>{formatEurDE(totalExpense)}</E6005601>
              </Uebertrag>
              <Korrektur_GuV>
                <E6006801>{formatEurDE(profit)}</E6006801>
              </Korrektur_GuV>
              <Stpfl_GuV>
                <E6007002>{formatEurDE(profit)}</E6007002>
                <E6007202>{formatEurDE(profit)}</E6007202>
              </Stpfl_GuV>
            </Ermittlung_Gewinn>
            <Zus_Angabe_EinzelUntern>
              <Entnahme_Einlage>
                <Entnahme>
                  <Sum>
                    <E6006601>0,00</E6006601>
                  </Sum>
                </Entnahme>
                <Einlage>
                  <Sum>
                    <E6006701>0,00</E6006701>
                  </Sum>
                </Einlage>
              </Entnahme_Einlage>
            </Zus_Angabe_EinzelUntern>
          </EUER>
          <Vorsatz>
            <Unterfallart>77</Unterfallart>
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
        </E77>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""

  result = xml
