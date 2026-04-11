## Datenabholung XML Generation
## Generates ELSTER DatenTeil XML for Postfach operations

import std/[strformat]

proc generateDatenTeil(nutzdatenContent: string): string =
  result = &"""<Elster>
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
        <Datenabholung xmlns="http://www.elster.de/elsterxml/schema/v11">
{nutzdatenContent}
        </Datenabholung>
      </Nutzdaten>
    </Nutzdatenblock>
  </DatenTeil>
</Elster>"""

proc generatePostfachStatusDatenTeil*(): string =
  generateDatenTeil("          <PostfachStatus/>")

proc generatePostfachAnfrageDatenTeil*(): string =
  generateDatenTeil("          <PostfachAnfrage/>")

proc generatePostfachBestaetigungDatenTeil*(ids: seq[string]): string =
  var content = "          <PostfachBestaetigung>\n"
  content.add("            <Bereitstellungen>\n")
  for id in ids:
    content.add(&"              <Bereitstellung id=\"{id}\"/>\n")
  content.add("            </Bereitstellungen>\n")
  content.add("          </PostfachBestaetigung>")
  generateDatenTeil(content)
