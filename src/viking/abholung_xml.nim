## Datenabholung XML Generation
## Generates ELSTER XML for Postfach operations (Datenabholung v31)

import std/[strformat]
import viking/config

const datenabholungNs = "http://finkonsens.de/elster/elsterdatenabholung/v3"
const elsterNs = "http://www.elster.de/elsterxml/schema/v11"

proc generateAbholungXml*(
  nutzdatenContent: string,
  name: string,
  test: bool,
  produktVersion: string = "0.1.0",
  datenArt: string = "PostfachAnfrage",
): string =
  let herstellerId = HerstellerId
  let produktName = ProduktName
  let testmerkerLine = if test: "\n    <Testmerker>700000004</Testmerker>" else: ""
  result = &"""<?xml version="1.0" encoding="UTF-8"?>
<Elster xmlns="{elsterNs}">
  <TransferHeader version="11">
    <Verfahren>ElsterDatenabholung</Verfahren>
    <DatenArt>{datenArt}</DatenArt>
    <Vorgang>send-Auth</Vorgang>{testmerkerLine}
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
        <Empfaenger id="L">CS</Empfaenger>
        <Hersteller>
          <ProduktName>{produktName}</ProduktName>
          <ProduktVersion>{produktVersion}</ProduktVersion>
        </Hersteller>
      </NutzdatenHeader>
      <Nutzdaten>
        <Datenabholung xmlns="{datenabholungNs}" version="31">
{nutzdatenContent}
        </Datenabholung>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""

proc generatePostfachAnfrageXml*(
  name: string,
  test: bool,
  produktVersion: string = "0.1.0",
  einschraenkung: string = "alle",
): string =
  # Request all standard document types:
  # ESB = Elektronischer Steuerbescheid (DIVA Stufe 1)
  # EPMitteilung = Elektronische Postfach-Mitteilungen
  # DivaBescheidESt/USt/GewSt/KSt/FEIN = Steuerbescheide (DIVA Stufe 2)
  # DivaSonstigerVA = sonstige Verwaltungsakte
  var content = &"          <PostfachAnfrage einschraenkung=\"{einschraenkung}\" max=\"1000\">\n"
  for name in ["ESB", "EPMitteilung",
                "DivaBescheidESt", "DivaBescheidUSt",
                "DivaBescheidGewSt", "DivaBescheidKSt",
                "DivaBescheidFEIN", "DivaSonstigerVA"]:
    content.add(&"            <DatenartBereitstellung name=\"{name}\"/>\n")
  content.add("          </PostfachAnfrage>")
  generateAbholungXml(content, name, test, produktVersion, "PostfachAnfrage")

proc generatePostfachBestaetigungXml*(
  bereitstellungIds: seq[string],
  name: string,
  test: bool,
  produktVersion: string = "0.1.0",
): string =
  var content = "          <PostfachBestaetigung>\n"
  content.add("            <Bereitstellungen>\n")
  for id in bereitstellungIds:
    content.add(&"              <Bereitstellung id=\"{id}\"/>\n")
  content.add("            </Bereitstellungen>\n")
  content.add("          </PostfachBestaetigung>")
  generateAbholungXml(content, name, test, produktVersion, "PostfachBestaetigung")
