## SonstigeNachrichten XML Generation
## Generates ELSTER XML for sending a message to the Finanzamt

import std/[strformat]
import viking/config

const nachrichtNs = "http://finkonsens.de/elster/elsternachricht/sonstigenachrichten/v21"
const elsterNs = "http://www.elster.de/elsterxml/schema/v11"

proc xmlEscape(s: string): string =
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc generateNachrichtXml*(
  steuernummer: string,
  name: string,
  strasse: string,
  hausnummer: string,
  plz: string,
  ort: string,
  betreff: string,
  text: string,
  test: bool,
  produktVersion: string = "0.1.0",
): string =
  let herstellerId = HerstellerId
  let finanzamt = steuernummer[0..3]
  let bundesland = bundeslandFromSteuernummer(steuernummer)
  let testmerkerLine = if test: "\n    <Testmerker>700000004</Testmerker>" else: ""

  let escName = xmlEscape(name)
  let escStrasse = xmlEscape(strasse)
  let escOrt = xmlEscape(ort)
  let escBetreff = xmlEscape(betreff)
  let escText = xmlEscape(text)

  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="{elsterNs}">
  <TransferHeader version="11">
    <Verfahren>ElsterNachricht</Verfahren>
    <DatenArt>SonstigeNachrichten</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
    <Empfaenger id="L">
      <Ziel>{bundesland}</Ziel>
    </Empfaenger>
    <HerstellerID>{herstellerId}</HerstellerID>
    <DatenLieferant>{escName}</DatenLieferant>
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
        <Nachricht xmlns="{nachrichtNs}" version="21">
          <Steuernummer>{steuernummer}</Steuernummer>
          <Steuerpflichtiger>
            <SteuerpflichtigerTyp>NichtNatPerson</SteuerpflichtigerTyp>
            <Name>{escName}</Name>
            <Adresse>
              <StrAdrInl>
                <Strasse>{escStrasse}</Strasse>
                <Hausnummer>{hausnummer}</Hausnummer>
                <Postleitzahl>{plz}</Postleitzahl>
                <Ort>{escOrt}</Ort>
              </StrAdrInl>
            </Adresse>
          </Steuerpflichtiger>
          <Inhalt>
            <Betreff>{escBetreff}</Betreff>
            <Text>{escText}</Text>
          </Inhalt>
        </Nachricht>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""
