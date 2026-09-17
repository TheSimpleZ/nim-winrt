## The Windows Runtime ABI, by hand.
##
## WinRT is COM plus conventions, and every one of those conventions is
## positional: an interface is a pointer to a pointer to a table of function
## pointers, and which function you called is decided by counting. Nothing in
## this module is clever, and it must not become clever — it is the layer that
## has to match Microsoft's layout exactly or crash.
##
## Every call into the Windows Runtime reduces to what is here:
##
##   HSTRING -> activation factory -> QueryInterface -> call a vtable slot

import std/[os, strformat, strutils, widestrs]

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
    ## name is wrong; see `activationHint`.
  CLASS_E_CLASSNOTAVAILABLE* = cast[HRESULT](0x80040111'u32)

func succeeded*(hr: HRESULT): bool {.inline.} =
  ## The sign bit is the failure flag. This cannot be `hr == S_OK`, because
  ## `S_FALSE` is a success and several routes return it.
  hr >= 0

func failed*(hr: HRESULT): bool {.inline.} =
  hr < 0

func hex*(hr: HRESULT): string =
  &"0x{cast[uint32](hr):08X}"

func name*(hr: HRESULT): string =
  ## A readable name for the handful of HRESULTs that actually come up while
  ## bringing this layer up. Anything else prints as hex.
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
  else: hr.hex

type
  WinRtError* = object of CatchableError
    hr*: HRESULT

proc check*(hr: HRESULT, what: string) =
  ## Raise on failure, keeping the HRESULT attached so callers can branch on
  ## it rather than on message text.
  if hr.failed:
    var e = newException(WinRtError, &"{what} failed: {hr.name}")
    e.hr = hr
    raise e

# -------------------------------------------------------------------- imports

# Everything here comes out of `combase.dll`, which is part of Windows and so
# is always present — the same way `std/winlean` reaches `kernel32`. The shared
# attributes are pushed rather than repeated:
#
# * `raises: []` and `gcsafe` because a C function does neither. Saying so is
#   not decoration — without it Nim assumes every call through this boundary
#   might raise, and `=destroy` hooks that call `Release` will not compile.
# * `stdcall` because that is the Windows ABI for these.
#
# The Nim names are camelCase and the C names are not, so `importc` still
# carries the real name on each one.
{.push stdcall, dynlib: "combase", raises: [], gcsafe.}

proc roInitialize(initType: int32): HRESULT {.importc: "RoInitialize".}
proc roUninitialize() {.importc: "RoUninitialize".}
proc roActivateInstance(classId: HSTRING,
                        instance: ptr pointer): HRESULT
  {.importc: "RoActivateInstance".}
proc roGetActivationFactory(classId: HSTRING, iid: ptr GUID,
                            factory: ptr pointer): HRESULT
  {.importc: "RoGetActivationFactory".}

proc windowsCreateString(src: ptr Utf16Char, len: uint32,
                         res: ptr HSTRING): HRESULT
  {.importc: "WindowsCreateString".}
proc windowsDeleteString*(s: HSTRING): HRESULT
  {.importc: "WindowsDeleteString".}
proc windowsGetStringRawBuffer(s: HSTRING,
                               len: ptr uint32): ptr Utf16Char
  {.importc: "WindowsGetStringRawBuffer".}

{.pop.}

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

template withHString*(s: string, name, body: untyped) =
  ## Run `body` with `name` bound to a temporary HSTRING, deleted after.
  ## Every activation call needs one of these and forgetting the delete is
  ## the easiest leak in the codebase.
  block:
    let name = s.toHString
    try:
      body
    finally:
      discard windowsDeleteString(name)

# ------------------------------------------------------------------- vtables

# What every WinRT vtable slot is: a C function, called the Windows way, that
# neither raises a Nim exception nor touches Nim's heap.
#
# Declaring all three matters. `stdcall` is the ABI. `raises: []` is what lets
# `release` be called from a `=destroy` hook — a destructor may not raise, and
# without this Nim assumes anything reached through a function pointer might.
# `gcsafe` says the call cannot touch GC memory, which is true and which
# threaded code needs to know.
#
# A user pragma does not cross a module boundary in Nim — the stdlib `include`s
# such definitions rather than importing them — so generated code spells the
# same three out at each signature.
{.pragma: abi, stdcall, raises: [], gcsafe.}


type
  IInspectableVtbl* {.pure.} = object
    ## Every slot carries `abi`, so Nim knows a call through one neither raises
    ## nor touches the heap. That is what lets `release` be called from a
    ## `=destroy` hook, which must not raise.
    # --- IUnknown ---
    queryInterface*: proc(self: pointer, riid: ptr GUID,
                          ppv: ptr pointer): HRESULT {.abi.}
    addRef*: proc(self: pointer): uint32 {.abi.}
    release*: proc(self: pointer): uint32 {.abi.}
    # --- IInspectable ---
    getIids*: proc(self: pointer, count: ptr uint32,
                   iids: ptr ptr GUID): HRESULT {.abi.}
    getRuntimeClassName*: proc(self: pointer, name: ptr HSTRING): HRESULT {.abi.}
    getTrustLevel*: proc(self: pointer, level: ptr int32): HRESULT {.abi.}

  IInspectable* {.pure.} = object
    vtbl*: ptr IInspectableVtbl

const
  IID_IActivationFactory* = GUID(
    data1: 0x00000035'u32, data2: 0'u16, data3: 0'u16,
    data4: [0xC0'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])
    ## {00000035-0000-0000-C000-000000000046} — implemented by every activation
    ## factory, so it is the one IID that never needs generating.

func `==`*(a, b: GUID): bool =
  ## Field by field: a GUID is sixteen bytes with no padding, but Nim has no
  ## structural equality for an object containing an array without saying so.
  a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and
    a.data4 == b.data4

template vcall*(obj: pointer, slot: int, T: typedesc): untyped =
  ## The method at vtable index `slot`, as a callable of type `T`.
  ##
  ## This is the whole of how a WinRT call works: an interface pointer points
  ## at a pointer to an array of function pointers, and which method you called
  ## is decided by counting. `slot` comes from a generated `Slot_*` constant and
  ## `T` from the matching `Fn_*` type, so the two always agree.
  ##
  ## Slots are numbered *per interface*. Counting into the table of an
  ## interface that does not declare the method finds whatever sits at that
  ## index in a different table, which is a wrong call rather than an error —
  ## so pass the pointer `queryInterface` returned for the interface the method
  ## belongs to, not whichever pointer happens to be at hand.
  cast[T](cast[ptr ptr UncheckedArray[pointer]](obj)[][slot])

proc addRef*(obj: pointer): uint32 {.discardable, raises: [], gcsafe.} =
  ## Take a reference. Safe to call from a destructor, because `abi` says the
  ## slot cannot raise.
  if obj.isNil: return 0
  cast[ptr IInspectable](obj).vtbl.addRef(obj)

proc release*(obj: pointer): uint32 {.discardable, raises: [], gcsafe.} =
  ## Drop a reference, and the object with the last one.
  if obj.isNil: return 0
  cast[ptr IInspectable](obj).vtbl.release(obj)

func guid*(s: string): GUID =
  ## A GUID from its textual form, with or without braces.
  ##
  ## Most IIDs in this library are generated constants and never need this. It
  ## exists for the ones that cannot be: a parameterised interface such as
  ## `IVector<Something>` has no GUID in any metadata file — WinRT computes one
  ## by hashing a signature string — so those arrive as text.
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

# ------------------------------------------------- the runtime's lifetime

var runtimeAlive = true

proc endRuntime*() =
  ## Record that the hosting runtime has shut down and its objects are gone.
  ##
  ## Nothing in this package calls this: an application that only makes WinRT
  ## calls never has a runtime torn out from under it. A framework built on top
  ## does — a XAML projection calls this once `Application.Start` returns —
  ## after which a `Release` would reach through a vtable that has been freed.
  runtimeAlive = false

proc releaseIfLive*(obj: pointer) {.raises: [].} =
  ## Release, unless the runtime has already gone.
  ##
  ## Object wrappers release in their destructors, and a wrapper captured by an
  ## event handler's closure outlives the message loop: the closure sits in a
  ## module-level table that Nim destroys at *process* exit, by which time the
  ## framework has torn itself down. Releasing then corrupts the heap —
  ## `STATUS_HEAP_CORRUPTION`, raised after the program has otherwise finished
  ## successfully, which is about as hard to attribute as a fault gets.
  ##
  ## Skipping the release leaks, but only during the handful of microseconds
  ## between the runtime ending and the process ending, so nothing can observe
  ## it. That is the right trade against writing into freed memory.
  if runtimeAlive: release(obj)

proc addRefIfLive*(obj: pointer) {.raises: [].} =
  ## The counterpart of `releaseIfLive`, for the same reason: a wrapper copied
  ## while the runtime is being torn down must not touch the object either.
  if runtimeAlive: addRef(obj)

proc queryInterface*(obj: pointer, iid: GUID): pointer =
  ## `nil` when the object does not implement `iid`. Callers that care about
  ## *why* should call the vtable slot directly.
  if obj.isNil: return nil
  var id = iid
  let i = cast[ptr IInspectable](obj)
  if i.vtbl.queryInterface(obj, id.addr, result.addr).failed:
    result = nil

proc runtimeClassName*(obj: pointer): string =
  ## What a WinRT object says it is. Note that activation *factories* are
  ## allowed to answer `E_NOTIMPL` here and commonly do — that is not a fault.
  if obj.isNil: return "<nil>"
  let i = cast[ptr IInspectable](obj)
  var h: HSTRING
  let hr = i.vtbl.getRuntimeClassName(obj, h.addr)
  if hr.failed:
    return &"<unavailable: {hr.name}>"
  result = $h
  discard windowsDeleteString(h)

# ---------------------------------------------------------------- apartment

type
  Apartment* = enum
    multiThreaded = 0
    singleThreaded = 1
      ## What XAML and most UI frameworks require.

proc initApartment*(model = singleThreaded): HRESULT {.discardable.} =
  ## Idempotent in practice: a second call with the same model returns
  ## `S_FALSE`, and a call with a *different* model returns
  ## `RPC_E_CHANGED_MODE` without changing anything. Both are survivable, so
  ## this reports rather than raises.
  roInitialize(model.int32)

proc uninitApartment*() =
  ## Leave the apartment. Balances one `initApartment`, and is rarely worth
  ## calling: the apartment lasts as long as the thread, and a process that is
  ## exiting anyway has nothing to tidy up.
  roUninitialize()

# --------------------------------------------------------------- activation

proc activateInstance*(classId: string): pointer =
  ## Create a WinRT object that has a default constructor.
  ##
  ## Plenty of classes do not — anything static, and anything meant to be
  ## derived from, answers `E_NOTIMPL` here — which is why `activationFactory`
  ## is the call this library actually leans on.
  withHString(classId, id):
    let hr = roActivateInstance(id, result.addr)
    hr.check(&"RoActivateInstance({classId})")

var activationHint*: proc(classId: string): string {.nimcall, gcsafe.} = nil
  ## Called when a class cannot be activated, to add whatever the caller knows
  ## about why.
  ##
  ## `REGDB_E_CLASSNOTREG` sends people looking for a typo in the class id, and
  ## the class id is almost never the problem — Windows simply has nowhere to
  ## look. *Where* it should have looked depends on which runtime the class
  ## belongs to, and this module deliberately does not know: inbox Windows
  ## classes are always present, while a class from the Windows App SDK needs
  ## that SDK deployed. A package projecting one of those assigns this and says
  ## the useful thing. Left unset, the error is still accurate, just general.

proc defaultHint(classId: string): string =
  let exe = getAppFilename()
  let manifest = exe & ".manifest"
  "\n\nwinrt: " & classId & " could not be activated. Windows found no\n" &
    "registration for it, which means either the class belongs to a runtime\n" &
    "that is not deployed with this executable, or the executable has no\n" &
    "manifest naming it.\n\n" &
    "  executable: " & exe & "\n" &
    "  manifest:   " & manifest &
    (if fileExists(manifest): "  (present)" else: "  (MISSING)") & "\n\n" &
    "Note that Windows caches the activation context by executable path and\n" &
    "timestamp, including the result when no manifest was found, so adding one\n" &
    "afterwards changes nothing until the executable is rebuilt.\n"

proc activationFactory*(classId: string, iid = IID_IActivationFactory): pointer =
  ## Fetch a class's activation factory.
  ##
  ## This is where a deployment problem shows up, as `REGDB_E_CLASSNOTREG`:
  ## the class id is real, but nothing in the process knows where to find it.
  ## See `activationHint`.
  var id = iid
  withHString(classId, cid):
    let hr = roGetActivationFactory(cid, id.addr, result.addr)
    if hr == REGDB_E_CLASSNOTREG:
      var e = newException(WinRtError,
        &"RoGetActivationFactory({classId}) failed: {hr.name}" &
        (if activationHint.isNil: defaultHint(classId)
         else: activationHint(classId)))
      e.hr = hr
      raise e
    hr.check(&"RoGetActivationFactory({classId})")

proc tryActivationFactory*(classId: string,
                           iid = IID_IActivationFactory): tuple[factory: pointer, hr: HRESULT] =
  ## Non-raising variant, for probing whether a class is reachable at all.
  var id = iid
  withHString(classId, cid):
    result.hr = roGetActivationFactory(cid, id.addr, result.factory.addr)

# ------------------------------------------- what the generated API is built on
#
# These used to be emitted into every generated module, which meant eighteen
# copies of each and an `ambiguous call` the moment a program imported two of
# them. They are not specific to any namespace, so they live here.

template withIface*(obj: pointer, iid: GUID, what: string,
                   name, body: untyped) =
  ## Dispatch through the interface that declares the method, not
  ## through whichever one the caller happens to hold. Slots are
  ## numbered per interface, so the difference is a wrong function
  ## or a crash, never an error code.
  let name = queryInterface(obj, iid)
  if name.isNil:
    raise newException(WinRtError, "winui3: object is not a " & what)
  try:
    body
  finally:
    release(name)

template withStatics*(classId: string, iid: GUID,
                     name, body: untyped) =
  ## Dispatch to a class with no instances. Everything it can do
  ## lives on an interface reached through its activation factory,
  ## which combase caches, so this costs a lookup and an AddRef.
  let name = activationFactory(classId, iid)
  try:
    body
  finally:
    release(name)

proc takeString*(h: HSTRING): string =
  ## Convert an `[out] HSTRING` to a Nim string and delete it.
  ##
  ## A WinRT method that returns a string hands over ownership: the HSTRING is
  ## the caller's to delete. Reading a string property without this leaks one
  ## per call, which a soak test measures as a flat couple of hundred bytes an
  ## iteration — invisible in a demo and fatal in a program that runs for days.
  result = $h
  discard windowsDeleteString(h)

proc activateAs*(classId: string, iid: GUID): pointer =
  ## Activate a runtime class and narrow it to one of its interfaces.
  ##
  ## The activation reference is dropped once the typed one is held: they name
  ## the same object, and keeping both would leak it.
  let obj = activateInstance(classId)
  result = queryInterface(obj, iid)
  release(obj)
  if result.isNil:
    raise newException(WinRtError, "winrt: " & classId &
      " does not implement the expected interface")

proc composeAs*(classId: string, factoryIid, iid: GUID,
                slot: int): pointer =
  ## Construct a composable runtime class.
  ##
  ## Most of the visual tree is designed to be derived from, and answers
  ## `RoActivateInstance` with `E_NOTIMPL`. Such a class is built through its
  ## factory's `CreateInstance(outer, inner, value)` instead. Passing a nil
  ## `outer` says we are not deriving from it, and the `inner` handed back
  ## carries its own reference that is not ours to keep.
  type FnCompose = proc(self: pointer, outer: pointer, inner: ptr pointer,
                        value: ptr pointer): HRESULT {.stdcall, raises: [], gcsafe.}
  let factory = activationFactory(classId, factoryIid)
  var inner, instance: pointer
  try:
    vcall(factory, slot, FnCompose)(factory, nil, inner.addr, instance.addr)
      .check(classId & ".CreateInstance")
  finally:
    release(factory)
  if not inner.isNil and inner != instance:
    release(inner)
  result = queryInterface(instance, iid)
  release(instance)
  if result.isNil:
    raise newException(WinRtError, "winrt: " & classId &
      " does not implement the expected interface")

# IIDs of parameterised interfaces, computed from a signature
# string rather than read from metadata - see tools/piid.nim.
const IID_EventHandler_1_TracingStatusChangedEventArgs* = GUID(
    data1: 0x2BF27008'u32, data2: 0x2EB4'u16, data3: 0x5675'u16,
    data4: [0xB1'u8, 0xCD, 0xE9, 0x90, 0x6C, 0xC5, 0xCE, 0x64])
const IID_TypedEventHandler_2_IFileLoggingSession_LogFileGeneratedEventArgs* = GUID(
    data1: 0x0C6563B0'u32, data2: 0x9D8B'u16, data3: 0x5B60'u16,
    data4: [0x99'u8, 0x4B, 0xDE, 0xE1, 0x17, 0x4D, 0x1E, 0xFB])
const IID_TypedEventHandler_2_ILoggingChannel_Object* = GUID(
    data1: 0x52C9C2A1'u32, data2: 0x54A3'u16, data3: 0x5EF9'u16,
    data4: [0x9A'u8, 0xFF, 0x01, 0x4E, 0x7C, 0x45, 0x46, 0x55])


proc adopt*[T](p: pointer): T =
  ## Not called `owned`: Nim has a built-in `owned` type modifier, so `owned[T](p)`
  ## parses as a type the moment this is imported rather than declared locally.
  ## Adopt a pointer that is already ours — anything a getter, a factory or a
  ## QueryInterface returned, all of which hand over a reference.
  ##
  ## The counterpart of `borrowed`. Between them they cover every way a raw
  ## pointer becomes an object, and saying which one applies is the whole of
  ## the lifetime contract: adopt something you were only lent and the wrapper
  ## releases a reference it never took.
  T(p: p)

proc borrow*[T](p: pointer): T =
  ## Wrap a pointer we were *lent*, such as an event's sender or arguments.
  ##
  ## The wrapper releases on destruction, so adopting a borrowed pointer
  ## without this would over-release it and free an object still in use. A
  ## pointer that is already ours — anything a getter or a factory returned —
  ## is wrapped directly instead.
  if not p.isNil: addRef(p)
  T(p: p)

# --------------------------------------------------------------- collections

# `IVector<T>` and `IVectorView<T>` number their slots identically whatever `T`
# is — `GetAt` at 6 and `get_Size` at 7, after IInspectable's six — because a
# parameterised interface has one vtable layout and many instantiations. What
# differs per instantiation is the IID, and WinRT computes that by hashing a
# signature string rather than declaring it anywhere, so it arrives here as an
# argument the generator worked out.
const
  SlotCollectionGetAt = 6
  SlotCollectionSize = 7

type
  FnCollectionGetAt = proc(self: pointer, index: uint32,
                           item: ptr pointer): HRESULT {.stdcall, raises: [], gcsafe.}
  FnCollectionGetAtString = proc(self: pointer, index: uint32,
                                 item: ptr HSTRING): HRESULT {.stdcall, raises: [], gcsafe.}
  FnCollectionSize = proc(self: pointer,
                          size: ptr uint32): HRESULT {.stdcall, raises: [], gcsafe.}

template eachItem(collection: pointer, iid: GUID, body: untyped) =
  ## Walk a collection, with `view` and `i` bound inside `body`.
  ##
  ## Narrowing first is not optional: slots are numbered per interface, and the
  ## pointer a method handed back may be for a different one.
  let view {.inject.} = queryInterface(collection, iid)
  if not view.isNil:
    try:
      var count: uint32
      vcall(view, SlotCollectionSize, FnCollectionSize)(view, count.addr)
        .check("collection.get_Size")
      for i {.inject.} in 0'u32 ..< count:
        body
    finally:
      release(view)

proc toSeq*[T](collection: pointer, iid: GUID): seq[T] =
  ## Every element of a WinRT collection, as objects.
  ##
  ## Each `GetAt` hands over a reference, so the elements are adopted rather
  ## than retained again, and the collection itself stays the caller's to
  ## release.
  eachItem(collection, iid):
    var item: pointer
    vcall(view, SlotCollectionGetAt, FnCollectionGetAt)(view, i, item.addr)
      .check("collection.GetAt")
    result.add adopt[T](item)

proc toSeqString*(collection: pointer, iid: GUID): seq[string] =
  ## The same for a collection of strings, whose `GetAt` yields an HSTRING that
  ## is the caller's to delete.
  eachItem(collection, iid):
    var item: HSTRING
    vcall(view, SlotCollectionGetAt, FnCollectionGetAtString)(view, i, item.addr)
      .check("collection.GetAt")
    result.add takeString(item)
