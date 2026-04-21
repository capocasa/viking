## ERiC error-response parsing.
##
## Extract natural-language messages from the two buffers returned by
## `EricBearbeiteVorgang`: `rueckgabePuffer` (ERiC-side validation —
## `FehlerRegelpruefung`) and `serverantwortPuffer` (ELSTER server —
## `RC/Rueckgabe`). The ERiC lib's own error text for plausibility
## failures just says "evaluate the Rückgabepuffer"; this module does
## the evaluation.
##
## Extension: each `FehlerRegelpruefung` also carries `Feldidentifikator`
## (XPath to the offending field) and `VordruckZeilennummer` (line
## number on the printed form). Both are written to the log; consider
## surfacing them on stderr if the `Text` alone is too generic to
## locate the problem.

import std/[xmltree, xmlparser]

proc findAllDeep*(node: XmlNode, tag: string): seq[XmlNode] =
  if node.kind != xnElement: return
  if node.tag == tag: result.add(node)
  for child in node:
    result.add(findAllDeep(child, tag))

proc parseFehlerRegelpruefung*(xmlStr: string): seq[tuple[text: string, code: string]] =
  ## Return (Text, FachlicheFehlerId) pairs from an EricBearbeiteVorgang response.
  if xmlStr.len == 0: return
  var doc: XmlNode
  try: doc = parseXml(xmlStr)
  except CatchableError: return
  for fr in doc.findAllDeep("FehlerRegelpruefung"):
    var text, code: string
    for sub in fr:
      if sub.kind != xnElement: continue
      case sub.tag
      of "Text": text = sub.innerText
      of "FachlicheFehlerId": code = sub.innerText
      else: discard
    if text.len > 0 or code.len > 0:
      result.add((text, code))

proc parseServerRueckgabeErrors*(xmlStr: string): seq[tuple[text: string, code: string]] =
  ## Return (Text, Code) pairs from every non-zero RC/Rueckgabe in an Elster
  ## server response. Code "0" means success and is skipped.
  if xmlStr.len == 0: return
  var doc: XmlNode
  try: doc = parseXml(xmlStr)
  except CatchableError: return
  for rg in doc.findAllDeep("Rueckgabe"):
    var text, code: string
    for sub in rg:
      if sub.kind != xnElement: continue
      case sub.tag
      of "Text": text = sub.innerText
      of "Code": code = sub.innerText
      else: discard
    if code.len > 0 and code != "0":
      result.add((text, code))
