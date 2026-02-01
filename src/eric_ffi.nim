## ERiC C Library FFI Bindings
## Bindings to the German ELSTER Rich Client (ERiC) library

const
  ERIC_VALIDIERE* = 2'u32
  ERIC_SENDE* = 4'u32
  ERIC_DRUCKE* = 32'u32

type
  EricRueckgabepuffer* = pointer
  EricZertifikatHandle* = uint32

  EricVerschluesselungsParameterT* {.bycopy.} = object
    version*: uint32           # Must be 3
    zertifikatHandle*: EricZertifikatHandle
    pin*: cstring

  EricDruckParameterT* {.bycopy.} = object
    version*: uint32           # Must be 4
    vorschau*: uint32          # 0 = no preview, 1 = preview
    ersteSeite*: uint32        # First page number
    duplexDruck*: uint32       # 0 = simplex, 1 = duplex
    pdfName*: cstring          # Output PDF path or nil
    fussText*: cstring         # Footer text or nil

var
  ericLibHandle: pointer = nil
  ericLibPath: string = ""

# Function pointer types
type
  EricInitialisiereProc = proc(pluginPath: cstring, logPath: cstring): cint {.cdecl.}
  EricBeendeProc = proc(): cint {.cdecl.}
  EricBearbeiteVorgangProc = proc(
    xml: cstring,
    datenartVersion: cstring,
    flags: uint32,
    druckParam: ptr EricDruckParameterT,
    cryptParam: ptr EricVerschluesselungsParameterT,
    transferHandle: ptr uint32,
    rueckgabePuffer: EricRueckgabepuffer,
    serverantwortPuffer: EricRueckgabepuffer
  ): cint {.cdecl.}
  EricRueckgabepufferErzeugenProc = proc(): EricRueckgabepuffer {.cdecl.}
  EricRueckgabepufferInhaltProc = proc(buf: EricRueckgabepuffer): cstring {.cdecl.}
  EricRueckgabepufferFreigabeProc = proc(buf: EricRueckgabepuffer): cint {.cdecl.}
  EricHoleFehlerTextProc = proc(code: cint, buf: EricRueckgabepuffer): cint {.cdecl.}
  EricCreateTH_Proc = proc(
    zertifikatPfad: cstring,
    passwort: cstring,
    zertifikatHandle: ptr EricZertifikatHandle
  ): cint {.cdecl.}
  EricCloseHandleTH_Proc = proc(zertifikatHandle: EricZertifikatHandle): cint {.cdecl.}

# Function pointers
var
  pEricInitialisiere: EricInitialisiereProc = nil
  pEricBeende: EricBeendeProc = nil
  pEricBearbeiteVorgang: EricBearbeiteVorgangProc = nil
  pEricRueckgabepufferErzeugen: EricRueckgabepufferErzeugenProc = nil
  pEricRueckgabepufferInhalt: EricRueckgabepufferInhaltProc = nil
  pEricRueckgabepufferFreigabe: EricRueckgabepufferFreigabeProc = nil
  pEricHoleFehlerText: EricHoleFehlerTextProc = nil
  pEricCreateTH: EricCreateTH_Proc = nil
  pEricCloseHandleTH: EricCloseHandleTH_Proc = nil

# Dynamic library loading
when defined(windows):
  import std/dynlib
  proc loadEricLib(path: string): bool =
    ericLibHandle = loadLib(path)
    if ericLibHandle == nil:
      return false
    ericLibPath = path

    pEricInitialisiere = cast[EricInitialisiereProc](symAddr(ericLibHandle, "EricInitialisiere"))
    pEricBeende = cast[EricBeendeProc](symAddr(ericLibHandle, "EricBeende"))
    pEricBearbeiteVorgang = cast[EricBearbeiteVorgangProc](symAddr(ericLibHandle, "EricBearbeiteVorgang"))
    pEricRueckgabepufferErzeugen = cast[EricRueckgabepufferErzeugenProc](symAddr(ericLibHandle, "EricRueckgabepufferErzeugen"))
    pEricRueckgabepufferInhalt = cast[EricRueckgabepufferInhaltProc](symAddr(ericLibHandle, "EricRueckgabepufferInhalt"))
    pEricRueckgabepufferFreigabe = cast[EricRueckgabepufferFreigabeProc](symAddr(ericLibHandle, "EricRueckgabepufferFreigabe"))
    pEricHoleFehlerText = cast[EricHoleFehlerTextProc](symAddr(ericLibHandle, "EricHoleFehlerText"))
    pEricCreateTH = cast[EricCreateTH_Proc](symAddr(ericLibHandle, "EricCreateTH"))
    pEricCloseHandleTH = cast[EricCloseHandleTH_Proc](symAddr(ericLibHandle, "EricCloseHandleTH"))

    return pEricInitialisiere != nil and pEricBeende != nil
else:
  import std/dynlib
  proc loadEricLib*(path: string): bool =
    ericLibHandle = loadLib(path)
    if ericLibHandle == nil:
      return false
    ericLibPath = path

    pEricInitialisiere = cast[EricInitialisiereProc](symAddr(ericLibHandle, "EricInitialisiere"))
    pEricBeende = cast[EricBeendeProc](symAddr(ericLibHandle, "EricBeende"))
    pEricBearbeiteVorgang = cast[EricBearbeiteVorgangProc](symAddr(ericLibHandle, "EricBearbeiteVorgang"))
    pEricRueckgabepufferErzeugen = cast[EricRueckgabepufferErzeugenProc](symAddr(ericLibHandle, "EricRueckgabepufferErzeugen"))
    pEricRueckgabepufferInhalt = cast[EricRueckgabepufferInhaltProc](symAddr(ericLibHandle, "EricRueckgabepufferInhalt"))
    pEricRueckgabepufferFreigabe = cast[EricRueckgabepufferFreigabeProc](symAddr(ericLibHandle, "EricRueckgabepufferFreigabe"))
    pEricHoleFehlerText = cast[EricHoleFehlerTextProc](symAddr(ericLibHandle, "EricHoleFehlerText"))
    pEricCreateTH = cast[EricCreateTH_Proc](symAddr(ericLibHandle, "EricCreateTH"))
    pEricCloseHandleTH = cast[EricCloseHandleTH_Proc](symAddr(ericLibHandle, "EricCloseHandleTH"))

    return pEricInitialisiere != nil and pEricBeende != nil

proc unloadEricLib*() =
  if ericLibHandle != nil:
    unloadLib(ericLibHandle)
    ericLibHandle = nil

# Wrapper functions
proc ericInitialisiere*(pluginPath, logPath: string): int =
  if pEricInitialisiere == nil:
    return -1
  result = pEricInitialisiere(pluginPath.cstring, logPath.cstring).int

proc ericBeende*(): int =
  if pEricBeende == nil:
    return -1
  result = pEricBeende().int

proc ericBearbeiteVorgang*(
  xml: string,
  datenartVersion: string,
  flags: uint32,
  druckParam: ptr EricDruckParameterT,
  cryptParam: ptr EricVerschluesselungsParameterT,
  transferHandle: ptr uint32,
  rueckgabePuffer: EricRueckgabepuffer,
  serverantwortPuffer: EricRueckgabepuffer
): int =
  if pEricBearbeiteVorgang == nil:
    return -1
  result = pEricBearbeiteVorgang(
    xml.cstring,
    datenartVersion.cstring,
    flags,
    druckParam,
    cryptParam,
    transferHandle,
    rueckgabePuffer,
    serverantwortPuffer
  ).int

proc ericRueckgabepufferErzeugen*(): EricRueckgabepuffer =
  if pEricRueckgabepufferErzeugen == nil:
    return nil
  result = pEricRueckgabepufferErzeugen()

proc ericRueckgabepufferInhalt*(buf: EricRueckgabepuffer): string =
  if pEricRueckgabepufferInhalt == nil or buf == nil:
    return ""
  let cs = pEricRueckgabepufferInhalt(buf)
  if cs == nil:
    return ""
  result = $cs

proc ericRueckgabepufferFreigabe*(buf: EricRueckgabepuffer): int =
  if pEricRueckgabepufferFreigabe == nil or buf == nil:
    return -1
  result = pEricRueckgabepufferFreigabe(buf).int

proc ericHoleFehlerText*(code: int): string =
  if pEricHoleFehlerText == nil:
    return "Unknown error (ERiC library not loaded)"
  let buf = ericRueckgabepufferErzeugen()
  if buf == nil:
    return "Unknown error (buffer creation failed)"
  defer: discard ericRueckgabepufferFreigabe(buf)
  let rc = pEricHoleFehlerText(code.cint, buf)
  if rc != 0:
    return "Unknown error code: " & $code
  result = ericRueckgabepufferInhalt(buf)

proc ericCreateTH*(zertifikatPfad: string, passwort: string): tuple[rc: int, handle: EricZertifikatHandle] =
  if pEricCreateTH == nil:
    return (-1, 0)
  var handle: EricZertifikatHandle = 0
  let rc = pEricCreateTH(zertifikatPfad.cstring, passwort.cstring, addr handle)
  result = (rc.int, handle)

proc ericCloseHandleTH*(handle: EricZertifikatHandle): int =
  if pEricCloseHandleTH == nil:
    return -1
  result = pEricCloseHandleTH(handle).int
