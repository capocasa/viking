## Datenabholung XML Generation
## Generates ELSTER XML for Postfach operations (Datenabholung v31)

import std/[strformat]

const datenabholungNs = "http://finkonsens.de/elster/elsterdatenabholung/v3"
const elsterNs = "http://www.elster.de/elsterxml/schema/v11"

proc generateAbholungXml*(
  nutzdatenContent: string,
  herstellerId: string,
  name: string,
  test: bool,
  datenArt: string = "PostfachAnfrage",
): string =
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
          <ProduktName>Viking</ProduktName>
          <ProduktVersion>0.1.0</ProduktVersion>
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
  herstellerId: string,
  name: string,
  test: bool,
): string =
  # Request all standard document types:
  # ESB = Elektronischer Steuerbescheid (DIVA Stufe 1)
  # EPMitteilung = Elektronische Postfach-Mitteilungen
  # DivaBescheidESt/USt/GewSt/KSt/FEIN = Steuerbescheide (DIVA Stufe 2)
  # DivaSonstigerVA = sonstige Verwaltungsakte
  var content = "          <PostfachAnfrage einschraenkung=\"alle\" max=\"1000\">\n"
  for name in ["ESB", "EPMitteilung",
                "DivaBescheidESt", "DivaBescheidUSt",
                "DivaBescheidGewSt", "DivaBescheidKSt",
                "DivaBescheidFEIN", "DivaSonstigerVA"]:
    content.add(&"            <DatenartBereitstellung name=\"{name}\"/>\n")
  content.add("          </PostfachAnfrage>")
  generateAbholungXml(content, herstellerId, name, test, "PostfachAnfrage")

proc generatePostfachBestaetigungXml*(
  bereitstellungIds: seq[string],
  herstellerId: string,
  name: string,
  test: bool,
): string =
  var content = "          <PostfachBestaetigung>\n"
  content.add("            <Bereitstellungen>\n")
  for id in bereitstellungIds:
    content.add(&"              <Bereitstellung id=\"{id}\"/>\n")
  content.add("            </Bereitstellungen>\n")
  content.add("          </PostfachBestaetigung>")
  generateAbholungXml(content, herstellerId, name, test, "PostfachBestaetigung")
