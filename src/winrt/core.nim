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
##
## The second half of the module is what the generated API is built on: how an
## object is held, how a collection or a map is read, how a value crosses in an
## `IReference<T>`, how an array comes back.

import std/[hashes, macros, options, os, strformat, strutils, tables, widestrs]

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
  E_BOUNDS* = cast[HRESULT](0x8000000B'u32)
    ## An index past the end of a collection. WinRT uses this rather than
    ## failing generically, and callers test for it.
  E_CHANGED_STATE* = cast[HRESULT](0x8000000C'u32)
    ## A collection changed under an iterator.

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
  of E_BOUNDS: "E_BOUNDS"
  of E_CHANGED_STATE: "E_CHANGED_STATE"
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

proc takeString*(h: HSTRING): string =
  ## Convert an `[out] HSTRING` to a Nim string and delete it.
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
    ## be called from any apartment without marshalling, so the runtime invokes
    ## it on whatever thread it is already on instead of trying to reach the
    ## one that handed it over.

# ------------------------------------------------------------------- vtables

include ./abidef

type
  IInspectableVtbl* {.pure.} = object
    ## The six slots every WinRT interface begins with. Every slot carries
    ## `abi`, so Nim knows a call through one neither raises nor touches the
    ## heap — which is what lets `release` be called from a `=destroy` hook.
    ##
    ## Also the head of every vtable this library *implements*: getting the
    ## order or the count of these wrong is the mistake that puts a caller's
    ## `GetAt` through `Release`.
    # --- IUnknown ---
    queryInterface*: proc(self: pointer, riid: ptr GUID,
                          ppv: ptr pointer): HRESULT {.abi.}
    addRef*: proc(self: pointer): uint32 {.abi.}
    release*: proc(self: pointer): uint32 {.abi.}
    # --- IInspectable ---
    getIids*: proc(self: pointer, count: ptr uint32,
                   iids: ptr ptr GUID): HRESULT {.abi.}
    getRuntimeClassName*: proc(self: pointer,
                               name: ptr HSTRING): HRESULT {.abi.}
    getTrustLevel*: proc(self: pointer, level: ptr int32): HRESULT {.abi.}

  IInspectable* {.pure.} = object
    vtbl*: ptr IInspectableVtbl

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
  ##
  ## Doing it marks the runtime as gone, because it is: every object obtained
  ## through it is dead from here, and a `=destroy` running afterwards would
  ## release through a vtable that no longer exists. See `endRuntime`.
  endRuntime()
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
    "timestamp, including the result when no manifest was found, so\n" &
    "adding one\n" &
    "afterwards changes nothing until the executable is rebuilt.\n"

proc activationFactory*(classId: string,
                        iid = IID_IActivationFactory): pointer =
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
                           iid = IID_IActivationFactory):
                             tuple[factory: pointer, hr: HRESULT] =
  ## Non-raising variant, for probing whether a class is reachable at all.
  var id = iid
  withHString(classId, cid):
    result.hr = roGetActivationFactory(cid, id.addr, result.factory.addr)

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
                        value: ptr pointer): HRESULT {.abi.}
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

# ------------------------------------------------------------------ objects

type WinRtObject* {.inheritable, pure.} = object
  ## What every projected runtime class is, underneath: one COM pointer.
  ##
  ## Declared here rather than once per namespace so that the reference
  ## counting below is written once too. `=destroy` and its companions are
  ## inherited, so these four cover all 4,670 classes.
  p*: pointer

proc `=destroy`*(x: var WinRtObject) =
  if x.p != nil: releaseIfLive(x.p)

proc `=copy`*(dst: var WinRtObject, src: WinRtObject) =
  if dst.p == src.p: return
  `=destroy`(dst)
  wasMoved(dst)
  dst.p = src.p
  if dst.p != nil: addRefIfLive(dst.p)

proc `=sink`*(dst: var WinRtObject, src: WinRtObject) =
  # A move transfers the reference, so neither count changes.
  `=destroy`(dst)
  wasMoved(dst)
  dst.p = src.p

func isNil*(x: WinRtObject): bool {.inline.} = x.p.isNil

proc hash*(x: WinRtObject): Hash {.inline.} =
  ## By identity, so an object can key a `Table` — `IMap<Uri, String>` is
  ## one. Two wrappers around one pointer are the same key, which is what the
  ## runtime's own maps mean by equality as well.
  hash(x.p)

proc adopt*[T](p: pointer): T =
  ## Wrap a pointer that is already ours — anything a getter, a factory or a
  ## QueryInterface returned, all of which hand over a reference.
  ##
  ## The counterpart of `borrow`. Between them they cover every way a raw
  ## pointer becomes an object, and saying which one applies is the whole of
  ## the lifetime contract: adopt something you were only lent and the wrapper
  ## releases a reference it never took.
  T(p: p)

proc borrow*[T](p: pointer): T =
  ## Wrap a pointer we were *lent*, such as an event's sender or arguments.
  ##
  ## The wrapper releases on destruction, so adopting a borrowed pointer
  ## without this would over-release it and free an object still in use.
  if not p.isNil: addRef(p)
  T(p: p)

# ------------------------------------------- what the generated API is built on

# An interface is named by its ABI identifier — `IUriRuntimeClass`, not
# `IID_IUriRuntimeClass` — and the templates build the constant and the
# error text from that one name. (`IID iface` inside backticks joins the
# two, and Nim reads `IIDIUriRuntimeClass` and `IID_IUriRuntimeClass` as
# the same identifier.) The generated code reads
#
#     withIface(self.p, IUriRuntimeClass, it):
#       var tmp: HSTRING
#       it.call(IUriRuntimeClass_get_Host, tmp.addr)
#
# which is the whole of a WinRT method call: narrow to the interface that
# declares the method, call its slot, check the HRESULT.

template withIface*(obj: pointer, iface, name, body: untyped) =
  ## Dispatch through the interface that declares the method, not through
  ## whichever one the caller happens to hold. Slots are numbered per
  ## interface, so the difference is a wrong function or a crash, never an
  ## error code.
  let name = queryInterface(obj, `IID iface`)
  if name.isNil:
    raise newException(WinRtError, "winrt: object is not a " & astToStr(iface))
  try:
    body
  finally:
    release(name)

template withStatics*(classId: string, iface, name, body: untyped) =
  ## Dispatch to a class with no instances. Everything it can do lives on an
  ## interface reached through its activation factory, which combase caches,
  ## so this costs a lookup and an AddRef.
  let name = activationFactory(classId, `IID iface`)
  try:
    body
  finally:
    release(name)

macro call*(obj: pointer, tag: untyped, args: varargs[untyped]): untyped =
  ## The method `tag` names — `IUriRuntimeClass_get_Host` — called on `obj`
  ## with `args`, and its HRESULT checked. `Slot_tag` says where it is and
  ## `Fn_tag` what it takes; both are generated from the same metadata row,
  ## so they cannot disagree.
  ##
  ## A macro rather than a template only because a template's `varargs` does
  ## not take zero arguments, and `IClosable_Close` has none.
  let invoke = newCall(newCall(bindSym"vcall", obj, ident("Slot_" & $tag),
                               ident("Fn_" & $tag)), obj)
  for a in args: invoke.add a
  newCall(bindSym"check", invoke, newLit($tag))

type EventHandler*[S, A] = proc(sender: S, args: A) {.closure.}
  ## What an event's `on*` proc takes: the sender and the arguments, each as
  ## the class it is, or `WinRtObject` where the metadata says only `Object`.

# --------------------------------------------------------------- COM heap

# Every COM object this library implements — a delegate, a collection handed
# to the runtime, a boxed value, a completion handler — lives on the COM heap,
# not Nim's. The runtime may release it, iterate it or invoke it on a thread
# Nim never started, and Nim's allocator keeps its state per thread: on a
# thread it has not set up, the first allocation dereferences an uninitialised
# region and the process dies. `CoTaskMemAlloc` has no such state; it is the
# heap COM itself uses, which is also what a receive array comes back on.

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

proc comFree*(p: pointer) {.inline.} =
  ## Give back what `comAlloc` handed out. Safe from any thread, nil included.
  coTaskMemFree(p)

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
                           item: ptr pointer): HRESULT {.abi.}
  FnCollectionGetAtString = proc(self: pointer, index: uint32,
                                 item: ptr HSTRING): HRESULT {.abi.}
  FnCollectionGetAtValue[T] = proc(self: pointer, index: uint32,
                                   item: ptr T): HRESULT {.abi.}
  FnCollectionSize = proc(self: pointer,
                          size: ptr uint32): HRESULT {.abi.}

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

proc toTable*[K, V](map: pointer, iterableIid, pairIid: GUID,
                    innerIid = GUID()): Table[K, V]

proc readTableAs[K, V](_: typedesc[Table[K, V]], map: pointer,
                       iterableIid, pairIid: GUID): Table[K, V] =
  ## `toTable` with K and V taken apart from the Table type, which is the one
  ## way a generic can name the halves of a `Table[K, V]` it was handed whole.
  toTable[K, V](map, iterableIid, pairIid)

proc toSeq*[T](collection: pointer, iid: GUID, innerIid = GUID(),
               innerPairIid = GUID()): seq[T] =
  ## Every element of a WinRT collection, as a `seq`.
  ##
  ## An element is a string, an object, a value read by width, or a
  ## collection or map in turn, and which is decided from `T` rather than by
  ## having a reader per shape. Each `GetAt` hands over what it returns, so
  ## strings are taken, objects adopted rather than retained again, and a
  ## nested collection read and released here. The outer collection itself
  ## stays the caller's to release.
  ##
  ## `innerIid` is the instantiation a nested collection is read through —
  ## for a `seq[seq[Point]]` — or the iterable-of-pairs of a nested map, whose
  ## pair instantiation is then `innerPairIid`. Both are unused otherwise.
  eachItem(collection, iid):
    when T is string:
      var item: HSTRING
      vcall(view, SlotCollectionGetAt, FnCollectionGetAtString)(view, i, item.addr)
        .check("collection.GetAt")
      result.add takeString(item)
    elif T is WinRtObject:
      var item: pointer
      vcall(view, SlotCollectionGetAt, FnCollectionGetAt)(view, i, item.addr)
        .check("collection.GetAt")
      result.add adopt[T](item)
    elif T is seq:
      var item: pointer
      vcall(view, SlotCollectionGetAt, FnCollectionGetAt)(view, i, item.addr)
        .check("collection.GetAt")
      result.add toSeq[typeof(result[0][0])](item, innerIid)
      release(item)
    elif T is Table:
      var item: pointer
      vcall(view, SlotCollectionGetAt, FnCollectionGetAt)(view, i, item.addr)
        .check("collection.GetAt")
      result.add readTableAs(T, item, innerIid, innerPairIid)
      release(item)
    else:
      var item: T
      vcall(view, SlotCollectionGetAt, FnCollectionGetAtValue[T])(view, i, item.addr)
        .check("collection.GetAt")
      result.add item

# ---------------------------------------------------------------------- maps

# A WinRT map is read by iterating it: `IMapView<K, V>` is an
# `IIterable<IKeyValuePair<K, V>>`, and each pair answers `get_Key` at slot 6
# and `get_Value` at slot 7. `Lookup` exists too, but only iteration gives you
# everything without knowing the keys first.
const
  SlotIterableFirst = 6
  SlotPairKey = 6
  SlotPairValue = 7
  SlotIteratorCurrent = 6
  SlotIteratorHasCurrent = 7
  SlotIteratorMoveNext = 8

type
  FnFirst = proc(self: pointer, it: ptr pointer): HRESULT {.abi.}
  FnCurrent = proc(self: pointer, item: ptr pointer): HRESULT {.abi.}
  FnHasCurrent = proc(self: pointer, has: ptr bool): HRESULT {.abi.}
  FnPairString = proc(self: pointer, v: ptr HSTRING): HRESULT {.abi.}
  FnPairValue[T] = proc(self: pointer, value: ptr T): HRESULT {.abi.}
  FnPairPtr = proc(self: pointer, v: ptr pointer): HRESULT {.abi.}

template eachPair(map: pointer, iterableIid, pairIid: GUID, body: untyped) =
  ## Walk a map, with `pair` bound inside `body`.
  let iterable = queryInterface(map, iterableIid)
  if not iterable.isNil:
    try:
      var cursor: pointer
      vcall(iterable, SlotIterableFirst, FnFirst)(iterable, cursor.addr)
        .check("map.First")
      if not cursor.isNil:
        try:
          while true:
            var more: bool
            vcall(cursor, SlotIteratorHasCurrent, FnHasCurrent)(cursor, more.addr)
              .check("map.get_HasCurrent")
            if not more: break
            var raw: pointer
            vcall(cursor, SlotIteratorCurrent, FnCurrent)(cursor, raw.addr)
              .check("map.get_Current")
            let pair {.inject.} = queryInterface(raw, pairIid)
            release(raw)
            if not pair.isNil:
              try:
                body
              finally:
                release(pair)
            vcall(cursor, SlotIteratorMoveNext, FnHasCurrent)(cursor, more.addr)
              .check("map.MoveNext")
        finally:
          release(cursor)
    finally:
      release(iterable)

proc toTable*[K, V](map: pointer, iterableIid, pairIid: GUID,
                    innerIid = GUID()): Table[K, V] =
  ## Every entry of a WinRT map, as a Nim `Table`.
  ##
  ## Key and value are each a string, an object, or a value read by width —
  ## and a value may also be a collection, read through `innerIid` — and
  ## which is decided from the Nim type rather than by having a reader per
  ## combination. An object is *adopted*: `get_Value` hands over a reference
  ## that is ours.
  eachPair(map, iterableIid, pairIid):
    var k: K
    when K is string:
      var kh: HSTRING
      vcall(pair, SlotPairKey, FnPairString)(pair, kh.addr).check("pair.get_Key")
      k = takeString(kh)
    elif K is WinRtObject:
      var kp: pointer
      vcall(pair, SlotPairKey, FnPairPtr)(pair, kp.addr).check("pair.get_Key")
      k = adopt[K](kp)
    else:
      vcall(pair, SlotPairKey, FnPairValue[K])(pair, k.addr).check("pair.get_Key")
    var v: V
    when V is string:
      var vh: HSTRING
      vcall(pair, SlotPairValue, FnPairString)(pair, vh.addr)
        .check("pair.get_Value")
      v = takeString(vh)
    elif V is WinRtObject:
      var vp: pointer
      vcall(pair, SlotPairValue, FnPairPtr)(pair, vp.addr).check("pair.get_Value")
      v = adopt[V](vp)
    elif V is seq:
      var vp: pointer
      vcall(pair, SlotPairValue, FnPairPtr)(pair, vp.addr).check("pair.get_Value")
      v = toSeq[typeof(v[0])](vp, innerIid)
      release(vp)
    else:
      vcall(pair, SlotPairValue, FnPairValue[V])(pair, v.addr)
        .check("pair.get_Value")
    result[k] = v

# ---------------------------------------------------------------- references

# `IReference<T>` is how WinRT says "a T, or nothing". It is an interface, so
# the absence is a null pointer rather than a sentinel value, and the value
# itself is read through `get_Value` — slot 6, the first method after
# IInspectable's six, on every instantiation.
#
# Nim already has a word for that shape, so this is where the projection stops
# looking like COM and starts looking like Nim.
const SlotReferenceValue = 6

type FnReferenceValue[T] =
  proc(self: pointer, value: ptr T): HRESULT {.abi.}

proc readReference*[T](box: pointer, iid: GUID, what: string): Option[T] =
  ## The value inside an `IReference<T>`, or `none` if there was not one.
  ##
  ## The box itself stays the caller's to release; only the narrowed interface
  ## is released here.
  if box.isNil: return none(T)
  let typed = queryInterface(box, iid)
  if typed.isNil:
    raise newException(WinRtError, "winrt: " & what &
      " is not the reference type its signature declares")
  try:
    var v: T
    vcall(typed, SlotReferenceValue, FnReferenceValue[T])(typed, v.addr)
      .check(what & ".get_Value")
    result = some(v)
  finally:
    release(typed)

# ------------------------------------------------------------------- boxing

# The other half of `IReference<T>`: handing a value *in* means wrapping it in
# an object, and `Windows.Foundation.PropertyValue` is the runtime's own
# factory for that. Each `CreateX` returns an `IInspectable` that answers
# `QueryInterface` for `IReference<X>`, which is what the callee narrows to.
#
# Only the types PropertyValue has a `CreateX` for can be boxed this way.
# There is no `CreateEnum` and no way to box an arbitrary struct, so those go
# through `reference.nim`, which implements `IReference<T>` itself.
const
  PropertyValueClass = "Windows.Foundation.PropertyValue"
  IID_IPropertyValueStatics = guid"629BDBC8-D932-4FF4-96B9-8D96C5C1E858"
  SlotBoxString = 18
  SlotBoxNone* = -1        ## no `CreateX` exists for this type

type FnBox[T] = proc(self: pointer, value: T,
                     boxed: ptr pointer): HRESULT {.abi.}

proc box*[T](value: T, slot: int): pointer =
  ## `value` as an `IReference<T>`, or nil if `slot` says it cannot be boxed.
  ##
  ## Returned with a reference count of 1: pass it to the method and release
  ## it. Boxing goes through the activation factory, which combase caches.
  if slot == SlotBoxNone: return nil
  let factory = activationFactory(PropertyValueClass, IID_IPropertyValueStatics)
  try:
    vcall(factory, slot, FnBox[T])(factory, value, result.addr)
      .check(PropertyValueClass & ".Create")
  finally:
    release(factory)

proc boxString*(value: string): pointer =
  ## The same for a string, whose HSTRING is the factory's to copy.
  let factory = activationFactory(PropertyValueClass, IID_IPropertyValueStatics)
  try:
    withHString(value, h):
      vcall(factory, SlotBoxString, FnBox[HSTRING])(factory, h, result.addr)
        .check(PropertyValueClass & ".CreateString")
  finally:
    release(factory)

proc boxAs*[T](value: T, slot: int, iid: GUID): pointer =
  ## `value` as the `IReference<T>` a signature asks for.
  ##
  ## `CreateX` hands back an `IInspectable`, and a method declaring
  ## `IReference<T>` wants that interface, not this one. Passing the
  ## `IInspectable` is not a type error anywhere — both are bare pointers at
  ## the ABI — and the callee reads a different vtable, which is how it comes
  ## back as zero rather than as a failure.
  let inspectable = box(value, slot)
  if inspectable.isNil: return nil
  result = queryInterface(inspectable, iid)
  release(inspectable)

proc boxStringAs*(value: string, iid: GUID): pointer =
  ## The same for a string.
  let inspectable = boxString(value)
  if inspectable.isNil: return nil
  result = queryInterface(inspectable, iid)
  release(inspectable)

# ----------------------------------------------------------------- arrays

# WinRT passes an array as two arguments — a count and a pointer — and who
# frees it depends on the direction. An argument we pass is ours throughout.
# A *returned* array was allocated by the callee with `CoTaskMemAlloc` and is
# ours to free, and if its elements are strings or objects then each of those
# is ours as well.

proc takeArray*[T](size: uint32, data: ptr T): seq[T] =
  ## A returned array of values, copied out and the buffer released.
  if data.isNil: return
  let items = cast[ptr UncheckedArray[T]](data)
  result = newSeq[T](int(size))
  for i in 0 ..< int(size): result[i] = items[i]
  coTaskMemFree(data)

proc takeArrayString*(size: uint32, data: ptr HSTRING): seq[string] =
  ## The same for strings: each HSTRING is ours to delete, and so is the
  ## buffer holding them.
  if data.isNil: return
  let items = cast[ptr UncheckedArray[HSTRING]](data)
  result = newSeq[string](int(size))
  for i in 0 ..< int(size):
    result[i] = takeString(items[i])
  coTaskMemFree(data)

proc takeArrayObject*[T](size: uint32, data: ptr pointer): seq[T] =
  ## The same for objects. Each element arrives with a reference that is the
  ## caller's, so each is adopted rather than retained again.
  if data.isNil: return
  let items = cast[ptr UncheckedArray[pointer]](data)
  result = newSeq[T](int(size))
  for i in 0 ..< int(size): result[i] = adopt[T](items[i])
  coTaskMemFree(data)

template withStringArray*(values: openArray[string], n, d, body: untyped) =
  ## `values` as an array of HSTRINGs for the length of `body`.
  ##
  ## A Nim `seq[string]` is not an array of HSTRINGs, so unlike an array of
  ## numbers this one cannot be pointed at where it lies — it is converted
  ## into a buffer of its own, and every string in it deleted afterwards.
  var strs = newSeq[HSTRING](values.len)
  let n {.inject.} = uint32(values.len)
  let d {.inject.} = if strs.len > 0: strs[0].addr else: nil
  try:
    for i in 0 ..< values.len: strs[i] = toHString(values[i])
    body
  finally:
    for h in strs: discard windowsDeleteString(h)

template withObjectArray*[T](values: openArray[T], iid: GUID,
                             n, d, body: untyped) =
  ## `values` as an array of interface pointers for the length of `body`.
  ##
  ## Each element is narrowed to the interface the signature asks for, which
  ## is a reference this holds and drops again — the callee retains anything
  ## it keeps.
  var ptrs = newSeq[pointer](values.len)
  let n {.inject.} = uint32(values.len)
  let d {.inject.} = if ptrs.len > 0: ptrs[0].addr else: nil
  try:
    for i in 0 ..< values.len: ptrs[i] = queryInterface(values[i].p, iid)
    body
  finally:
    for p in ptrs: release(p)
