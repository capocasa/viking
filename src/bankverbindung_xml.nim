## AenderungBankverbindung XML Generation
## Generates ELSTER XML for changing bank account (IBAN) at the Finanzamt

import std/[strformat]
import config

const bankverbindungNs = "http://finkonsens.de/elster/elsternachricht/aenderungbankverbindung/v20"
const elsterNs = "http://www.elster.de/elsterxml/schema/v11"

proc generateBankverbindungXml*(
  steuernummer: string,
  name: string,
  vorname: string,
  nachname: string,
  geburtsdatum: string,
  idnr: string,
  iban: string,
  test: bool,
): string =
  let herstellerId = HerstellerId
  let finanzamt = steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(steuernummer)
  let testmerkerLine = if test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="{elsterNs}">
  <TransferHeader version="11">
    <Verfahren>ElsterNachricht</Verfahren>
    <DatenArt>AenderungBankverbindung</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L">
      <Ziel>{bundesland}</Ziel>
    </Empfaenger>
    <HerstellerID>{herstellerId}</HerstellerID>
    <DatenLieferant>{name}</DatenLieferant>
    <Datei>
      <Verschluesselung>CMSEncryptedData</Verschluesselung>
      <Kompression>GZIP</Kompression>
    </Datei>
  </TransferHeader>
  <DatenTeil>
    <Nutzdatenblock>
      <NutzdatenHeader version="11">
        <NutzdatenTicket>1</NutzdatenTicket>
        <Empfaenger id="F">{finanzamt}</Empfaenger>
      </NutzdatenHeader>
      <Nutzdaten>
        <AenderungBankverbindung xmlns="{bankverbindungNs}" version="20">
          <Ordnungsbegriff>
            <Steuernummer>{steuernummer}</Steuernummer>
          </Ordnungsbegriff>
          <Persoenliche_Daten>
            <Person_A>
              <Identifikationsnummer>{idnr}</Identifikationsnummer>
              <Anrede>Herrn</Anrede>
              <Vorname>{vorname}</Vorname>
              <Name>{nachname}</Name>
              <Geburtsdatum>{geburtsdatum}</Geburtsdatum>
            </Person_A>
          </Persoenliche_Daten>
          <Aenderung_der_Bankverbindung>
            <Bankverbindungen>
              <Bankverbindung>
                <IBAN>{iban}</IBAN>
                <Kontoinhaber>Person_A</Kontoinhaber>
                <Steuerarten>
                  <Steuerart>Alle (übrigen)</Steuerart>
                </Steuerarten>
              </Bankverbindung>
            </Bankverbindungen>
          </Aenderung_der_Bankverbindung>
        </AenderungBankverbindung>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""
