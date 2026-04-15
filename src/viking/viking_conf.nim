## viking.conf parser
## Parses INI-style configuration for taxpayer data, KAP settings, and children.

import std/[parsecfg, streams, strutils, os]

type
  KidConf* = object
    firstname*: string
    birthdate*: string
    idnr*: string

  KapConf* = object
    guenstigerpruefung*: bool
    sparerPauschbetrag*: float

  TaxpayerConf* = object
    firstname*: string
    lastname*: string
    birthdate*: string
    idnr*: string
    taxnumber*: string
    income*: string          # "2"=Gewerbebetrieb, "3"=Selbstaendige Arbeit
    street*: string
    housenumber*: string
    zip*: string
    city*: string
    iban*: string
    religion*: string
    profession*: string
    kvArt*: string           # "privat" or "gesetzlich"
    rechtsform*: string
    besteuerungsart*: string

  VikingConf* = object
    taxpayer*: TaxpayerConf
    kap*: KapConf
    kids*: seq[KidConf]

proc loadVikingConf*(path: string): VikingConf =
  ## Parse a viking.conf file. Uses event-based parsecfg to handle
  ## repeated [kid] sections (each [kid] section adds a new child).
  if not fileExists(path):
    raise newException(IOError, "Config file not found: " & path)

  result.taxpayer.religion = "11"
  result.taxpayer.kvArt = "privat"
  result.taxpayer.rechtsform = "120"
  result.taxpayer.besteuerungsart = "2"

  let stream = newFileStream(path, fmRead)
  if stream == nil:
    raise newException(IOError, "Cannot open config file: " & path)
  defer: stream.close()

  var parser: CfgParser
  open(parser, stream, path)
  defer: close(parser)

  var currentSection = ""
  var currentKid: KidConf

  while true:
    let event = parser.next()
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      # Save previous kid if we were in a kid section
      if currentSection == "kid" and currentKid.firstname != "":
        result.kids.add(currentKid)
        currentKid = KidConf()
      currentSection = event.section.toLowerAscii
      if currentSection == "kid":
        currentKid = KidConf()
    of cfgKeyValuePair:
      let key = event.key.toLowerAscii
      let val = event.value

      case currentSection
      of "taxpayer":
        case key
        of "firstname": result.taxpayer.firstname = val
        of "lastname": result.taxpayer.lastname = val
        of "birthdate": result.taxpayer.birthdate = val
        of "idnr": result.taxpayer.idnr = val
        of "taxnumber": result.taxpayer.taxnumber = val
        of "income": result.taxpayer.income = val
        of "street": result.taxpayer.street = val
        of "housenumber": result.taxpayer.housenumber = val
        of "zip": result.taxpayer.zip = val
        of "city": result.taxpayer.city = val
        of "iban": result.taxpayer.iban = val
        of "religion": result.taxpayer.religion = val
        of "profession": result.taxpayer.profession = val
        of "kv_art", "kvart": result.taxpayer.kvArt = val
        of "rechtsform": result.taxpayer.rechtsform = val
        of "besteuerungsart": result.taxpayer.besteuerungsart = val
        else: discard
      of "kap":
        case key
        of "guenstigerpruefung":
          result.kap.guenstigerpruefung = val == "1" or val.toLowerAscii == "true"
        of "sparer_pauschbetrag", "sparerpauschbetrag":
          try: result.kap.sparerPauschbetrag = parseFloat(val)
          except ValueError: discard
        else: discard
      of "kid":
        case key
        of "firstname": currentKid.firstname = val
        of "birthdate": currentKid.birthdate = val
        of "idnr": currentKid.idnr = val
        else: discard
      else:
        discard
    of cfgOption:
      discard
    of cfgError:
      raise newException(ValueError, "Config parse error: " & event.msg)

  # Don't forget the last kid section
  if currentSection == "kid" and currentKid.firstname != "":
    result.kids.add(currentKid)

proc kidFirstnames*(conf: VikingConf): seq[string] =
  ## Return list of kid firstnames for deduction prefix matching.
  for kid in conf.kids:
    result.add(kid.firstname)

proc validateFields(tp: TaxpayerConf, fields: openArray[string]): seq[string] =
  ## Check that the given taxpayer fields are non-empty.
  for field in fields:
    let val = case field
      of "firstname": tp.firstname
      of "lastname": tp.lastname
      of "birthdate": tp.birthdate
      of "idnr": tp.idnr
      of "taxnumber": tp.taxnumber
      of "income": tp.income
      of "street": tp.street
      of "housenumber": tp.housenumber
      of "zip": tp.zip
      of "city": tp.city
      of "iban": tp.iban
      of "rechtsform": tp.rechtsform
      else: ""
    if val == "":
      result.add("taxpayer." & field & " not set in viking.conf")

proc validateForEst*(conf: VikingConf): seq[string] =
  result = conf.taxpayer.validateFields(
    ["firstname", "lastname", "birthdate", "taxnumber", "income", "iban"])
  if conf.taxpayer.income != "" and conf.taxpayer.income != "2" and conf.taxpayer.income != "3":
    result.add("taxpayer.income must be 2 (Gewerbebetrieb) or 3 (Selbstaendige Arbeit)")
  if conf.taxpayer.kvArt != "privat" and conf.taxpayer.kvArt != "gesetzlich":
    result.add("taxpayer.kv_art must be 'privat' or 'gesetzlich'")

proc validateForUstva*(conf: VikingConf): seq[string] =
  conf.taxpayer.validateFields(
    ["firstname", "lastname", "taxnumber", "street", "zip", "city"])

proc validateForUst*(conf: VikingConf): seq[string] =
  result = conf.taxpayer.validateFields(
    ["firstname", "lastname", "taxnumber", "street", "zip", "city"])
  if conf.taxpayer.besteuerungsart notin ["1", "2", "3"]:
    result.add("taxpayer.besteuerungsart must be 1, 2 or 3")

proc validateForNachricht*(conf: VikingConf): seq[string] =
  conf.taxpayer.validateFields(
    ["firstname", "lastname", "taxnumber", "street", "housenumber", "zip", "city"])

proc validateForBankverbindung*(conf: VikingConf): seq[string] =
  conf.taxpayer.validateFields(
    ["firstname", "lastname", "birthdate", "idnr", "taxnumber"])

proc validateForAbholung*(conf: VikingConf): seq[string] =
  conf.taxpayer.validateFields(["firstname", "lastname"])

proc validateForEuer*(conf: VikingConf): seq[string] =
  conf.taxpayer.validateFields(
    ["firstname", "lastname", "taxnumber", "street", "zip", "city", "rechtsform", "income"])
