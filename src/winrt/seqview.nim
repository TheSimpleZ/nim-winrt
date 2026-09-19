## Handing a Nim `seq` to WinRT.
##
## `core` walks a collection the runtime gave us. This is the other direction:
## a method that takes an `IIterable<T>` or an `IVectorView<T>` wants an object
## implementing those interfaces, so one is built around the seq.
##
## ## Two interfaces, two vtables
##
## A COM object that implements two interfaces cannot have one vtable, because
## `IIterable<T>` and `IVectorView<T>` both put their own first method at slot
## 6 — `First` for one, `GetAt` for the other. So the object begins with two
## vtable pointers, and `QueryInterface` hands out the address of whichever
## field matches. Each method then recovers the object by subtracting that
## field's offset, which is the standard COM arrangement for this.
##
## `IIterable<T>::First` has to return a separate object again, because an
## iterator has its own position.
##
## ## What crosses
##
## Elements are objects or strings — the two shapes a generated wrapper can
## produce. Both are *owned* by the view: an object is retained on the way in
## and released when the view dies, and a string is copied. `GetAt` follows
## WinRT's rule that the caller owns what it receives, so it retains again for
## an object and duplicates again for a string.
##
## The IIDs are the caller's business. Every instantiation of a parameterised
## interface has a different one, computed by hashing a signature string, so
## the generated code works them out and passes all three in.

import ./core
include ./abidef

type
  ElementKind* = enum
    ekObject   ## an interface pointer, retained
    ekString   ## an HSTRING, copied
    ekValue    ## a number, enum or struct, copied by size

  IterableVtbl {.pure.} = object
    base: InspectableVtbl
    first: proc(self: pointer, it: ptr pointer): HRESULT {.abi.}

  ViewVtbl {.pure.} = object
    base: InspectableVtbl
    getAt: proc(self: pointer, index: uint32,
                item: ptr pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    indexOf: proc(self: pointer, item: pointer, index: ptr uint32,
                  found: ptr bool): HRESULT {.abi.}

  IteratorVtbl {.pure.} = object
    base: InspectableVtbl
    getCurrent: proc(self: pointer, item: ptr pointer): HRESULT {.abi.}
    getHasCurrent: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    moveNext: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    getMany: proc(self: pointer, capacity: uint32, items: ptr pointer,
                  actual: ptr uint32): HRESULT {.abi.}

  SeqView {.pure.} = object
    ## Shared-allocated: WinRT may hold it past the call, and its lifetime is
    ## COM's rather than Nim's.
    iterableVtbl: ptr IterableVtbl    ## must stay first
    viewVtbl: ptr ViewVtbl
    refs: int32
    iterableIid, viewIid, iteratorIid: GUID
    kind: ElementKind
    count: int32
    items: ptr UncheckedArray[pointer]
    # For `ekValue` the elements are not pointers at all: `items` is a flat
    # buffer of `count * stride` bytes and `GetAt` copies `stride` of them into
    # whatever the caller pointed at. That keeps one implementation for every
    # value type instead of a generic one per instantiation — the ABI shape is
    # the same either way, since the vtable slot only ever sees a `pointer`.
    stride: int32

  SeqIterator {.pure.} = object
    vtbl: ptr IteratorVtbl
    refs: int32
    iid: GUID
    owner: ptr SeqView
    pos: int32

const IidAgile = GUID(
  data1: 0x94EA2B94'u32, data2: 0xE9CC'u16, data3: 0x49E0'u16,
  data4: [0xC0'u8, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90])

# `QueryInterface` hands out the address of a vtable field, so a method arrives
# holding that field rather than the object. These put it back.
proc fromIterable(self: pointer): ptr SeqView {.inline.} =
  cast[ptr SeqView](self)

proc fromView(self: pointer): ptr SeqView {.inline.} =
  cast[ptr SeqView](cast[uint](self) - uint(offsetOf(SeqView, viewVtbl)))

proc valueAt(v: ptr SeqView, slot: int32): pointer {.inline.} =
  cast[pointer](cast[uint](v.items) + uint(slot * v.stride))

proc retain(v: ptr SeqView, slot: int32, item: ptr pointer): HRESULT =
  ## One element, owned by whoever receives it.
  if v.kind == ekValue:
    copyMem(item, valueAt(v, slot), v.stride)
    return S_OK
  let raw = v.items[slot]
  case v.kind
  of ekObject:
    if not raw.isNil: discard addRef(raw)
    item[] = raw
    result = S_OK
  of ekString:
    var dup: HSTRING
    result = windowsDuplicateString(cast[HSTRING](raw), dup.addr)
    item[] = cast[pointer](dup)
  of ekValue: discard   # handled above

proc destroy(v: ptr SeqView) =
  if v.kind != ekValue:                 # values own nothing
    for i in 0 ..< v.count:
      let raw = v.items[i]
      if raw.isNil: continue
      case v.kind
      of ekObject: discard release(raw)
      of ekString: discard windowsDeleteString(cast[HSTRING](raw))
      of ekValue: discard
  if v.count > 0: deallocShared(v.items)
  deallocShared(v)

# --------------------------------------------------------------- IInspectable

proc viewAddRef(self: pointer): uint32 {.abi.} =
  let v = fromIterable(self)
  v.refs.inc
  uint32(v.refs)

proc viewAddRefV(self: pointer): uint32 {.abi.} =
  let v = fromView(self)
  v.refs.inc
  uint32(v.refs)

proc viewRelease(self: pointer): uint32 {.abi.} =
  let v = fromIterable(self)
  v.refs.dec
  if v.refs <= 0:
    destroy(v)
    return 0
  uint32(v.refs)

proc viewReleaseV(self: pointer): uint32 {.abi.} =
  let v = fromView(self)
  v.refs.dec
  if v.refs <= 0:
    destroy(v)
    return 0
  uint32(v.refs)

proc answer(v: ptr SeqView, riid: ptr GUID, ppv: ptr pointer): HRESULT =
  ## Whichever vtable the caller asked for.
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IidAgile or riid[] == v.iterableIid:
    ppv[] = cast[pointer](v)
    v.refs.inc
    return S_OK
  if riid[] == v.viewIid:
    ppv[] = cast[pointer](v.viewVtbl.addr)
    v.refs.inc
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc viewQuery(self: pointer, riid: ptr GUID,
               ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  answer(fromIterable(self), riid, ppv)

proc viewQueryV(self: pointer, riid: ptr GUID,
                ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  answer(fromView(self), riid, ppv)

proc noIids(self: pointer, count: ptr uint32,
            iids: ptr ptr GUID): HRESULT {.abi.} =
  count[] = 0
  iids[] = nil
  S_OK

proc noName(self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  name[] = HSTRING(nil)
  S_OK

proc baseTrust(self: pointer, level: ptr int32): HRESULT {.abi.} =
  level[] = 0          # BaseTrust
  S_OK

# ------------------------------------------------------------- IVectorView<T>

proc viewGetAt(self: pointer, index: uint32,
               item: ptr pointer): HRESULT {.abi.} =
  let v = fromView(self)
  if index >= uint32(v.count): return E_BOUNDS
  retain(v, int32(index), item)

proc viewGetSize(self: pointer, size: ptr uint32): HRESULT {.abi.} =
  size[] = uint32(fromView(self).count)
  S_OK

proc viewIndexOf(self: pointer, item: pointer, index: ptr uint32,
                 found: ptr bool): HRESULT {.abi.} =
  ## Identity only. WinRT wants `IUnknown` identity for objects and value
  ## equality for strings; a view built to be read once is not worth the second
  ## of those, and saying "not found" is allowed.
  let v = fromView(self)
  index[] = 0
  found[] = false
  if v.kind == ekObject:
    for i in 0 ..< v.count:
      if v.items[i] == item:
        index[] = uint32(i)
        found[] = true
        break
  elif v.kind == ekValue and not item.isNil:
    # A value compares by its bytes, which is what equality means for the
    # numbers, enums and layout-only structs this carries.
    for i in 0 ..< v.count:
      if equalMem(valueAt(v, i), item, v.stride):
        index[] = uint32(i)
        found[] = true
        break
  S_OK

# -------------------------------------------------------------- IIterator<T>

proc iterAddRef(self: pointer): uint32 {.abi.} =
  let it = cast[ptr SeqIterator](self)
  it.refs.inc
  uint32(it.refs)

proc iterRelease(self: pointer): uint32 {.abi.} =
  let it = cast[ptr SeqIterator](self)
  it.refs.dec
  if it.refs <= 0:
    discard viewRelease(cast[pointer](it.owner))
    deallocShared(it)
    return 0
  uint32(it.refs)

proc iterQuery(self: pointer, riid: ptr GUID,
               ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let it = cast[ptr SeqIterator](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IidAgile or riid[] == it.iid:
    ppv[] = self
    discard iterAddRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc iterCurrent(self: pointer, item: ptr pointer): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  if it.pos >= it.owner.count: return E_BOUNDS
  retain(it.owner, it.pos, item)

proc iterHasCurrent(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  has[] = it.pos < it.owner.count
  S_OK

proc iterMoveNext(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  if it.pos < it.owner.count: it.pos.inc
  has[] = it.pos < it.owner.count
  S_OK

proc iterGetMany(self: pointer, capacity: uint32, items: ptr pointer,
                 actual: ptr uint32): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  let step = if it.owner.kind == ekValue: it.owner.stride else: int32(sizeof(pointer))
  var n = 0'u32
  while n < capacity and it.pos < it.owner.count:
    let slot = cast[ptr pointer](cast[uint](items) + uint(int32(n) * step))
    let hr = retain(it.owner, it.pos, slot)
    if failed(hr):
      actual[] = n
      return hr
    it.pos.inc
    n.inc
  actual[] = n
  S_OK

var iteratorVtbl = IteratorVtbl(
  base: InspectableVtbl(queryInterface: iterQuery, addRef: iterAddRef, release: iterRelease,
         getIids: noIids, getRuntimeClassName: noName, getTrustLevel: baseTrust),
  getCurrent: iterCurrent, getHasCurrent: iterHasCurrent,
  moveNext: iterMoveNext, getMany: iterGetMany)

proc viewFirst(self: pointer, outIt: ptr pointer): HRESULT {.abi.} =
  let v = fromIterable(self)
  let it = cast[ptr SeqIterator](allocShared0(sizeof(SeqIterator)))
  it.vtbl = iteratorVtbl.addr
  it.refs = 1
  it.iid = v.iteratorIid
  it.owner = v
  it.pos = 0
  discard viewAddRef(cast[pointer](v))    # the iterator keeps the view alive
  outIt[] = cast[pointer](it)
  S_OK

var iterableVtbl = IterableVtbl(
  base: InspectableVtbl(queryInterface: viewQuery, addRef: viewAddRef, release: viewRelease,
         getIids: noIids, getRuntimeClassName: noName, getTrustLevel: baseTrust),
  first: viewFirst)

var viewVtbl = ViewVtbl(
  base: InspectableVtbl(queryInterface: viewQueryV, addRef: viewAddRefV,
         release: viewReleaseV, getIids: noIids, getRuntimeClassName: noName,
         getTrustLevel: baseTrust),
  getAt: viewGetAt, getSize: viewGetSize, indexOf: viewIndexOf)

proc newSeqView(kind: ElementKind, n: int,
                iterableIid, viewIid, iteratorIid: GUID,
                stride = sizeof(pointer)): ptr SeqView =
  result = cast[ptr SeqView](allocShared0(sizeof(SeqView)))
  result.iterableVtbl = iterableVtbl.addr
  result.viewVtbl = viewVtbl.addr
  result.refs = 1
  result.iterableIid = iterableIid
  result.viewIid = viewIid
  result.iteratorIid = iteratorIid
  result.kind = kind
  result.count = int32(n)
  result.stride = int32(stride)
  if n > 0:
    result.items = cast[ptr UncheckedArray[pointer]](allocShared0(n * stride))

proc asIterable*[T](items: seq[T],
                    iterableIid, viewIid, iteratorIid: GUID): pointer =
  ## A seq of objects, as something WinRT can iterate.
  ##
  ## Returned with a reference count of 1. Pass it to the method and release
  ## it; the object frees itself once the callee lets go, which may be after
  ## the call returns.
  let v = newSeqView(ekObject, items.len, iterableIid, viewIid, iteratorIid)
  for i, x in items:
    let p = x.p
    if not p.isNil: discard addRef(p)
    v.items[i] = p
  cast[pointer](v)

proc asIterableValue*[T](items: seq[T],
                         iterableIid, viewIid, iteratorIid: GUID): pointer =
  ## The same for a seq of values — numbers, enums, structs — copied into a
  ## flat buffer the view owns. `T` has to be a plain type with no destructor;
  ## every WinRT value type is.
  let v = newSeqView(ekValue, items.len, iterableIid, viewIid, iteratorIid,
                     sizeof(T))
  for i, x in items:
    cast[ptr T](valueAt(v, int32(i)))[] = x
  cast[pointer](v)

proc asIterableString*(items: seq[string],
                       iterableIid, viewIid, iteratorIid: GUID): pointer =
  ## The same for a seq of strings, each copied into an HSTRING the view owns.
  let v = newSeqView(ekString, items.len, iterableIid, viewIid, iteratorIid)
  for i, s in items:
    v.items[i] = cast[pointer](s.toHString)
  cast[pointer](v)
