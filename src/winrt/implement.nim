## Implementing a WinRT interface from Nim.
##
## Everything else in this library calls objects Windows made. This is for the
## other case: an object *you* make that Windows calls back — an
## `INotifyPropertyChanged` for data binding, an `ICommand`, a background
## task, an `IReference<T>` of your own. `implement` takes an interface's
## vtable type with your methods filled in and hands back a COM object that
## Windows can hold, query and call:
##
## ```nim
## include winrt/abidef            # the `abi` calling convention
##
## var answer = 42'i32
## let box = implement(IID_IReference_1_Int32, IReferenceInt32Vtbl(
##   get_Value: proc(self: pointer, value: ptr int32): HRESULT {.abi.} =
##     value[] = cast[ptr int32](stateOf(self))[]
##     S_OK),
##   state = answer.addr)
## ```
##
## The methods are written at the ABI: they receive `self` and the raw
## arguments the vtable declares, and return an HRESULT. `stateOf(self)` gives
## back whatever pointer you attached; `takeString`, `toHString`, `adopt` and
## `borrow` convert what crosses. The six methods every interface begins with
## are filled in here — `QueryInterface` answers for `IUnknown`,
## `IInspectable`, `IAgileObject` and the interface itself.
##
## One interface per object. An object answering for two unrelated interfaces
## needs a vtable pointer per interface and a recovery offset in every method,
## which is what `seqview` and `mapview` do by hand for the collections.
##
## Windows may hold the object past the call that received it and release it
## from any thread, so it lives on the COM heap and its count is atomic. Your
## methods may be called on any thread too, and there is no dispatcher in
## between as there is for a delegate: a method that touches GC memory must
## know which thread it is on.

import std/atomics
import ./core
include ./abidef

type
  ImplHeader {.pure.} = object
    ## The part every implementation shares, at a fixed offset so `stateOf`
    ## needs no type.
    vtbl: pointer            ## must stay first
    refs: Atomic[int32]
    iid: GUID
    state: pointer

  Impl[V] {.pure.} = object
    header: ImplHeader
    table: V                 ## this object's own copy: two objects of one
                             ## type may carry different methods

proc implAddRef(self: pointer): uint32 {.abi.} =
  uint32(cast[ptr ImplHeader](self).refs.fetchAdd(1) + 1)

proc implRelease(self: pointer): uint32 {.abi.} =
  let left = cast[ptr ImplHeader](self).refs.fetchSub(1) - 1
  if left <= 0:
    comFree(self)
    return 0
  uint32(left)

proc implQuery(self: pointer, riid: ptr GUID, ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let h = cast[ptr ImplHeader](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == h.iid:
    ppv[] = self
    discard implAddRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc implIids(self: pointer, count: ptr uint32,
              iids: ptr ptr GUID): HRESULT {.abi.} =
  ## The one interface, in an array the caller frees with `CoTaskMemFree`.
  let one = cast[ptr GUID](comAlloc(sizeof(GUID)))
  one[] = cast[ptr ImplHeader](self).iid
  count[] = 1
  iids[] = one
  S_OK

proc implClassName(self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  name[] = HSTRING(nil)     # no runtime class behind this; the empty string
  S_OK

proc implTrust(self: pointer, level: ptr int32): HRESULT {.abi.} =
  level[] = 0               # BaseTrust
  S_OK

proc implement*[V](iid: GUID, methods: V, state: pointer = nil): pointer =
  ## A COM object implementing the interface whose IID is `iid` and whose
  ## vtable type is `V`, with the methods `methods` carries. Returned with a
  ## reference count of 1; hand it to Windows, which takes its own, and
  ## release yours.
  let obj = cast[ptr Impl[V]](comAlloc(sizeof(Impl[V])))
  obj.table = methods
  obj.table.queryInterface = implQuery
  obj.table.addRef = implAddRef
  obj.table.release = implRelease
  obj.table.getIids = implIids
  obj.table.getRuntimeClassName = implClassName
  obj.table.getTrustLevel = implTrust
  obj.header.vtbl = obj.table.addr
  obj.header.refs.store(1)
  obj.header.iid = iid
  obj.header.state = state
  cast[pointer](obj)

proc stateOf*(self: pointer): pointer {.inline.} =
  ## The pointer `implement` was given, from inside one of the methods.
  cast[ptr ImplHeader](self).state
