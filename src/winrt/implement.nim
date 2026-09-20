## Implementing WinRT interfaces from Nim.
##
## Everything else in this library calls objects Windows made. This is for the
## other case: an object *you* make that Windows calls back — an
## `INotifyPropertyChanged` for data binding, an `ICommand`, a background
## task, an `IBuffer` over your own bytes. `implement` takes each interface's
## vtable type, from the ABI module, with your methods filled in and hands
## back a COM object that Windows can hold, query and call:
##
## ```nim
## var answer = 42'i32
## let box = implement(IReferenceVtbl[int32](
##   get_Value: proc(self: pointer, value: ptr int32): HRESULT {.stdcall.} =
##     value[] = cast[ptr int32](stateOf(self))[]
##     S_OK),
##   state = answer.addr)
## ```
##
## An object may implement several interfaces — two or three as arguments,
## any number as one tuple — and `QueryInterface` answers for each of them,
## for `IUnknown`, `IInspectable` and `IAgileObject`. The methods are written
## at the ABI: `{.stdcall.}` procs that receive `self` and the raw arguments
## the vtable declares and return an HRESULT. `stateOf(self)` gives back
## whatever pointer you attached, from a method of any of the interfaces;
## `takeString`, `toHString`, `adopt` and `borrow` convert what crosses. The
## three methods every interface begins with, and the three more of
## `IInspectable`, are filled in here, and each interface's IID comes from its
## vtable type — `iid(V)`, which the ABI declares for everything in the
## metadata and which you declare for an interface of your own.
##
## Windows may hold the object past the call that received it and release it
## from any thread, so it lives on the COM heap and its count is atomic. The
## `dispose` proc, if you give one, runs once Windows has let go — on the
## dispatcher thread, whichever thread released last — so it may free GC
## memory: `GC_unref` the object you `GC_ref`ed when you attached it.
##
## Your methods may be called on any thread too, and there is no dispatcher
## in between as there is for a delegate, because a method has to answer
## before it returns: a method that touches GC memory must know which thread
## it is on, and `runOnDispatcher` is how it hands work to the right one.

import std/[atomics, typetraits]
import ./[com, delegate]
include ./abidef

type
  Dispose* = proc(state: pointer) {.nimcall, raises: [].}
    ## What to do with `state` once Windows has let go of the object.

  Slot {.pure.} = object
    ## What an interface pointer points at: the vtable, which is what COM
    ## reads, and the way back to the object, which is what this module reads.
    vtbl: pointer            ## must stay first
    owner: ptr Header
    iid: GUID
    inspectable: bool        ## derives from IInspectable, not just IUnknown

  Header {.pure.} = object
    ## The part every implementation shares, whatever its interfaces.
    refs: Atomic[int32]
    count: int32
    slots: ptr UncheckedArray[Slot]
    state: pointer
    dispose: Dispose

  Impl[T: tuple] {.pure.} = object
    ## `T` is the tuple of vtables `implement` was given: one slot per
    ## interface, and this object's own copy of every table, because two
    ## objects of one interface may carry different methods.
    header: Header
    slots: array[tupleLen(T), Slot]
    tables: T

proc owner(self: pointer): ptr Header {.inline.} =
  cast[ptr Slot](self).owner

proc implAddRef(self: pointer): uint32 {.abi.} =
  uint32(owner(self).refs.fetchAdd(1) + 1)

proc implRelease(self: pointer): uint32 {.abi.} =
  let h = owner(self)
  let left = h.refs.fetchSub(1) - 1
  if left <= 0:
    # Whichever thread this is, the memory is COM's to free. The state is
    # Nim's, and is let go of on the dispatcher thread.
    let dispose = h.dispose
    let state = h.state
    comFree(h)
    if not dispose.isNil:
      runOnDispatcher(dispose, state)
    return 0
  uint32(left)

proc answer(h: ptr Header, i: int, ppv: ptr pointer): HRESULT =
  ppv[] = h.slots[i].addr
  discard implAddRef(ppv[])
  S_OK

proc implQuery(self: pointer, riid: ptr GUID, ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let h = owner(self)
  if riid[] == IID_IUnknown or riid[] == IID_IAgileObject:
    return answer(h, 0, ppv)
  for i in 0 ..< h.count:
    if riid[] == h.slots[i].iid or
       (riid[] == IID_IInspectable and h.slots[i].inspectable):
      return answer(h, i, ppv)
  ppv[] = nil
  E_NOINTERFACE

proc implIids(self: pointer, count: ptr uint32,
              iids: ptr ptr GUID): HRESULT {.abi.} =
  ## The WinRT interfaces — those deriving from IInspectable — in an array the
  ## caller frees with `CoTaskMemFree`.
  let h = owner(self)
  var n = 0
  for i in 0 ..< h.count:
    if h.slots[i].inspectable: n.inc
  let found = cast[ptr UncheckedArray[GUID]](comAlloc(max(n, 1) * sizeof(GUID)))
  var k = 0
  for i in 0 ..< h.count:
    if h.slots[i].inspectable:
      found[k] = h.slots[i].iid
      k.inc
  count[] = uint32(n)
  iids[] = cast[ptr GUID](found)
  S_OK

proc implClassName(self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  name[] = HSTRING(nil)     # no runtime class behind this; the empty string
  S_OK

proc implTrust(self: pointer, level: ptr int32): HRESULT {.abi.} =
  level[] = 0               # BaseTrust
  S_OK

proc implement*[T: tuple](vtables: T, state: pointer = nil,
                          dispose: Dispose = nil): pointer =
  ## A COM object implementing every interface in `vtables`, a tuple of
  ## vtable objects each carrying your methods. Returned with a reference
  ## count of 1, as a pointer to the first interface; hand it to Windows,
  ## which takes its own, and release yours. `state` is what `stateOf(self)`
  ## returns inside your methods, and `dispose` is called with it once the
  ## last reference is gone.
  ensureDispatcher()
  let obj = cast[ptr Impl[T]](comAlloc(sizeof(Impl[T])))
  obj.header.refs.store(1)
  obj.header.count = int32(tupleLen(T))
  obj.header.slots = cast[ptr UncheckedArray[Slot]](obj.slots[0].addr)
  obj.header.state = state
  obj.header.dispose = dispose
  obj.tables = vtables
  var i = 0
  for table in fields(obj.tables):
    table.queryInterface = implQuery
    table.addRef = implAddRef
    table.release = implRelease
    when table is IInspectableVtbl:
      table.getIids = implIids
      table.getRuntimeClassName = implClassName
      table.getTrustLevel = implTrust
    obj.slots[i] = Slot(vtbl: table.addr, owner: obj.header.addr,
                        iid: iid(typeof(table)),
                        inspectable: table is IInspectableVtbl)
    inc i
  obj.slots[0].addr

proc implement*[V](vtable: V, state: pointer = nil,
                   dispose: Dispose = nil): pointer =
  ## One interface.
  implement((vtable,), state, dispose)

proc implement*[A, B](a: A, b: B, state: pointer = nil,
                      dispose: Dispose = nil): pointer =
  ## Two interfaces on one object.
  implement((a, b), state, dispose)

proc implement*[A, B, C](a: A, b: B, c: C, state: pointer = nil,
                         dispose: Dispose = nil): pointer =
  ## Three interfaces on one object; for more, pass them as one tuple.
  implement((a, b, c), state, dispose)

proc stateOf*(self: pointer): pointer {.inline.} =
  ## The pointer `implement` was given, from inside a method of any of the
  ## object's interfaces.
  owner(self).state
