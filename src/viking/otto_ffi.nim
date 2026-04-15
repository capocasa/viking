## Otto Library FFI Bindings
## Bindings to the ELSTER OTTER client library (Otto)
## Otto = "Object transfer to (and from) OTTER"

import std/dynlib

type
  OttoInstanzHandle* = pointer
  OttoRueckgabepufferHandle* = pointer

var
  ottoLibHandle: pointer = nil

# Function pointer types
type
  OttoInstanzErzeugenProc = proc(
    logPfad: cstring, logCallback: pointer,
    logCallbackBenutzerdaten: pointer,
    instanz: ptr OttoInstanzHandle
  ): cint {.cdecl.}
  OttoInstanzFreigebenProc = proc(instanz: OttoInstanzHandle): cint {.cdecl.}
  OttoRueckgabepufferErzeugenProc = proc(
    instanz: OttoInstanzHandle,
    rueckgabepuffer: ptr OttoRueckgabepufferHandle
  ): cint {.cdecl.}
  OttoRueckgabepufferInhaltProc = proc(
    rueckgabepuffer: OttoRueckgabepufferHandle
  ): pointer {.cdecl.}
  OttoRueckgabepufferGroesseProc = proc(
    rueckgabepuffer: OttoRueckgabepufferHandle
  ): uint64 {.cdecl.}
  OttoRueckgabepufferFreigebenProc = proc(
    rueckgabepuffer: OttoRueckgabepufferHandle
  ): cint {.cdecl.}
  OttoDatenAbholenProc = proc(
    instanz: OttoInstanzHandle,
    objektId: cstring, objektGroesse: uint32,
    zertifikatsPfad: cstring, zertifikatsPasswort: cstring,
    herstellerId: cstring, abholzertifikat: cstring,
    abholDaten: OttoRueckgabepufferHandle
  ): cint {.cdecl.}
  OttoHoleFehlertextProc = proc(statuscode: cint): cstring {.cdecl.}

var
  pOttoInstanzErzeugen: OttoInstanzErzeugenProc = nil
  pOttoInstanzFreigeben: OttoInstanzFreigebenProc = nil
  pOttoRueckgabepufferErzeugen: OttoRueckgabepufferErzeugenProc = nil
  pOttoRueckgabepufferInhalt: OttoRueckgabepufferInhaltProc = nil
  pOttoRueckgabepufferGroesse: OttoRueckgabepufferGroesseProc = nil
  pOttoRueckgabepufferFreigeben: OttoRueckgabepufferFreigebenProc = nil
  pOttoDatenAbholen: OttoDatenAbholenProc = nil
  pOttoHoleFehlertext: OttoHoleFehlertextProc = nil

proc loadOttoLib*(path: string): bool =
  ottoLibHandle = loadLib(path)
  if ottoLibHandle == nil:
    return false

  pOttoInstanzErzeugen = cast[OttoInstanzErzeugenProc](symAddr(ottoLibHandle, "OttoInstanzErzeugen"))
  pOttoInstanzFreigeben = cast[OttoInstanzFreigebenProc](symAddr(ottoLibHandle, "OttoInstanzFreigeben"))
  pOttoRueckgabepufferErzeugen = cast[OttoRueckgabepufferErzeugenProc](symAddr(ottoLibHandle, "OttoRueckgabepufferErzeugen"))
  pOttoRueckgabepufferInhalt = cast[OttoRueckgabepufferInhaltProc](symAddr(ottoLibHandle, "OttoRueckgabepufferInhalt"))
  pOttoRueckgabepufferGroesse = cast[OttoRueckgabepufferGroesseProc](symAddr(ottoLibHandle, "OttoRueckgabepufferGroesse"))
  pOttoRueckgabepufferFreigeben = cast[OttoRueckgabepufferFreigebenProc](symAddr(ottoLibHandle, "OttoRueckgabepufferFreigeben"))
  pOttoDatenAbholen = cast[OttoDatenAbholenProc](symAddr(ottoLibHandle, "OttoDatenAbholen"))
  pOttoHoleFehlertext = cast[OttoHoleFehlertextProc](symAddr(ottoLibHandle, "OttoHoleFehlertext"))

  return pOttoInstanzErzeugen != nil and pOttoDatenAbholen != nil

proc unloadOttoLib*() =
  if ottoLibHandle != nil:
    unloadLib(ottoLibHandle)
    ottoLibHandle = nil

proc ottoInstanzErzeugen*(logPfad: string): tuple[rc: int, instanz: OttoInstanzHandle] =
  if pOttoInstanzErzeugen == nil:
    return (-1, nil)
  var instanz: OttoInstanzHandle = nil
  let logPtr = if logPfad == "": nil else: logPfad.cstring
  let rc = pOttoInstanzErzeugen(logPtr, nil, nil, addr instanz)
  result = (rc.int, instanz)

proc ottoInstanzFreigeben*(instanz: OttoInstanzHandle): int =
  if pOttoInstanzFreigeben == nil:
    return -1
  result = pOttoInstanzFreigeben(instanz).int

proc ottoRueckgabepufferErzeugen*(instanz: OttoInstanzHandle): tuple[rc: int, buf: OttoRueckgabepufferHandle] =
  if pOttoRueckgabepufferErzeugen == nil:
    return (-1, nil)
  var buf: OttoRueckgabepufferHandle = nil
  let rc = pOttoRueckgabepufferErzeugen(instanz, addr buf)
  result = (rc.int, buf)

proc ottoRueckgabepufferGroesse*(buf: OttoRueckgabepufferHandle): uint64 =
  if pOttoRueckgabepufferGroesse == nil or buf == nil:
    return 0
  result = pOttoRueckgabepufferGroesse(buf)

proc ottoRueckgabepufferInhalt*(buf: OttoRueckgabepufferHandle): pointer =
  if pOttoRueckgabepufferInhalt == nil or buf == nil:
    return nil
  result = pOttoRueckgabepufferInhalt(buf)

proc ottoRueckgabepufferFreigeben*(buf: OttoRueckgabepufferHandle): int =
  if pOttoRueckgabepufferFreigeben == nil or buf == nil:
    return -1
  result = pOttoRueckgabepufferFreigeben(buf).int

proc ottoDatenAbholen*(
  instanz: OttoInstanzHandle, objektId: string, objektGroesse: uint32,
  certPath: string, certPin: string, herstellerId: string,
  buf: OttoRueckgabepufferHandle
): int =
  if pOttoDatenAbholen == nil:
    return -1
  result = pOttoDatenAbholen(
    instanz, objektId.cstring, objektGroesse,
    certPath.cstring, certPin.cstring, herstellerId.cstring,
    nil, buf
  ).int

proc ottoHoleFehlertext*(code: int): string =
  if pOttoHoleFehlertext == nil:
    return "Unknown error (Otto library not loaded)"
  let text = pOttoHoleFehlertext(code.cint)
  if text == nil:
    return "Unknown error code: " & $code
  result = $text
