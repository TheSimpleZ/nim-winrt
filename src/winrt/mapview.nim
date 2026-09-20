## Handing a Nim `Table` to WinRT.
##
## `core` reads a map the runtime gave us. This is the other direction: a
## method that takes an `IMap<K, V>`, an `IMapView<K, V>` or an
## `IIterable<IKeyValuePair<K, V>>` wants an object implementing those, so one
## is built around a copy of the table.
##
## ## Three interfaces, three vtables
##
## All three put their own first method at slot 6 — `First`, `Lookup`, and
## `Lookup` again with a different tail — so the object begins with three
## vtable pointers and `QueryInterface` hands out the address of whichever
## field matches. Each method recovers the object by subtracting that field's
## offset, which is the standard COM arrangement for this. The pairs an
## iterator produces and the iterator itself are objects of their own.
##
## ## What crosses
##
## Keys are strings or GUIDs; values are strings or objects. Strings are copied
## into HSTRINGs the map owns, objects retained, GUIDs copied. The map is a
## *copy* of the table. A callee that inserts into it changes its copy, which
## is what every projection does — C++/WinRT hands over a `single_threaded_map`
## the caller no longer holds — and the alternative, writing back into the
## caller's `Table` after the call, would have to guess when the callee is
## finished with it.
##
## Why those and not any key and any value: `Lookup(key)`, `HasKey(key)` and
## `Insert(key, value)` take them *by value*, and the C signature depends on
## the size. A string, an object and a struct of more than eight bytes all
## arrive as one pointer-sized argument — the HSTRING, the interface pointer,
## the address of the caller's copy — so one vtable serves all of them. A
## four-byte key — an enum, an `Int32` — arrives in the register itself, so
## those get a second pair of vtables whose only difference is that argument;
## no map in the metadata is keyed by anything else on the way in, or valued
## by anything but a string or an object.
##
## Nothing here is Nim memory at all: WinRT may hold the map past the call,
## walk it and release it from another thread, and on a thread Nim never set
## up neither its allocator nor a destructor may run. Everything lives on the
## COM heap — see `comAlloc` in `core`.
##
## The IIDs are the caller's business. Five instantiations are involved and
## none is declared anywhere, so the generated code computes them and passes
## them in as one `MapIids`.

import ./core
import ./seqview
include ./abidef

type
  MapIids* = object
    ## The instantiations one map answers for.
    iterable*: GUID   ## `IIterable<IKeyValuePair<K, V>>`
    cursor*: GUID     ## `IIterator<IKeyValuePair<K, V>>` — `iterator` is a keyword
    pair*: GUID       ## `IKeyValuePair<K, V>`
    view*: GUID       ## `IMapView<K, V>`
    map*: GUID        ## `IMap<K, V>`

  IterableVtbl {.pure.} = object
    base: IInspectableVtbl
    first: proc(self: pointer, it: ptr pointer): HRESULT {.abi.}

  ViewVtbl {.pure.} = object
    base: IInspectableVtbl
    lookup: proc(self: pointer, key: pointer, value: pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    hasKey: proc(self: pointer, key: pointer, found: ptr bool): HRESULT {.abi.}
    split: proc(self: pointer, first, second: ptr pointer): HRESULT {.abi.}

  MapVtbl {.pure.} = object
    base: IInspectableVtbl
    lookup: proc(self: pointer, key: pointer, value: pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    hasKey: proc(self: pointer, key: pointer, found: ptr bool): HRESULT {.abi.}
    getView: proc(self: pointer, view: ptr pointer): HRESULT {.abi.}
    insert: proc(self: pointer, key, value: pointer,
                 replaced: ptr bool): HRESULT {.abi.}
    remove: proc(self: pointer, key: pointer): HRESULT {.abi.}
    clear: proc(self: pointer): HRESULT {.abi.}

  # The same two, for a key that arrives in a register.
  ViewVtbl32 {.pure.} = object
    base: IInspectableVtbl
    lookup: proc(self: pointer, key: uint32, value: pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    hasKey: proc(self: pointer, key: uint32, found: ptr bool): HRESULT {.abi.}
    split: proc(self: pointer, first, second: ptr pointer): HRESULT {.abi.}

  MapVtbl32 {.pure.} = object
    base: IInspectableVtbl
    lookup: proc(self: pointer, key: uint32, value: pointer): HRESULT {.abi.}
    getSize: proc(self: pointer, size: ptr uint32): HRESULT {.abi.}
    hasKey: proc(self: pointer, key: uint32, found: ptr bool): HRESULT {.abi.}
    getView: proc(self: pointer, view: ptr pointer): HRESULT {.abi.}
    insert: proc(self: pointer, key: uint32, value: pointer,
                 replaced: ptr bool): HRESULT {.abi.}
    remove: proc(self: pointer, key: uint32): HRESULT {.abi.}
    clear: proc(self: pointer): HRESULT {.abi.}

  PairVtbl {.pure.} = object
    base: IInspectableVtbl
    getKey: proc(self: pointer, key: pointer): HRESULT {.abi.}
    getValue: proc(self: pointer, value: pointer): HRESULT {.abi.}

  IteratorVtbl {.pure.} = object
    base: IInspectableVtbl
    getCurrent: proc(self: pointer, item: ptr pointer): HRESULT {.abi.}
    getHasCurrent: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    moveNext: proc(self: pointer, has: ptr bool): HRESULT {.abi.}
    getMany: proc(self: pointer, capacity: uint32, items: ptr pointer,
                  actual: ptr uint32): HRESULT {.abi.}

  Column = object
    ## One side of the map — all the keys, or all the values — in one buffer.
    kind: ElementKind
    stride: int32
    data: pointer        ## `count * stride` bytes, `capacity` slots
    copyValue: ValueCopy       ## for `ekValue`: a copy through the type's hooks
    destroyValue: ValueDestroy

  MapObj {.pure.} = object
    iterableVtbl: ptr IterableVtbl   ## must stay first
    viewVtbl: ptr ViewVtbl
    mapVtbl: ptr MapVtbl
    refs: int32
    iids: MapIids
    count, capacity: int32
    version: int32       ## bumped by every mutation, checked by iterators
    keys, vals: Column

  PairObj {.pure.} = object
    vtbl: ptr PairVtbl
    refs: int32
    iid: GUID
    keys, vals: Column   ## one slot each, owned by the pair

  MapIterator {.pure.} = object
    vtbl: ptr IteratorVtbl
    refs: int32
    iid: GUID
    owner: ptr MapObj
    version: int32
    pos: int32

# `QueryInterface` hands out the address of a vtable field, so a method arrives
# holding that field rather than the object. These put it back.
proc fromIterable(self: pointer): ptr MapObj {.inline.} = cast[ptr MapObj](self)
proc fromView(self: pointer): ptr MapObj {.inline.} =
  cast[ptr MapObj](cast[uint](self) - uint(offsetOf(MapObj, viewVtbl)))
proc fromMap(self: pointer): ptr MapObj {.inline.} =
  cast[ptr MapObj](cast[uint](self) - uint(offsetOf(MapObj, mapVtbl)))

# ------------------------------------------------------------------ columns

proc slot(c: Column, i: int32): pointer {.inline.} =
  cast[pointer](cast[uint](c.data) + uint(i * c.stride))

# An element as a method receives it: the HSTRING or interface pointer itself
# for a string or an object, the address of the caller's copy for a value.
# `take` and `same` read that shape; `argOf` produces it from a slot.

proc argOf(c: Column, i: int32): pointer {.inline.} =
  if c.kind == ekValue: c.slot(i) else: cast[ptr pointer](c.slot(i))[]

proc take(c: var Column, i: int32, arg: pointer) =
  ## Store `arg` in slot `i`, taking a copy or a reference the column owns.
  case c.kind
  of ekString:
    var dup: HSTRING
    discard windowsDuplicateString(cast[HSTRING](arg), dup.addr)
    cast[ptr HSTRING](c.slot(i))[] = dup
  of ekObject:
    if not arg.isNil: discard addRef(arg)
    cast[ptr pointer](c.slot(i))[] = arg
  of ekValue:
    c.copyValue(c.slot(i), arg)

proc give(c: Column, i: int32, dst: pointer): HRESULT =
  ## Hand slot `i` to a caller at `dst`, who then owns what they receive.
  case c.kind
  of ekString:
    windowsDuplicateString(cast[ptr HSTRING](c.slot(i))[], cast[ptr HSTRING](dst))
  of ekObject:
    let p = cast[ptr pointer](c.slot(i))[]
    if not p.isNil: discard addRef(p)
    cast[ptr pointer](dst)[] = p
    S_OK
  of ekValue:
    c.copyValue(dst, c.slot(i))
    S_OK

proc drop(c: Column, i: int32) =
  case c.kind
  of ekString: discard windowsDeleteString(cast[ptr HSTRING](c.slot(i))[])
  of ekObject:
    let p = cast[ptr pointer](c.slot(i))[]
    if not p.isNil: discard release(p)
  of ekValue: c.destroyValue(c.slot(i))

proc same(c: Column, i: int32, arg: pointer): bool =
  ## Whether slot `i` holds `arg`, by the equality each shape has: strings by
  ## content, objects by identity, values by their bytes — which for a struct
  ## holding a string is the handle's identity, and "not found" is allowed.
  case c.kind
  of ekString: sameString(cast[ptr HSTRING](c.slot(i))[], cast[HSTRING](arg))
  of ekObject: cast[ptr pointer](c.slot(i))[] == arg
  of ekValue: equalMem(c.slot(i), arg, c.stride)

proc newColumn(kind: ElementKind, stride: int, capacity: int32,
               copy: ValueCopy, destroy: ValueDestroy): Column =
  result.kind = kind
  result.stride = int32(stride)
  result.copyValue = copy
  result.destroyValue = destroy
  if capacity > 0: result.data = comAlloc(int(capacity) * stride)

proc grow(m: ptr MapObj) =
  ## Room for one more entry.
  if m.count < m.capacity: return
  let cap = max(4'i32, m.capacity * 2)
  m.keys.data = comRealloc(m.keys.data, int(m.capacity) * m.keys.stride,
                               int(cap) * m.keys.stride)
  m.vals.data = comRealloc(m.vals.data, int(m.capacity) * m.vals.stride,
                               int(cap) * m.vals.stride)
  m.capacity = cap

proc find(m: ptr MapObj, key: pointer): int32 =
  ## The slot holding `key`, or -1. Linear: these are option bags of a few
  ## entries, and a hash over three element shapes is not worth its weight.
  for i in 0 ..< m.count:
    if m.keys.same(i, key): return i
  -1

proc destroy(m: ptr MapObj) =
  for i in 0 ..< m.count:
    m.keys.drop(i)
    m.vals.drop(i)
  if not m.keys.data.isNil: comFree(m.keys.data)
  if not m.vals.data.isNil: comFree(m.vals.data)
  comFree(m)

# ------------------------------------------------------------- IInspectable

proc noIids(self: pointer, count: ptr uint32,
            iids: ptr ptr GUID): HRESULT {.abi.} =
  count[] = 0
  iids[] = nil
  S_OK

proc noName(self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  name[] = HSTRING(nil)
  S_OK

proc baseTrust(self: pointer, level: ptr int32): HRESULT {.abi.} =
  level[] = 0
  S_OK

proc answer(m: ptr MapObj, riid: ptr GUID, ppv: ptr pointer): HRESULT =
  ## Whichever vtable the caller asked for.
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == m.iids.iterable:
    ppv[] = cast[pointer](m)
  elif riid[] == m.iids.view:
    ppv[] = cast[pointer](m.viewVtbl.addr)
  elif riid[] == m.iids.map:
    ppv[] = cast[pointer](m.mapVtbl.addr)
  else:
    ppv[] = nil
    return E_NOINTERFACE
  m.refs.inc
  S_OK

template inspectable(prefix, recover: untyped) =
  ## The IUnknown half of a vtable, for one of the three entry points.
  proc `prefix AddRef`(self: pointer): uint32 {.abi.} =
    let m = recover(self)
    m.refs.inc
    uint32(m.refs)
  proc `prefix Release`(self: pointer): uint32 {.abi.} =
    let m = recover(self)
    m.refs.dec
    if m.refs <= 0:
      destroy(m)
      return 0
    uint32(m.refs)
  proc `prefix Query`(self: pointer, riid: ptr GUID,
                      ppv: ptr pointer): HRESULT {.abi.} =
    if ppv.isNil: return E_POINTER
    answer(recover(self), riid, ppv)

inspectable(iterable, fromIterable)
inspectable(view, fromView)
inspectable(map, fromMap)

# ------------------------------------------------------------ IMapView<K, V>

proc lookupIn(m: ptr MapObj, key, value: pointer): HRESULT =
  let i = m.find(key)
  if i < 0: return E_BOUNDS
  m.vals.give(i, value)

proc viewLookup(self: pointer, key, value: pointer): HRESULT {.abi.} =
  lookupIn(fromView(self), key, value)

proc viewSize(self: pointer, size: ptr uint32): HRESULT {.abi.} =
  size[] = uint32(fromView(self).count)
  S_OK

proc viewHasKey(self: pointer, key: pointer, found: ptr bool): HRESULT {.abi.} =
  found[] = fromView(self).find(key) >= 0
  S_OK

proc viewSplit(self: pointer, first, second: ptr pointer): HRESULT {.abi.} =
  ## Splitting is a hint for parallel walks and may decline; a view that
  ## declines answers with two nulls.
  first[] = nil
  second[] = nil
  S_OK

# ---------------------------------------------------------------- IMap<K, V>

proc mapLookup(self: pointer, key, value: pointer): HRESULT {.abi.} =
  lookupIn(fromMap(self), key, value)

proc mapSize(self: pointer, size: ptr uint32): HRESULT {.abi.} =
  size[] = uint32(fromMap(self).count)
  S_OK

proc mapHasKey(self: pointer, key: pointer, found: ptr bool): HRESULT {.abi.} =
  found[] = fromMap(self).find(key) >= 0
  S_OK

proc mapGetView(self: pointer, view: ptr pointer): HRESULT {.abi.} =
  ## The view is this same object through its other vtable. A snapshot would
  ## be more faithful to the contract and is not worth the copy for a map
  ## the callee is about to read once.
  let m = fromMap(self)
  view[] = cast[pointer](m.viewVtbl.addr)
  m.refs.inc
  S_OK

proc mapInsert(self: pointer, key, value: pointer,
               replaced: ptr bool): HRESULT {.abi.} =
  let m = fromMap(self)
  var i = m.find(key)
  if i >= 0:
    m.vals.drop(i)
    replaced[] = true
  else:
    m.grow()
    i = m.count
    m.count.inc
    m.keys.take(i, key)
    replaced[] = false
  m.vals.take(i, value)
  m.version.inc
  S_OK

proc mapRemove(self: pointer, key: pointer): HRESULT {.abi.} =
  let m = fromMap(self)
  let i = m.find(key)
  if i < 0: return E_BOUNDS
  m.keys.drop(i)
  m.vals.drop(i)
  # Close the gap; order is not part of a map's contract.
  let last = m.count - 1
  if i != last:
    copyMem(m.keys.slot(i), m.keys.slot(last), m.keys.stride)
    copyMem(m.vals.slot(i), m.vals.slot(last), m.vals.stride)
  m.count.dec
  m.version.inc
  S_OK

proc mapClear(self: pointer): HRESULT {.abi.} =
  let m = fromMap(self)
  for i in 0 ..< m.count:
    m.keys.drop(i)
    m.vals.drop(i)
  m.count = 0
  m.version.inc
  S_OK

# A four-byte key lands in a local and continues through the pointer path.
proc viewLookup32(self: pointer, key: uint32, value: pointer): HRESULT {.abi.} =
  var k = key
  viewLookup(self, k.addr, value)
proc viewHasKey32(self: pointer, key: uint32, found: ptr bool): HRESULT {.abi.} =
  var k = key
  viewHasKey(self, k.addr, found)
proc mapLookup32(self: pointer, key: uint32, value: pointer): HRESULT {.abi.} =
  var k = key
  mapLookup(self, k.addr, value)
proc mapHasKey32(self: pointer, key: uint32, found: ptr bool): HRESULT {.abi.} =
  var k = key
  mapHasKey(self, k.addr, found)
proc mapInsert32(self: pointer, key: uint32, value: pointer,
                 replaced: ptr bool): HRESULT {.abi.} =
  var k = key
  mapInsert(self, k.addr, value, replaced)
proc mapRemove32(self: pointer, key: uint32): HRESULT {.abi.} =
  var k = key
  mapRemove(self, k.addr)

# ---------------------------------------------------------- IKeyValuePair<K, V>

proc pairAddRef(self: pointer): uint32 {.abi.} =
  let p = cast[ptr PairObj](self)
  p.refs.inc
  uint32(p.refs)

proc pairRelease(self: pointer): uint32 {.abi.} =
  let p = cast[ptr PairObj](self)
  p.refs.dec
  if p.refs <= 0:
    p.keys.drop(0)
    p.vals.drop(0)
    comFree(p.keys.data)
    comFree(p.vals.data)
    comFree(p)
    return 0
  uint32(p.refs)

proc pairQuery(self: pointer, riid: ptr GUID, ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let p = cast[ptr PairObj](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == p.iid:
    ppv[] = self
    discard pairAddRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc pairKey(self: pointer, key: pointer): HRESULT {.abi.} =
  cast[ptr PairObj](self).keys.give(0, key)

proc pairValue(self: pointer, value: pointer): HRESULT {.abi.} =
  cast[ptr PairObj](self).vals.give(0, value)

var pairVtbl = PairVtbl(
  base: IInspectableVtbl(queryInterface: pairQuery, addRef: pairAddRef,
                        release: pairRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  getKey: pairKey, getValue: pairValue)

proc newPair(m: ptr MapObj, i: int32): pointer =
  ## Entry `i` as a pair of its own, holding copies so that it outlives any
  ## later change to the map.
  let p = cast[ptr PairObj](comAlloc(sizeof(PairObj)))
  p.vtbl = pairVtbl.addr
  p.refs = 1
  p.iid = m.iids.pair
  p.keys = newColumn(m.keys.kind, m.keys.stride, 1,
                     m.keys.copyValue, m.keys.destroyValue)
  p.vals = newColumn(m.vals.kind, m.vals.stride, 1,
                     m.vals.copyValue, m.vals.destroyValue)
  p.keys.take(0, m.keys.argOf(i))
  p.vals.take(0, m.vals.argOf(i))
  cast[pointer](p)

# ------------------------------------------------ IIterator<IKeyValuePair<K, V>>

proc iterAddRef(self: pointer): uint32 {.abi.} =
  let it = cast[ptr MapIterator](self)
  it.refs.inc
  uint32(it.refs)

proc iterRelease(self: pointer): uint32 {.abi.} =
  let it = cast[ptr MapIterator](self)
  it.refs.dec
  if it.refs <= 0:
    discard iterableRelease(cast[pointer](it.owner))
    comFree(it)
    return 0
  uint32(it.refs)

proc iterQuery(self: pointer, riid: ptr GUID, ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let it = cast[ptr MapIterator](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == it.iid:
    ppv[] = self
    discard iterAddRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE


proc iterCurrent(self: pointer, item: ptr pointer): HRESULT {.abi.} =
  let it = cast[ptr MapIterator](self)
  if it.version != it.owner.version: return E_CHANGED_STATE
  if it.pos >= it.owner.count: return E_BOUNDS
  item[] = newPair(it.owner, it.pos)
  S_OK

proc iterHasCurrent(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr MapIterator](self)
  has[] = it.pos < it.owner.count
  S_OK

proc iterMoveNext(self: pointer, has: ptr bool): HRESULT {.abi.} =
  let it = cast[ptr MapIterator](self)
  if it.version != it.owner.version: return E_CHANGED_STATE
  if it.pos < it.owner.count: it.pos.inc
  has[] = it.pos < it.owner.count
  S_OK

proc iterGetMany(self: pointer, capacity: uint32, items: ptr pointer,
                 actual: ptr uint32): HRESULT {.abi.} =
  let it = cast[ptr MapIterator](self)
  if it.version != it.owner.version: return E_CHANGED_STATE
  let dest = cast[ptr UncheckedArray[pointer]](items)
  var n = 0'u32
  while n < capacity and it.pos < it.owner.count:
    dest[n] = newPair(it.owner, it.pos)
    it.pos.inc
    n.inc
  actual[] = n
  S_OK

var iteratorVtbl = IteratorVtbl(
  base: IInspectableVtbl(queryInterface: iterQuery, addRef: iterAddRef,
                        release: iterRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  getCurrent: iterCurrent, getHasCurrent: iterHasCurrent,
  moveNext: iterMoveNext, getMany: iterGetMany)

proc iterableFirst(self: pointer, outIt: ptr pointer): HRESULT {.abi.} =
  let m = fromIterable(self)
  let it = cast[ptr MapIterator](comAlloc(sizeof(MapIterator)))
  it.vtbl = iteratorVtbl.addr
  it.refs = 1
  it.iid = m.iids.cursor
  it.owner = m
  it.version = m.version
  discard iterableAddRef(self)     # the iterator keeps the map alive
  outIt[] = cast[pointer](it)
  S_OK

# ------------------------------------------------------------------ the map

var iterableVtbl = IterableVtbl(
  base: IInspectableVtbl(queryInterface: iterableQuery, addRef: iterableAddRef,
                        release: iterableRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  first: iterableFirst)

var viewVtbl = ViewVtbl(
  base: IInspectableVtbl(queryInterface: viewQuery, addRef: viewAddRef,
                        release: viewRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  lookup: viewLookup, getSize: viewSize, hasKey: viewHasKey, split: viewSplit)

var mapVtbl = MapVtbl(
  base: IInspectableVtbl(queryInterface: mapQuery, addRef: mapAddRef,
                        release: mapRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  lookup: mapLookup, getSize: mapSize, hasKey: mapHasKey, getView: mapGetView,
  insert: mapInsert, remove: mapRemove, clear: mapClear)

var viewVtbl32 = ViewVtbl32(
  base: IInspectableVtbl(queryInterface: viewQuery, addRef: viewAddRef,
                        release: viewRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  lookup: viewLookup32, getSize: viewSize, hasKey: viewHasKey32,
  split: viewSplit)

var mapVtbl32 = MapVtbl32(
  base: IInspectableVtbl(queryInterface: mapQuery, addRef: mapAddRef,
                        release: mapRelease, getIids: noIids,
                        getRuntimeClassName: noName, getTrustLevel: baseTrust),
  lookup: mapLookup32, getSize: mapSize, hasKey: mapHasKey32,
  getView: mapGetView, insert: mapInsert32, remove: mapRemove32,
  clear: mapClear)

func shapeOf(T: typedesc): tuple[kind: ElementKind, stride: int] =
  ## How a Nim type is kept in a column.
  when T is string: (ekString, sizeof(HSTRING))
  elif T is WinRtObject: (ekObject, sizeof(pointer))
  else: (ekValue, sizeof(T))

proc asMap*[K, V](entries: Table[K, V], iids: MapIids): pointer =
  ## `entries`, as an object WinRT can read as a map or iterate as pairs.
  ##
  ## Returned with a reference count of 1. Pass it to the method and release
  ## it; the object frees itself once the callee lets go, which may be after
  ## the call returns.
  let (kk, ks) = shapeOf(K)
  let (vk, vs) = shapeOf(V)
  let m = cast[ptr MapObj](comAlloc(sizeof(MapObj)))
  m.iterableVtbl = iterableVtbl.addr
  if kk == ekValue and ks == 4:
    # Only the address of the table is handed out, so the field's type does
    # not have to match the table it points at.
    m.viewVtbl = cast[ptr ViewVtbl](viewVtbl32.addr)
    m.mapVtbl = cast[ptr MapVtbl](mapVtbl32.addr)
  else:
    m.viewVtbl = viewVtbl.addr
    m.mapVtbl = mapVtbl.addr
  m.refs = 1
  m.iids = iids
  m.capacity = int32(entries.len)
  m.keys = newColumn(kk, ks, m.capacity, copyValue[K], destroyValue[K])
  m.vals = newColumn(vk, vs, m.capacity, copyValue[V], destroyValue[V])
  for k, v in entries:
    let i = m.count
    m.count.inc
    # Each side is handed to the column the way a method would hand it: an
    # HSTRING the column duplicates, a pointer it retains, or the address of
    # a value it copies.
    when K is string:
      let hk = toHString(k)
      m.keys.take(i, cast[pointer](hk))
      discard windowsDeleteString(hk)
    elif K is WinRtObject:
      m.keys.take(i, k.p)
    else:
      m.keys.take(i, k.unsafeAddr)
    when V is string:
      let hv = toHString(v)
      m.vals.take(i, cast[pointer](hv))
      discard windowsDeleteString(hv)
    elif V is WinRtObject:
      m.vals.take(i, v.p)
    else:
      m.vals.take(i, v.unsafeAddr)
  cast[pointer](m)
