## COM, as much of it as the Windows Runtime rests on.
##
## WinRT is COM plus conventions, and every one of those conventions is
## positional: an interface is a pointer to a pointer to a table of function
## pointers, and which function you called is decided by counting. Nothing in
## this module is clever, and it must not become clever — it is the layer that
## has to match Microsoft's layout exactly or crash.
##
## What is here: the `HRESULT` and its names, `GUID`, `HSTRING` and the Nim
## string either side of it, the two vtables every interface begins with,
## `Interface[V]` — an interface pointer held for the length of a scope — the
## text behind a failure, and the heap COM objects live on.

import std/[hashes, macros, options, strformat, strutils, tables, widestrs]

# A method that may not have a value returns `Option[T]` and a map reads as a
# `Table`, so anyone holding either needs those without a second import.
export options, tables

# ------------------------------------------------------------------- basics

type
  HRESULT* = int32

  GUID* {.pure.} = object
    data1*: uint32
    data2*: uint16
    data3*: uint16
    data4*: array[8, uint8]

  HSTRING* = distinct pointer
    ## Opaque, refcounted-by-the-runtime string handle. Not a Nim string, and
    ## not owned by the GC: whoever creates one deletes it.

  Char16* = distinct uint16
    ## A UTF-16 code unit, which is what WinRT means by `Char`. Distinct from
    ## `uint16` because the two are different types to the runtime: an
    ## `IVector<Char16>` and an `IVector<UInt16>` have different IIDs.

const
  S_OK* = HRESULT(0)
  S_FALSE* = HRESULT(1)
  E_NOTIMPL* = cast[HRESULT](0x80004001'u32)
  E_NOINTERFACE* = cast[HRESULT](0x80004002'u32)
  E_POINTER* = cast[HRESULT](0x80004003'u32)
  E_FAIL* = cast[HRESULT](0x80004005'u32)
  CO_E_NOTINITIALIZED* = cast[HRESULT](0x800401F0'u32)
  RPC_E_CHANGED_MODE* = cast[HRESULT](0x80010106'u32)
  REGDB_E_CLASSNOTREG* = cast[HRESULT](0x80040154'u32)
    ## Returned by `RoGetActivationFactory` when the class id does not resolve.
    ## In practice that means the class's runtime is not deployed, not that the
    ## name is wrong; see `activationHint` in `runtime`.
  CLASS_E_CLASSNOTAVAILABLE* = cast[HRESULT](0x80040111'u32)
  E_BOUNDS* = cast[HRESULT](0x8000000B'u32)
    ## An index past the end of a collection. WinRT uses this rather than
    ## failing generically, and callers test for it.
  E_CHANGED_STATE* = cast[HRESULT](0x8000000C'u32)
    ## A collection changed under an iterator.
  E_ILLEGAL_METHOD_CALL* = cast[HRESULT](0x8000000E'u32)
  E_ILLEGAL_STATE_CHANGE* = cast[HRESULT](0x8000000D'u32)
  RO_E_CLOSED* = cast[HRESULT](0x80000013'u32)
    ## The object was closed — `IClosable.Close` has already run.
  E_ABORT* = cast[HRESULT](0x80004004'u32)
  E_UNEXPECTED* = cast[HRESULT](0x8000FFFF'u32)
  E_ACCESSDENIED* = cast[HRESULT](0x80070005'u32)
  E_OUTOFMEMORY* = cast[HRESULT](0x8007000E'u32)
  E_INVALIDARG* = cast[HRESULT](0x80070057'u32)

func succeeded*(hr: HRESULT): bool {.inline.} =
  ## The sign bit is the failure flag. This cannot be `hr == S_OK`, because
  ## `S_FALSE` is a success and several routes return it.
  hr >= 0

func failed*(hr: HRESULT): bool {.inline.} =
  hr < 0

func hex*(hr: HRESULT): string =
  &"0x{cast[uint32](hr):08X}"

func name*(hr: HRESULT): string =
  ## A readable name for the HRESULTs that actually come up. Anything else
  ## prints as hex.
  case hr
  of S_OK: "S_OK"
  of S_FALSE: "S_FALSE"
  of E_NOTIMPL: "E_NOTIMPL"
  of E_NOINTERFACE: "E_NOINTERFACE"
  of E_POINTER: "E_POINTER"
  of E_FAIL: "E_FAIL"
  of CO_E_NOTINITIALIZED: "CO_E_NOTINITIALIZED"
  of RPC_E_CHANGED_MODE: "RPC_E_CHANGED_MODE"
  of REGDB_E_CLASSNOTREG: "REGDB_E_CLASSNOTREG"
  of CLASS_E_CLASSNOTAVAILABLE: "CLASS_E_CLASSNOTAVAILABLE"
  of E_BOUNDS: "E_BOUNDS"
  of E_CHANGED_STATE: "E_CHANGED_STATE"
  of E_ILLEGAL_METHOD_CALL: "E_ILLEGAL_METHOD_CALL"
  of E_ILLEGAL_STATE_CHANGE: "E_ILLEGAL_STATE_CHANGE"
  of RO_E_CLOSED: "RO_E_CLOSED"
  of E_ABORT: "E_ABORT"
  of E_UNEXPECTED: "E_UNEXPECTED"
  of E_ACCESSDENIED: "E_ACCESSDENIED"
  of E_OUTOFMEMORY: "E_OUTOFMEMORY"
  of E_INVALIDARG: "E_INVALIDARG"
  else: hr.hex

type
  WinRtError* = object of CatchableError
    ## A failing call. `hr` is the code, so a caller can branch on it rather
    ## than on the message, which carries what Windows had to say.
    hr*: HRESULT

proc check*(hr: HRESULT, what: string)
  ## Raise a `WinRtError` if `hr` is a failure. Defined with the failure
  ## machinery below, once the runtime it asks for the message is imported.

# -------------------------------------------------------------------- imports

# Everything here comes out of `combase.dll`, which is part of Windows and so
# is always present — the same way `std/winlean` reaches `kernel32`. The shared
# attributes are pushed rather than repeated:
#
# * `raises: []` and `gcsafe` because a C function does neither. Saying so is
#   not decoration — without it Nim assumes every call through this boundary
#   might raise, and `=destroy` hooks that call `Release` will not compile.
# * `stdcall` because that is the Windows ABI for these.
{.push stdcall, dynlib: "combase", raises: [], gcsafe.}

proc roInitialize*(initType: int32): HRESULT {.importc: "RoInitialize".}
proc roUninitialize*() {.importc: "RoUninitialize".}
proc roActivateInstance*(classId: HSTRING,
                         instance: ptr pointer): HRESULT
  {.importc: "RoActivateInstance".}
proc roGetActivationFactory*(classId: HSTRING, iid: ptr GUID,
                             factory: ptr pointer): HRESULT
  {.importc: "RoGetActivationFactory".}

proc windowsCreateString(src: ptr Utf16Char, len: uint32,
                         res: ptr HSTRING): HRESULT
  {.importc: "WindowsCreateString".}
proc windowsDeleteString*(s: HSTRING): HRESULT
  {.importc: "WindowsDeleteString".}
proc windowsDuplicateString*(s: HSTRING, dup: ptr HSTRING): HRESULT
  {.importc: "WindowsDuplicateString".}
proc windowsGetStringRawBuffer(s: HSTRING,
                               len: ptr uint32): ptr Utf16Char
  {.importc: "WindowsGetStringRawBuffer".}
proc windowsCompareStringOrdinal(a, b: HSTRING, order: ptr int32): HRESULT
  {.importc: "WindowsCompareStringOrdinal".}

proc coTaskMemAlloc(size: uint): pointer {.importc: "CoTaskMemAlloc".}
proc coTaskMemRealloc(p: pointer, size: uint): pointer
  {.importc: "CoTaskMemRealloc".}
proc coTaskMemFree(p: pointer) {.importc: "CoTaskMemFree".}

proc getRestrictedErrorInfo(info: ptr pointer): HRESULT
  {.importc: "GetRestrictedErrorInfo".}

{.pop.}

# Two more, for the text behind a failure: the BSTRs an error-info object
# hands out are freed through oleaut32, and the system's own description of
# an HRESULT comes from kernel32.
proc sysFreeString(s: pointer)
  {.importc: "SysFreeString", stdcall, dynlib: "oleaut32", raises: [], gcsafe.}
proc formatMessageW(flags: uint32, source: pointer, messageId, languageId: uint32,
                    buffer: ptr pointer, size: uint32, args: pointer): uint32
  {.importc: "FormatMessageW", stdcall, dynlib: "kernel32", raises: [], gcsafe.}
proc localFree(p: pointer): pointer
  {.importc: "LocalFree", stdcall, dynlib: "kernel32", raises: [], gcsafe.}

# -------------------------------------------------------------------- strings

proc toHString*(s: string): HSTRING =
  ## Nim string -> HSTRING. The caller owns the result.
  ##
  ## The length is in UTF-16 code units excluding the terminator, which is why
  ## `wide.len` is used and not `s.len`: they diverge the moment the string
  ## leaves ASCII. The buffer is copied, so the wide string may die after.
  let wide = newWideCString(s)
  let buf = wide.toWideCString
  if buf.isNil:
    return HSTRING(nil)
  windowsCreateString(cast[ptr Utf16Char](buf), uint32(wide.len), result.addr)
    .check("WindowsCreateString")

proc `$`*(h: HSTRING): string =
  ## HSTRING -> Nim string. The empty string is the *null* handle rather than
  ## a zero-length buffer, so the nil check is the normal path.
  if pointer(h).isNil:
    return ""
  var length: uint32
  let buf = windowsGetStringRawBuffer(h, length.addr)
  if buf.isNil or length == 0:
    return ""
  # HSTRING buffers are guaranteed NUL-terminated, so scanning is safe.
  $cast[WideCString](buf)

proc takeString*(h: HSTRING): string =
  ## An `[out] HSTRING` as a Nim string, the handle deleted.
  ##
  ## A WinRT method that returns a string hands over ownership: the HSTRING is
  ## the caller's to delete. Reading a string property without this leaks one
  ## per call, which a soak test measures as a flat couple of hundred bytes an
  ## iteration — invisible in a demo and fatal in a program that runs for days.
  result = $h
  discard windowsDeleteString(h)

proc sameString*(a, b: HSTRING): bool =
  ## Whether two HSTRINGs hold the same text, without converting either.
  ## For code that may run on a thread Nim did not start, where building a
  ## Nim string is not an option.
  var order: int32
  windowsCompareStringOrdinal(a, b, order.addr) == S_OK and order == 0

type WinRtString* = object
  ## An HSTRING that is somebody's to delete: a copy duplicates it and
  ## destruction deletes it. Two things are one of these — the string argument
  ## a generated wrapper holds for the length of a call, and a string field of
  ## a struct as it crosses the ABI, since a struct crosses by value with its
  ## exact layout and a `string` is not the width of a handle. Everywhere a
  ## person reads or writes a string, it is a `string`.
  h: HSTRING

proc `=destroy`*(x: var WinRtString) =
  if not pointer(x.h).isNil: discard windowsDeleteString(x.h)

proc `=copy`*(dst: var WinRtString, src: WinRtString) =
  if pointer(dst.h) == pointer(src.h): return
  `=destroy`(dst)
  wasMoved(dst)
  if not pointer(src.h).isNil:
    discard windowsDuplicateString(src.h, dst.h.addr)

proc `=sink`*(dst: var WinRtString, src: WinRtString) =
  `=destroy`(dst)
  wasMoved(dst)
  dst.h = src.h

proc toWinRtString*(s: string): WinRtString =
  WinRtString(h: toHString(s))

proc handle*(s: WinRtString): HSTRING {.inline.} =
  ## The handle itself, still owned by `s`: what a call takes.
  s.h

proc `$`*(s: WinRtString): string = $s.h

proc hash*(s: WinRtString): Hash = hash($s)

# -------------------------------------------------------------------- enums

proc enumName*[T: enum](v: T): string =
  ## The member's name, or `T(n)` for a value the metadata did not have.
  ##
  ## What every generated enum's `$` is. Windows can hand back a member added
  ## after this metadata was cut, and the standard `$` renders one of those as
  ## the empty string — which is the one answer that hides what happened.
  result = system.`$`(v)
  if result.len == 0: result = $T & "(" & $ord(v) & ")"

# ---------------------------------------------------------------------- GUIDs

func `==`*(a, b: GUID): bool =
  ## Field by field: a GUID is sixteen bytes with no padding, but Nim has no
  ## structural equality for an object containing an array without saying so.
  a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and
    a.data4 == b.data4

proc hash*(g: GUID): Hash =
  ## So a `GUID` can key a `Table`: several WinRT maps are keyed by one.
  hashData(g.unsafeAddr, sizeof(GUID))

func guid*(s: string): GUID =
  ## A GUID from its textual form, with or without braces.
  ##
  ## Every IID in this library is written this way — `guid"..."` in a `const`,
  ## evaluated at compile time — because that is how a GUID is written
  ## everywhere else, and a reader can compare it with the SDK headers.
  ##
  ## The first three fields are little-endian numbers written big-endian, which
  ## is why they are parsed as integers while the last eight are taken as bytes.
  let h = s.strip(chars = {'{', '}', ' '}).replace("-", "")
  doAssert h.len == 32, "winrt: not a GUID: " & s
  result.data1 = uint32(parseHexInt(h[0 ..< 8]))
  result.data2 = uint16(parseHexInt(h[8 ..< 12]))
  result.data3 = uint16(parseHexInt(h[12 ..< 16]))
  for i in 0 ..< 8:
    result.data4[i] = uint8(parseHexInt(h[16 + i * 2 ..< 18 + i * 2]))

func `$`*(g: GUID): string =
  ## The textual form, upper case, without braces.
  result = toHex(g.data1, 8) & "-" & toHex(g.data2, 4) & "-" & toHex(g.data3, 4) & "-"
  for i in 0 .. 7:
    result.add toHex(g.data4[i], 2)
    if i == 1: result.add "-"

const
  IID_IUnknown* = guid"00000000-0000-0000-C000-000000000046"
    ## The root of COM. Every object answers for it.
  IID_IInspectable* = guid"AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90"
    ## The root of every WinRT interface, as IUnknown is the root of every
    ## COM one.
  IID_IActivationFactory* = guid"00000035-0000-0000-C000-000000000046"
    ## Implemented by every activation factory.
  IID_IAgileObject* = guid"94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"
    ## A marker with no methods. An object answering for it tells COM it may
    ## be called from any thread without marshalling, so the runtime invokes
    ## it on whatever thread it is already on instead of trying to reach the
    ## one that handed it over.

# ------------------------------------------------------------------- vtables

include ./abidef

# A COM interface is a table of function pointers, and an interface pointer
# points at a pointer to that table. Here a table is a Nim object whose fields
# are the methods in vtable order: the generated `IUriRuntimeClassVtbl` derives
# from `IInspectableVtbl` and lists its own methods after the six every WinRT
# interface begins with, so `it.vtbl.get_Host(it.raw, ...)` is a type-checked
# field call rather than an index and a cast. Every field carries `abi`, so
# Nim knows a call through one neither raises nor touches the heap — which is
# what lets `release` be called from a `=destroy` hook.
#
# These are also the head of every vtable this library *implements*: getting
# the order or the count wrong is the mistake that puts a caller's `GetAt`
# through `Release`.

type
  IUnknownVtbl* {.pure, inheritable.} = object
    ## COM's three. A delegate's vtable derives from this.
    queryInterface*: proc(self: pointer, riid: ptr GUID,
                          ppv: ptr pointer): HRESULT {.abi.}
    addRef*: proc(self: pointer): uint32 {.abi.}
    release*: proc(self: pointer): uint32 {.abi.}

  IInspectableVtbl* {.pure, inheritable.} = object of IUnknownVtbl
    ## WinRT's three more. Every interface's vtable derives from this.
    getIids*: proc(self: pointer, count: ptr uint32,
                   iids: ptr ptr GUID): HRESULT {.abi.}
    getRuntimeClassName*: proc(self: pointer,
                               name: ptr HSTRING): HRESULT {.abi.}
    getTrustLevel*: proc(self: pointer, level: ptr int32): HRESULT {.abi.}

func interfaceName*(V: typedesc): string =
  ## `IUriRuntimeClass` for `IUriRuntimeClassVtbl`: the name a vtable type
  ## shares with the interface, and with the API's object for it.
  let n = $V
  if n.endsWith("Vtbl"): n[0 ..< n.len - 4] else: n

# ------------------------------------------------------ what a type is called

# A type's IID and its metadata name are constants the generated modules
# declare beside the type: `IID_IUriRuntimeClass`, `ClassName_Uri`,
# `DefaultIid_Uri`, `RuntimeName_BatteryStatus`. The four macros below turn a
# type into the name of its constant, so that generic code can ask `iid(V)`
# for any `V`. They are macros, the only ones in this library, because the
# alternatives were measured: a proc overload per interface costs five
# seconds of compile time in every program, and a table searched at compile
# time costs ten milliseconds per lookup.

proc constantFor(prefix: string, T: NimNode): NimNode =
  ## The identifier `prefix & <T's name>`, with `Vtbl` dropped so the vtable
  ## type and the API's object for one interface name the same constant, and
  ## a generic instantiation reduced to the generic.
  var t = T.getTypeInst
  if t.kind == nnkBracketExpr and t[0].eqIdent("typeDesc"): t = t[1]
  while t.kind == nnkBracketExpr: t = t[0]
  var name = t.repr
  if name.endsWith("Vtbl"): name = name[0 ..< name.len - 4]
  ident(prefix & name)

macro iid*(T: typedesc): GUID =
  ## The IID of the interface or delegate `T` names: `iid(IUriRuntimeClassVtbl)`
  ## and `iid(IUriRuntimeClass)` are both `IID_IUriRuntimeClass`. For an
  ## instantiation of a parameterised interface, `iid(IVectorVtbl[Uri])`, the
  ## IID is hashed from the generic's own and its arguments' signatures.
  var t = T.getTypeInst
  if t.kind == nnkBracketExpr and t[0].eqIdent("typeDesc"): t = t[1]
  if t.kind != nnkBracketExpr:
    return constantFor("IID_", T)
  let hash = newCall(ident("pinterfaceIid"), constantFor("IID_", T))
  for i in 1 ..< t.len:
    # `typeof(arg)`: the argument as `getTypeInst` hands it over would be
    # read as a value of that type, not the type, where this expands.
    hash.add newCall(ident("typeSignature"), newNimNode(nnkTypeOfExpr).add(t[i]))
  # A `const`, so the compiler takes the hash once for each instantiation and
  # the call site holds the GUID rather than computing a SHA-1 every time.
  let computed = genSym(nskConst, "iid")
  quote do:
    const `computed` = `hash`
    `computed`

macro className*(T: typedesc): string =
  ## The metadata name of the class `T`: `Windows.Foundation.Uri`.
  constantFor("ClassName_", T)

macro defaultIid*(T: typedesc): GUID =
  ## The IID of the class `T`'s default interface, which is what an instance
  ## of it is handed over as.
  constantFor("DefaultIid_", T)

macro runtimeName*(T: typedesc): string =
  ## The metadata name of the enum or struct `T`:
  ## `Windows.Devices.Power.BatteryStatus`.
  constantFor("RuntimeName_", T)

proc inspectable(obj: pointer): ptr IInspectableVtbl {.inline.} =
  cast[ptr ptr IInspectableVtbl](obj)[]

proc addRef*(obj: pointer): uint32 {.discardable, raises: [], gcsafe.} =
  ## Take a reference. Safe to call from a destructor, because `abi` says the
  ## slot cannot raise.
  if obj.isNil: return 0
  inspectable(obj).addRef(obj)

proc release*(obj: pointer): uint32 {.discardable, raises: [], gcsafe.} =
  ## Drop a reference, and the object with the last one.
  if obj.isNil: return 0
  inspectable(obj).release(obj)

proc queryInterface*(obj: pointer, iid: GUID): pointer =
  ## `nil` when the object does not implement `iid`. Callers that care about
  ## *why* should call the vtable slot directly.
  if obj.isNil: return nil
  var id = iid
  if inspectable(obj).queryInterface(obj, id.addr, result.addr).failed:
    result = nil

proc runtimeClassName*(obj: pointer): string =
  ## What a WinRT object says it is. Note that activation *factories* are
  ## allowed to answer `E_NOTIMPL` here and commonly do — that is not a fault.
  if obj.isNil: return "<nil>"
  var h: HSTRING
  let hr = inspectable(obj).getRuntimeClassName(obj, h.addr)
  if hr.failed:
    return &"<unavailable: {hr.name}>"
  result = $h
  discard windowsDeleteString(h)

# ----------------------------------------------------------------- interfaces

type
  InterfaceOwner* = object
    ## The reference an `Interface` holds, and the hooks that hold it: one
    ## object with one set of hooks, rather than a set per interface type,
    ## which is what makes eight thousand instantiations cheap to compile.
    raw*: pointer

  Interface*[V] = object
    ## One interface of an object, held for as long as the value lives: the
    ## pointer `QueryInterface` returned, released when this goes out of
    ## scope. `V` is the vtable type, so `it.vtbl.get_Host(it.raw, ...)` can
    ## only name methods that interface has — which matters, because methods
    ## are numbered per interface and calling one through the wrong interface
    ## is a wrong function or a crash, never an error code.
    owner*: InterfaceOwner

proc `=destroy`*(x: var InterfaceOwner) =
  if x.raw != nil: release(x.raw)

proc `=copy`*(dst: var InterfaceOwner, src: InterfaceOwner) =
  if dst.raw == src.raw: return
  `=destroy`(dst)
  wasMoved(dst)
  dst.raw = src.raw
  addRef(dst.raw)

proc `=sink`*(dst: var InterfaceOwner, src: InterfaceOwner) =
  `=destroy`(dst)
  wasMoved(dst)
  dst.raw = src.raw

proc raw*[V](it: Interface[V]): pointer {.inline.} =
  ## The interface pointer itself: what a method takes as `self`.
  it.owner.raw

func isNil*(it: Interface): bool {.inline.} = it.owner.raw.isNil

proc vtbl*[V](it: Interface[V]): ptr V {.inline.} =
  ## The methods, as the object lays them out.
  cast[ptr ptr V](it.owner.raw)[]

proc tryQueryInterface*[V](obj: pointer): Interface[V] =
  ## The interface `V` of `obj`, or one that `isNil` if it has none.
  Interface[V](owner: InterfaceOwner(raw: queryInterface(obj, iid(V))))

proc queryInterface*[V](obj: pointer): Interface[V] =
  ## The interface `V` of `obj`. Raises if the object does not implement it,
  ## naming both, because at the ABI that would otherwise be a call through
  ## the wrong vtable.
  result = tryQueryInterface[V](obj)
  if result.isNil:
    raise newException(WinRtError, "winrt: " & runtimeClassName(obj) &
      " does not implement " & interfaceName(V))

# ----------------------------------------------------------------- failures

# A WinRT method that fails usually says why: it calls `RoOriginateError` with
# a message before returning the HRESULT, and the runtime keeps that message
# on the calling thread until someone asks. C++/WinRT asks; so does this.
# Reading it consumes it, so it is read exactly once, right after the call
# that failed, by `check`.

const IID_IRestrictedErrorInfo = guid"82BA7092-4C88-427D-A7BC-16DD93FEB67E"

type IRestrictedErrorInfoVtbl {.pure.} = object of IUnknownVtbl
  getErrorDetails: proc(self: pointer, description: ptr pointer,
                        error: ptr HRESULT, restricted: ptr pointer,
                        capabilitySid: ptr pointer): HRESULT {.abi.}
  getReference: proc(self: pointer, reference: ptr pointer): HRESULT {.abi.}

proc takeBstr(b: pointer): string =
  ## A BSTR is NUL-terminated UTF-16 that is the caller's to free.
  if b.isNil: return ""
  result = $cast[WideCString](b)
  sysFreeString(b)

proc errorMessage*(hr: HRESULT): string =
  ## What Windows had to say about the failure that just happened on this
  ## thread, if anything, and otherwise the system's description of the code.
  ##
  ## The runtime's message is only taken if it was attached to *this* code:
  ## a stale one from an earlier failure would describe the wrong thing.
  var raw: pointer
  if getRestrictedErrorInfo(raw.addr) == S_OK and not raw.isNil:
    let info = tryQueryInterface[IRestrictedErrorInfoVtbl](raw)
    release(raw)
    if not info.isNil:
      var description, restricted, sid: pointer
      var code: HRESULT
      if info.vtbl.getErrorDetails(info.raw, description.addr, code.addr,
                                   restricted.addr, sid.addr) == S_OK:
        let r = takeBstr(restricted)
        let d = takeBstr(description)
        discard takeBstr(sid)
        if code == hr:
          result = if r.len > 0: r else: d
      if result.len > 0: return result.strip
  # FORMAT_MESSAGE_ALLOCATE_BUFFER or FROM_SYSTEM or IGNORE_INSERTS.
  var buf: pointer
  let n = formatMessageW(0x1300, nil, cast[uint32](hr), 0, buf.addr, 0, nil)
  if n > 0 and not buf.isNil:
    result = ($cast[WideCString](buf)).strip
    discard localFree(buf)

proc check*(hr: HRESULT, what: string) =
  if hr.failed:
    let detail = errorMessage(hr)
    var e = newException(WinRtError,
      what & " failed: " & hr.name & (if detail.len > 0: ": " & detail else: ""))
    e.hr = hr
    raise e

# --------------------------------------------------------------- COM heap

# Every COM object this library implements — a delegate, a collection handed
# to the runtime, a boxed value, a completion handler — lives on the COM heap,
# not Nim's. The runtime may release it, iterate it or invoke it on a thread
# Nim never started, and Nim's allocator keeps its state per thread: on a
# thread it has not set up, the first allocation dereferences an uninitialised
# region and the process dies. `CoTaskMemAlloc` has no such state; it is the
# heap COM itself uses, which is also what a received array comes back on.

proc comAlloc*(size: Natural): pointer =
  ## Zeroed memory on the COM heap. Safe from any thread.
  result = coTaskMemAlloc(uint(size))
  if result.isNil: raise newException(OutOfMemDefect, "winrt: CoTaskMemAlloc")
  zeroMem(result, size)

proc comRealloc*(p: pointer, oldSize, newSize: Natural): pointer =
  ## `p` grown to `newSize`, the new tail zeroed. Safe from any thread.
  result = coTaskMemRealloc(p, uint(newSize))
  if result.isNil: raise newException(OutOfMemDefect, "winrt: CoTaskMemRealloc")
  if newSize > oldSize:
    zeroMem(cast[pointer](cast[uint](result) + uint(oldSize)), newSize - oldSize)

proc comFree*(p: pointer) {.inline, raises: [], gcsafe.} =
  ## Give back what `comAlloc` handed out. Safe from any thread, nil included.
  coTaskMemFree(p)
