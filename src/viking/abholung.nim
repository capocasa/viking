## Postfach / Datenabholung helpers
## Types, XML parsing, and query logic for ELSTER Postfach operations.

import std/[strutils, strformat, xmltree, xmlparser]
import viking/[config, ericffi, abholung_xml, log]

type
  AbholAnhang* = object
    dateibezeichnung*: string
    dateityp*: string
    dateiReferenzId*: string
    dateiGroesse*: int

  AbholBereitstellung* = object
    id*: string
    datenart*: string
    groesse*: int
    veranlagungszeitraum*: string
    steuernummer*: string
    bescheiddatum*: string
    anhaenge*: seq[AbholAnhang]

func findAll(node: XmlNode, tag: string): seq[XmlNode] =
  result = @[]
  if node.kind != xnElement: return
  if node.tag == tag: result.add(node)
  for child in node:
    result.add(findAll(child, tag))

func mimeToExt*(mime: string): string =
  case mime
  of "application/pdf": ".pdf"
  of "text/xml", "application/xml": ".xml"
  of "text/html": ".html"
  else: ".bin"

func sanitizeFilename*(s: string): string =
  result = s
  for c in [' ', '/', '\\', ':', '*', '?', '"', '<', '>', '|']:
    result = result.replace($c, "_")

func constructFilename*(b: AbholBereitstellung, a: AbholAnhang): string =
  let ext = mimeToExt(a.dateityp)
  let vz = if b.veranlagungszeitraum.len > 0: "_" & b.veranlagungszeitraum else: ""
  sanitizeFilename(a.dateibezeichnung) & vz & ext

iterator allFilenames*(bereitstellungen: seq[AbholBereitstellung]): tuple[b: AbholBereitstellung, a: AbholAnhang, filename: string] =
  for b in bereitstellungen:
    for a in b.anhaenge:
      yield (b, a, constructFilename(b, a))

proc parsePostfachAntwort*(xmlDoc: XmlNode): seq[AbholBereitstellung] =
  result = @[]
  for dab in xmlDoc.findAll("DatenartBereitstellung"):
    let datenart = dab.attr("name")
    let anzahl = try: parseInt(dab.attr("anzahltreffer")) except ValueError: 0
    if anzahl == 0: continue

    for bs in dab.findAll("Bereitstellung"):
      let id = bs.attr("id")
      if id.len == 0:
        err "Warning: Bereitstellung missing id attribute, skipping"
        continue
      var b = AbholBereitstellung(
        id: id,
        datenart: datenart,
        groesse: try: parseInt(bs.attr("groesse")) except ValueError: 0,
      )

      for meta in bs.findAll("Meta"):
        let name = meta.attr("name")
        let value = meta.innerText
        case name
        of "veranlagungszeitraum": b.veranlagungszeitraum = value
        of "steuernummer": b.steuernummer = value
        of "bescheiddatum": b.bescheiddatum = value

      for anhang in bs.findAll("Anhang"):
        var a = AbholAnhang()
        for child in anhang:
          if child.kind != xnElement: continue
          case child.tag
          of "Dateibezeichnung": a.dateibezeichnung = child.innerText
          of "Dateityp": a.dateityp = child.innerText
          of "DateiReferenzId": a.dateiReferenzId = child.innerText
          of "DateiGroesse": a.dateiGroesse = try: parseInt(child.innerText) except ValueError: 0
        if a.dateiReferenzId.len > 0:
          b.anhaenge.add(a)

      result.add(b)

proc sendPostfachAnfrage*(
  cfg: Config,
  name: string,
  produktVersion: string,
  cryptParam: ptr EricVerschluesselungsParameterT,
  einschraenkung: string,
  verbose: bool,
): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
  let anfragXml = generatePostfachAnfrageXml(
    name, cfg.test, produktVersion, einschraenkung,
  )

  var transferHandle: uint32 = 0
  let responseBuf = ericRueckgabepufferErzeugen()
  let serverBuf = ericRueckgabepufferErzeugen()
  if responseBuf == nil or serverBuf == nil:
    err "Error: Failed to create return buffers"
    return (1, @[], "")
  defer:
    discard ericRueckgabepufferFreigabe(responseBuf)
    discard ericRueckgabepufferFreigabe(serverBuf)

  let rc = ericBearbeiteVorgang(anfragXml, "PostfachAnfrage_31",
    ERIC_VALIDIERE or ERIC_SENDE, nil, cryptParam, addr transferHandle,
    responseBuf, serverBuf)

  let response = ericRueckgabepufferInhalt(responseBuf)
  let serverResponse = ericRueckgabepufferInhalt(serverBuf)

  if rc != 0:
    err &"Error: Postfach request failed: {ericHoleFehlerText(rc)}"
    if response.len > 0: log response
    if serverResponse.len > 0: log serverResponse
    return (1, @[], "")

  if serverResponse.len == 0:
    return (0, @[], "")

  log serverResponse

  var xmlDoc: XmlNode
  try:
    xmlDoc = parseXml(serverResponse)
  except CatchableError:
    err "Error: Failed to parse server response XML"
    return (1, @[], "")

  let bereitstellungen = parsePostfachAntwort(xmlDoc)
  return (0, bereitstellungen, serverResponse)

proc initEricAndQueryPostfach*(cfg: Config, certPath, certPin, name, produktVersion: string, verbose: bool): tuple[rc: int, bereitstellungen: seq[AbholBereitstellung], serverResponse: string] =
  ## Shared helper: send PostfachAnfrage, parse response.
  ## Caller must have loaded ERiC lib and called ericInitialisiere already.

  let (certRc, certHandle) = ericGetHandleToCertificate(certPath)
  if certRc != 0:
    err &"Error: Failed to open certificate: {ericHoleFehlerText(certRc)}"
    return (1, @[], "")
  defer: discard ericCloseHandleToCertificate(certHandle)

  var cryptParam: EricVerschluesselungsParameterT
  cryptParam.version = 3
  cryptParam.zertifikatHandle = certHandle
  cryptParam.pin = certPin.cstring

  let (rc, bereitstellungen, serverResponse) = sendPostfachAnfrage(cfg, name, produktVersion, addr cryptParam, "alle", verbose)
  if rc != 0:
    return (rc, @[], "")

  if bereitstellungen.len == 0 and serverResponse.len == 0:
    return (0, @[], "")

  return (0, bereitstellungen, serverResponse)

proc displayBereitstellungen*(bereitstellungen: seq[AbholBereitstellung]) =
  if bereitstellungen.len == 0:
    return
  for b in bereitstellungen:
    for a in b.anhaenge:
      echo constructFilename(b, a)

