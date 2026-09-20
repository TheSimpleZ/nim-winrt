## Handing a Nim `seq` to WinRT.
##
## `core` walks a collection the runtime gave us. This is the other direction:
## a method that takes an `IIterable<T>` or an `IVectorView<T>` wants an object
## implementing those interfaces, so one is built around the seq.
##
## ## Three interfaces, three vtables
##
## A COM object that implements several interfaces cannot have one vtable,
## because `IIterable<T>`, `IVectorView<T>` and `IVector<T>` all put their own
## first method at slot 6 — `First` for one, `GetAt` for the others. So the
## object begins with three vtable pointers, and `QueryInterface` hands out the
## address of whichever field matches. Each method then recovers the object by
## subtracting that field's offset, which is the standard COM arrangement.
##
## `IVector<T>` is the mutable one, and is offered only when asked for and
## only over objects and strings. A callee that appends to it appends to the
## view's copy, which is what every projection does — C++/WinRT hands over a
## `single_threaded_vector` the caller no longer holds. Values are left out
## because `Append(T)` takes the element *by value*, which is a different C
## signature per element type; no method in the metadata takes an
## `IVector<T>` of values, so nothing is lost.
##
## `IIterable<T>::First` has to return a separate object again, because an
## iterator has its own position.
##
## ## What crosses
##
## Elements are objects, strings or values. All are *owned* by the view: an
## object is retained on the way in and released when the view dies, a string
## is copied, and a value is copied through its type's own hooks — a plain
## copy for a number, a duplicated handle for a struct holding a
## `WinRtString`. `GetAt` follows WinRT's rule that the caller owns what it
## receives, so it retains again for an object, duplicates again for a string,
## and copies a value the same way.
##
## The IIDs are the caller's business. Every instantiation of a parameterised
## interface has a different one, computed by hashing a signature string, so
## the generated code works them out and passes all three in.

import ./[com, objects]
include ./abidef

type
  ElementKind* = enum
    ekObject   ## an interface pointer, retained
    ekString   ## an HSTRING, copied
    ekValue    ## a number, enum or struct, copied through its hooks

  IterableVtbl {.pure.} = object
    base: IInspectableVtbl
    first: proc(self: pointer, it: ptr pointer): HRESULT {.abi.}

  ViewVtbl {.pure.} = object
    base: IInspectableVtbl
    getAt: proc(self: pointer, index: uint32,
                item: ptr pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    indexOf: proc(self: pointer, item: pointer, index: ptr uint32,
                  found: ptr bool): HRESULT {.abi.}

  VectorVtbl {.pure.} = object
    base: IInspectableVtbl
    getAt: proc(self: pointer, index: uint32,
                item: ptr pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    getView: proc(self: pointer, view: ptr pointer): HRESULT {.abi.}
    indexOf: proc(self: pointer, item: pointer, index: ptr uint32,
                  found: ptr bool): HRESULT {.abi.}
    setAt: proc(self: pointer, index: uint32, item: pointer): HRESULT {.abi.}
    insertAt: proc(self: pointer, index: uint32, item: pointer): HRESULT {.abi.}
    removeAt: proc(self: pointer, index: uint32): HRESULT {.abi.}
    append: proc(self: pointer, item: pointer): HRESULT {.abi.}
    removeAtEnd: proc(self: pointer): HRESULT {.abi.}
    clear: proc(self: pointer): HRESULT {.abi.}
    getMany: proc(self: pointer, start, capacity: uint32, items: ptr pointer,
                  actual: ptr uint32): HRESULT {.abi.}
    replaceAll: proc(self: pointer, count: uint32,
                     items: ptr pointer): HRESULT {.abi.}

  IteratorVtbl {.pure.} = object
    base: IInspectableVtbl
    getCurrent: proc(self: pointer, item: ptr pointer): HRESULT {.abi.}
    getHasCurrent: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    moveNext: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    getMany: proc(self: pointer, capacity: uint32, items: ptr pointer,
                  actual: ptr uint32): HRESULT {.abi.}

  SeqView {.pure.} = object
    ## On the COM heap: WinRT may hold it past the call, release it from any
    ## thread, and its lifetime is COM's rather than Nim's.
    iterableVtbl: ptr IterableVtbl    ## must stay first
    viewVtbl: ptr ViewVtbl
    vectorVtbl: ptr VectorVtbl
    refs: int32
    iterableIid, viewIid, iteratorIid: GUID
    vectorIid: GUID                   ## zero when `IVector<T>` is not offered
    kind: ElementKind
    count, capacity: int32
    version: int32                    ## bumped by every mutation
    items: ptr UncheckedArray[pointer]
    # For `ekValue` the elements are not pointers at all: `items` is a flat
    # buffer of `count * stride` bytes and `GetAt` copies one of them into
    # whatever the caller pointed at. That keeps one implementation for every
    # value type instead of a generic one per instantiation — the ABI shape is
    # the same either way, since the vtable slot only ever sees a `pointer`.
    # Copying and destroying an element are the one thing that is per type,
    # so those come in as procs.
    stride: int32
    copyValue: ValueCopy
    destroyValue: ValueDestroy

  SeqIterator {.pure.} = object
    vtbl: ptr IteratorVtbl
    refs: int32
    iid: GUID
    owner: ptr SeqView
    version: int32                    ## the view's, when this was made
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

proc fromVector(self: pointer): ptr SeqView {.inline.} =
  cast[ptr SeqView](cast[uint](self) - uint(offsetOf(SeqView, vectorVtbl)))

proc valueAt(v: ptr SeqView, slot: int32): pointer {.inline.} =
  cast[pointer](cast[uint](v.items) + uint(slot * v.stride))

proc retain(v: ptr SeqView, slot: int32, item: ptr pointer): HRESULT =
  ## One element, owned by whoever receives it.
  if v.kind == ekValue:
    v.copyValue(item, valueAt(v, slot))
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

proc keep(v: ptr SeqView, item: pointer): pointer =
  ## An element a caller handed in, as the view will own it: an object is
  ## retained, a string duplicated.
  case v.kind
  of ekObject:
    if not item.isNil: discard addRef(item)
    item
  of ekString:
    var dup: HSTRING
    discard windowsDuplicateString(cast[HSTRING](item), dup.addr)
    cast[pointer](dup)
  of ekValue: nil                     # never offered `IVector<T>`

proc drop(v: ptr SeqView, item: pointer) =
  if item.isNil: return
  case v.kind
  of ekObject: discard release(item)
  of ekString: discard windowsDeleteString(cast[HSTRING](item))
  of ekValue: discard

proc destroy(v: ptr SeqView) =
  for i in 0 ..< v.count:
    case v.kind
    of ekValue: v.destroyValue(valueAt(v, i))
    of ekObject: discard release(v.items[i])
    of ekString: discard windowsDeleteString(cast[HSTRING](v.items[i]))
  if v.capacity > 0: comFree(v.items)
  comFree(v)

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

proc vecAddRef(self: pointer): uint32 {.abi.} =
  let v = fromVector(self)
  v.refs.inc
  uint32(v.refs)

proc vecRelease(self: pointer): uint32 {.abi.} =
  let v = fromVector(self)
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
  if v.vectorIid != GUID() and riid[] == v.vectorIid:
    ppv[] = cast[pointer](v.vectorVtbl.addr)
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

proc vecQuery(self: pointer, riid: ptr GUID,
              ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  answer(fromVector(self), riid, ppv)

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

proc indexOf(v: ptr SeqView, item: pointer, index: ptr uint32,
             found: ptr bool): HRESULT =
  ## Identity only. WinRT wants `IUnknown` identity for objects and value
  ## equality for strings; a view built to be read once is not worth the second
  ## of those, and saying "not found" is allowed.
  index[] = 0
  found[] = false
  if v.kind == ekObject:
    for i in 0 ..< v.count:
      if v.items[i] == item:
        index[] = uint32(i)
        found[] = true
        break
  elif v.kind == ekValue and not item.isNil:
    # A value compares by its bytes: equality for numbers, enums and plain
    # structs, identity of the handle for a struct holding a string. "Not
    # found" is an allowed answer either way.
    for i in 0 ..< v.count:
      if equalMem(valueAt(v, i), item, v.stride):
        index[] = uint32(i)
        found[] = true
        break
  S_OK

proc viewIndexOf(self: pointer, item: pointer, index: ptr uint32,
                 found: ptr bool): HRESULT {.abi.} =
  indexOf(fromView(self), item, index, found)

# ----------------------------------------------------------------- IVector<T>

proc grow(v: ptr SeqView) =
  ## Room for one more element.
  if v.count < v.capacity: return
  let cap = max(4'i32, v.capacity * 2)
  v.items = cast[ptr UncheckedArray[pointer]](
    comRealloc(v.items, int(v.capacity) * sizeof(pointer),
                   int(cap) * sizeof(pointer)))
  v.capacity = cap

proc vecGetAt(self: pointer, index: uint32,
              item: ptr pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  if index >= uint32(v.count): return E_BOUNDS
  retain(v, int32(index), item)

proc vecGetSize(self: pointer, size: ptr uint32): HRESULT {.abi.} =
  size[] = uint32(fromVector(self).count)
  S_OK

proc vecGetView(self: pointer, view: ptr pointer): HRESULT {.abi.} =
  ## The view is this same object through its other vtable.
  let v = fromVector(self)
  view[] = cast[pointer](v.viewVtbl.addr)
  v.refs.inc
  S_OK

proc vecIndexOf(self: pointer, item: pointer, index: ptr uint32,
                found: ptr bool): HRESULT {.abi.} =
  indexOf(fromVector(self), item, index, found)

proc vecSetAt(self: pointer, index: uint32, item: pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  if index >= uint32(v.count): return E_BOUNDS
  drop(v, v.items[index])
  v.items[index] = keep(v, item)
  v.version.inc
  S_OK

proc vecInsertAt(self: pointer, index: uint32, item: pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  if index > uint32(v.count): return E_BOUNDS
  v.grow()
  for i in countdown(v.count, int32(index) + 1):
    v.items[i] = v.items[i - 1]
  v.items[index] = keep(v, item)
  v.count.inc
  v.version.inc
  S_OK

proc vecRemoveAt(self: pointer, index: uint32): HRESULT {.abi.} =
  let v = fromVector(self)
  if index >= uint32(v.count): return E_BOUNDS
  drop(v, v.items[index])
  for i in int32(index) ..< v.count - 1:
    v.items[i] = v.items[i + 1]
  v.count.dec
  v.version.inc
  S_OK

proc vecAppend(self: pointer, item: pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  v.grow()
  v.items[v.count] = keep(v, item)
  v.count.inc
  v.version.inc
  S_OK

proc vecRemoveAtEnd(self: pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  if v.count == 0: return E_BOUNDS
  v.count.dec
  drop(v, v.items[v.count])
  v.version.inc
  S_OK

proc vecClear(self: pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  for i in 0 ..< v.count: drop(v, v.items[i])
  v.count = 0
  v.version.inc
  S_OK

proc vecGetMany(self: pointer, start, capacity: uint32, items: ptr pointer,
                actual: ptr uint32): HRESULT {.abi.} =
  let v = fromVector(self)
  let dest = cast[ptr UncheckedArray[pointer]](items)
  var n = 0'u32
  while n < capacity and start + n < uint32(v.count):
    let hr = retain(v, int32(start + n), dest[n].addr)
    if failed(hr):
      actual[] = n
      return hr
    n.inc
  actual[] = n
  S_OK

proc vecReplaceAll(self: pointer, count: uint32,
                   items: ptr pointer): HRESULT {.abi.} =
  let v = fromVector(self)
  for i in 0 ..< v.count: drop(v, v.items[i])
  v.count = 0
  let src = cast[ptr UncheckedArray[pointer]](items)
  for i in 0 ..< int32(count):
    v.grow()
    v.items[v.count] = keep(v, src[i])
    v.count.inc
  v.version.inc
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
    comFree(it)
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
  if it.version != it.owner.version: return E_CHANGED_STATE
  if it.pos >= it.owner.count: return E_BOUNDS
  retain(it.owner, it.pos, item)

proc iterHasCurrent(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  has[] = it.pos < it.owner.count
  S_OK

proc iterMoveNext(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr SeqIterator](self)
  if it.version != it.owner.version: return E_CHANGED_STATE
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
  base: IInspectableVtbl(queryInterface: iterQuery, addRef: iterAddRef, release: iterRelease,
         getIids: noIids, getRuntimeClassName: noName, getTrustLevel: baseTrust),
  getCurrent: iterCurrent, getHasCurrent: iterHasCurrent,
  moveNext: iterMoveNext, getMany: iterGetMany)

proc viewFirst(self: pointer, outIt: ptr pointer): HRESULT {.abi.} =
  let v = fromIterable(self)
  let it = cast[ptr SeqIterator](comAlloc(sizeof(SeqIterator)))
  it.vtbl = iteratorVtbl.addr
  it.refs = 1
  it.iid = v.iteratorIid
  it.owner = v
  it.version = v.version
  it.pos = 0
  discard viewAddRef(cast[pointer](v))    # the iterator keeps the view alive
  outIt[] = cast[pointer](it)
  S_OK

var iterableVtbl = IterableVtbl(
  base: IInspectableVtbl(queryInterface: viewQuery, addRef: viewAddRef, release: viewRelease,
         getIids: noIids, getRuntimeClassName: noName, getTrustLevel: baseTrust),
  first: viewFirst)

var viewVtbl = ViewVtbl(
  base: IInspectableVtbl(queryInterface: viewQueryV, addRef: viewAddRefV,
         release: viewReleaseV, getIids: noIids, getRuntimeClassName: noName,
         getTrustLevel: baseTrust),
  getAt: viewGetAt, getSize: viewGetSize, indexOf: viewIndexOf)

var vectorVtbl = VectorVtbl(
  base: IInspectableVtbl(queryInterface: vecQuery, addRef: vecAddRef,
         release: vecRelease, getIids: noIids, getRuntimeClassName: noName,
         getTrustLevel: baseTrust),
  getAt: vecGetAt, getSize: vecGetSize, getView: vecGetView,
  indexOf: vecIndexOf, setAt: vecSetAt, insertAt: vecInsertAt,
  removeAt: vecRemoveAt, append: vecAppend, removeAtEnd: vecRemoveAtEnd,
  clear: vecClear, getMany: vecGetMany, replaceAll: vecReplaceAll)

proc newSeqView(kind: ElementKind, n: int,
                iterableIid, viewIid, iteratorIid, vectorIid: GUID,
                stride = sizeof(pointer)): ptr SeqView =
  result = cast[ptr SeqView](comAlloc(sizeof(SeqView)))
  result.iterableVtbl = iterableVtbl.addr
  result.viewVtbl = viewVtbl.addr
  result.vectorVtbl = vectorVtbl.addr
  result.refs = 1
  result.iterableIid = iterableIid
  result.viewIid = viewIid
  result.iteratorIid = iteratorIid
  result.vectorIid = vectorIid
  result.kind = kind
  result.count = int32(n)
  result.capacity = int32(n)
  result.stride = int32(stride)
  if n > 0:
    result.items = cast[ptr UncheckedArray[pointer]](comAlloc(n * stride))

proc asIterable*(items: seq[pointer], iterableIid, viewIid, iteratorIid: GUID,
                 vectorIid = GUID()): pointer =
  ## A seq of interface pointers, each a reference the view takes over, as
  ## something WinRT can iterate.
  ##
  ## Returned with a reference count of 1. Pass it to the method and release
  ## it; the object frees itself once the callee lets go, which may be after
  ## the call returns. With `vectorIid` it also answers for `IVector<T>`, over
  ## its own copy of the elements.
  let v = newSeqView(ekObject, items.len, iterableIid, viewIid, iteratorIid,
                     vectorIid)
  for i, p in items:
    v.items[i] = p
  cast[pointer](v)

proc asIterableValue*[T](items: seq[T],
                         iterableIid, viewIid, iteratorIid: GUID): pointer =
  ## The same for a seq of values — numbers, enums, structs — copied into a
  ## flat buffer the view owns, each through `T`'s own hooks, so a struct
  ## holding a `WinRtString` holds its own copy of it.
  let v = newSeqView(ekValue, items.len, iterableIid, viewIid, iteratorIid,
                     GUID(), sizeof(T))
  v.copyValue = copyValue[T]
  v.destroyValue = destroyValue[T]
  for i, x in items:
    cast[ptr T](valueAt(v, int32(i)))[] = x
  cast[pointer](v)

proc asIterableString*(items: seq[string],
                       iterableIid, viewIid, iteratorIid: GUID,
                       vectorIid = GUID()): pointer =
  ## The same for a seq of strings, each copied into an HSTRING the view owns.
  let v = newSeqView(ekString, items.len, iterableIid, viewIid, iteratorIid,
                     vectorIid)
  for i, s in items:
    v.items[i] = cast[pointer](s.toHString)
  cast[pointer](v)
