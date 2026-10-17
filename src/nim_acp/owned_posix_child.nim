## Private POSIX descriptor/session ownership. Windows keeps std/osproc.
import std/[os, options, posix]

{.compile: "owned_posix_child.c".}
{.passL: "-pthread".}
const ownedHeader = currentSourcePath().parentDir / "owned_posix_child.h"
when defined(acpAdmissionDiagnostics):
  {.passC: "-DACP_ADMISSION_DIAGNOSTICS".}
  proc admissionSnapshotJson(): cstring
    {.importc: "acp_admission_snapshot_json", header: ownedHeader.}

type
  NativeOwnedChild {.importc: "acp_owned_posix_child", header: ownedHeader.} = object
  OwnedPosixChildObj = object
    handle: ptr NativeOwnedChild
  OwnedPosixChild* = ref OwnedPosixChildObj
  OwnedPosixCleanupError* = object of OSError
    child*: OwnedPosixChild
  OwnedPosixClosedError* = object of IOError

proc nativeFree(child: ptr NativeOwnedChild)
  {.importc: "acp_owned_free", header: ownedHeader.}
proc `=destroy`(child: var OwnedPosixChildObj) =
  # Only the last reference can release storage. Native free retains unresolved
  # process ownership rather than freeing a handle whose cleanup is uncertain.
  if child.handle != nil: nativeFree(child.handle)
proc spawn(image: cstring; argv, env: cstringArray; temporaryParent: cstring;
           child: ptr ptr NativeOwnedChild): cint
  {.importc: "acp_owned_spawn", header: ownedHeader.}
proc nativeRead(child: ptr NativeOwnedChild; value: ptr uint8): cint
  {.importc: "acp_owned_read", header: ownedHeader.}
proc nativeWrite(child: ptr NativeOwnedChild; value: cstring; size: csize_t): cint
  {.importc: "acp_owned_write_frame", header: ownedHeader.}
proc alive(child: ptr NativeOwnedChild): cint
  {.importc: "acp_owned_alive", header: ownedHeader.}
proc drained(child: ptr NativeOwnedChild): cint
  {.importc: "acp_owned_drained", header: ownedHeader.}
proc nativeClose(child: ptr NativeOwnedChild; gracefulMs, terminalMs: cint): cint
  {.importc: "acp_owned_close", header: ownedHeader.}

proc close*(child: OwnedPosixChild; gracefulMs = 1000; terminalMs = 2000) =
  if child == nil: return
  let code = nativeClose(child.handle, gracefulMs.cint, terminalMs.cint)
  if code != 0:
    var failure = newException(OwnedPosixCleanupError,
      "Owned ACP process cleanup incomplete: " & osErrorMsg(OSErrorCode(code)))
    failure.errorCode = code
    failure.child = child
    when defined(acpAdmissionDiagnostics):
      failure.msg.add "\nACP cleanup observation: " & $admissionSnapshotJson()
    raise failure

proc openOwnedPosixChild*(image: string; args: seq[string]): OwnedPosixChild =
  new(result)
  let argv = allocCStringArray(@[image] & args)
  defer: deallocCStringArray(argv)
  let code = spawn(image.cstring, argv, nil, getTempDir().cstring, addr result.handle)
  if code != 0:
    if result.handle != nil:
      try:
        result.close()
      except OwnedPosixCleanupError as failure:
        failure.msg.add "\nACP process startup failed with errno " & $code &
          ": " & osErrorMsg(OSErrorCode(code))
        when defined(acpAdmissionDiagnostics):
          failure.msg.add "\nACP admission observation: " & $admissionSnapshotJson()
        raise
    when defined(acpAdmissionDiagnostics):
      try:
        raiseOSError(OSErrorCode(code))
      except OSError as failure:
        failure.msg.add "\nACP admission observation: " & $admissionSnapshotJson()
        raise
    else:
      raiseOSError(OSErrorCode(code))

proc isPresent*(child: OwnedPosixChild): bool =
  if child == nil or child.handle == nil: return false
  let status = drained(child.handle)
  if status < 0: raiseOSError(OSErrorCode(-status))
  status == 0

proc isAlive*(child: OwnedPosixChild): bool =
  if child == nil: return false
  let status = alive(child.handle)
  if status < 0: raiseOSError(OSErrorCode(-status))
  status == 1

proc readByte*(child: OwnedPosixChild): Option[char] =
  if child == nil: raise newException(OwnedPosixClosedError, "Closed ACP process")
  var value: uint8
  let code = nativeRead(child.handle, addr value)
  if code == 1: return some(char(value))
  if code == 0: return none(char)
  if code == -ECANCELED:
    raise newException(OwnedPosixClosedError, "Closed ACP process")
  raiseOSError(OSErrorCode(-code))

proc writeFrame*(child: OwnedPosixChild; payload: string) =
  if child == nil: raise newException(OwnedPosixClosedError, "Closed ACP process")
  let frame = payload & "\n"
  let code = nativeWrite(child.handle, frame.cstring, frame.len.csize_t)
  if code == ECANCELED or code == EPIPE:
    raise newException(OwnedPosixClosedError, "Closed ACP process")
  if code != 0: raiseOSError(OSErrorCode(code))
