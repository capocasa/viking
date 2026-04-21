## Unit tests for viking/ericerror: parsing of ERiC/server response buffers.

import std/[unittest, strutils]
import viking/ericerror

suite "parseFehlerRegelpruefung":

  test "extracts Text and FachlicheFehlerId from one entry":
    const xml = """<?xml version="1.0" encoding="UTF-8"?>
<EricBearbeiteVorgang xmlns="http://www.elster.de/EricXML/1.1/EricBearbeiteVorgang">
  <FehlerRegelpruefung>
    <Nutzdatenticket>1</Nutzdatenticket>
    <Feldidentifikator>/USt2A[1]/Abz_VoSt[1]/Tabelle[1]/Abz_VoSt_Sum[1]/E3006901[1]</Feldidentifikator>
    <VordruckZeilennummer>87</VordruckZeilennummer>
    <RegelName>/USt2A/Abz_VoSt/Tabelle/Abz_VoSt_Sum/USt_30150</RegelName>
    <FachlicheFehlerId>30150</FachlicheFehlerId>
    <Text>Die Summe der abziehbaren Vorsteuerbeträge wurde nicht übertragen.</Text>
  </FehlerRegelpruefung>
</EricBearbeiteVorgang>"""
    let res = parseFehlerRegelpruefung(xml)
    check res.len == 1
    check res[0].code == "30150"
    check res[0].text == "Die Summe der abziehbaren Vorsteuerbeträge wurde nicht übertragen."

  test "extracts multiple entries in document order":
    const xml = """<?xml version="1.0"?>
<EricBearbeiteVorgang>
  <FehlerRegelpruefung>
    <FachlicheFehlerId>30150</FachlicheFehlerId>
    <Text>Erste Meldung.</Text>
  </FehlerRegelpruefung>
  <FehlerRegelpruefung>
    <FachlicheFehlerId>30901</FachlicheFehlerId>
    <Text>Zweite Meldung.</Text>
  </FehlerRegelpruefung>
</EricBearbeiteVorgang>"""
    let res = parseFehlerRegelpruefung(xml)
    check res.len == 2
    check res[0] == (text: "Erste Meldung.", code: "30150")
    check res[1] == (text: "Zweite Meldung.", code: "30901")

  test "returns empty on success response (Transfers only)":
    const xml = """<?xml version="1.0"?>
<EricBearbeiteVorgang>
  <Transfers>
    <Transfer><TransferTicket>eh10776x9me4om1kq3qjsqt5h1r4bq3j</TransferTicket></Transfer>
  </Transfers>
</EricBearbeiteVorgang>"""
    check parseFehlerRegelpruefung(xml).len == 0

  test "empty input returns empty":
    check parseFehlerRegelpruefung("").len == 0

  test "malformed XML does not raise":
    check parseFehlerRegelpruefung("<not closed").len == 0

suite "parseServerRueckgabeErrors":

  test "skips success code 0":
    const xml = """<?xml version="1.0"?>
<Elster><TransferHeader>
  <RC><Rueckgabe><Code>0</Code><Text>Daten wurden erfolgreich angenommen.</Text></Rueckgabe></RC>
</TransferHeader></Elster>"""
    check parseServerRueckgabeErrors(xml).len == 0

  test "reports non-zero Code and Text":
    const xml = """<?xml version="1.0"?>
<Elster><TransferHeader>
  <RC><Rueckgabe><Code>130025002</Code><Text>Die Verwendung einer TestCA ohne gesetzten Testmerker ist nicht zulaessig -</Text></Rueckgabe></RC>
</TransferHeader></Elster>"""
    let res = parseServerRueckgabeErrors(xml)
    check res.len == 1
    check res[0].code == "130025002"
    check res[0].text.startsWith("Die Verwendung einer TestCA")

  test "empty input returns empty":
    check parseServerRueckgabeErrors("").len == 0

  test "malformed XML does not raise":
    check parseServerRueckgabeErrors("<<<").len == 0
