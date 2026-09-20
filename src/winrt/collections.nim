## Collections and arrays, in both directions.
##
## A WinRT collection is an object — an `IVectorView<T>`, an `IMap<K, V>` —
## and a Nim program wants a `seq` or a `Table`. Reading one is `takeSeq`
## and `takeTable`; handing one over is `asCollection` and `asMap`, which
## build an object of this library's own around the seq or the Table (see
## `seqview` and `mapview` for the object). An array crosses as a count and a
## pointer, and `takeArray` and `asArray` are the same two directions for it.
##
## Each of these is generic over the *metadata* type, spelled with the ABI's
## generic vtables — `IVectorViewVtbl[StorageFile]` — because that is what
## decides the IIDs involved, and over the Nim type it reads as or is given,
## which the caller spells because Nim cannot work a result type out on its
## own. So a collection read is `takeSeq[IVectorViewVtbl[StorageFile],
## seq[StorageFile]](p)`: what it is on the wire, and what comes back.
##
## Neither type is written as `Api(M)` or `Abi(M)` in a signature here, though
## both are used freely inside these bodies. A generic whose *signature*
## expands a template reports an injected symbol wherever it is instantiated,
## and that note would land in the program of anyone calling a method that
## takes a `Some...` type class.

import ./[com, objects, values, seqview, mapview]
import ./abi/[types, generic]

# ------------------------------------------------------- one value across

proc takeSeq*[M, R](collection: pointer): R
proc takeTable*[M, R](map: pointer): R

proc readValue*[T, R, A](abi: A): R =
  ## What arrived as the ABI form of a `T`, as its Nim type `R` — the value
  ## we were *handed*: an object's reference, a string's handle, a
  ## collection, are ours and are taken. `A` is what it arrived as.
  when T is string: takeString(abi)
  elif T is WinRtObject: adopt[T](abi)
  elif T is IReferenceVtbl: takeReference[Api(T.T)](abi)
  elif T is IVectorViewVtbl or T is IVectorVtbl or T is IIterableVtbl or
       T is IObservableVectorVtbl: takeSeq[T, R](abi)
  elif T is IMapViewVtbl or T is IMapVtbl or T is IObservableMapVtbl:
    takeTable[T, R](abi)
  elif T is IUnknownVtbl: adopt[WinRtObject](abi)
  else:
    mixin fromAbi
    when compiles(fromAbi(abi)): fromAbi(abi)   # a struct with a twin
    else: abi

proc borrowValue*[T, R, A](abi: A): R =
  ## `readValue` for a value we were *lent* — a delegate's arguments — so
  ## an object is retained and a string copied rather than taken.
  when T is string: $abi
  elif T is WinRtObject: borrow[T](abi)
  elif T is IReferenceVtbl: readReference[Api(T.T)](abi)
  elif T is IUnknownVtbl: borrow[WinRtObject](abi)
  else:
    mixin fromAbi
    when compiles(fromAbi(abi)): fromAbi(abi)
    else: abi

proc elementIid[E](): GUID =
  ## The interface an element of type `E` is handed over as: an interface
  ## wrapper's own, a class's default, `IInspectable` for `Object`.
  when E is WinRtInterface: iid(E)
  elif WinRtObject is E: IID_IInspectable
  elif E is WinRtObject: defaultIid(E)
  else: iid(E)                    # a nested collection or reference

# -------------------------------------------------------------- reading

iterator elements[T, A](collection: pointer): A =
  ## Every element of an `IIterable<T>`, through its iterator, each one ours
  ## to take. `A` is the ABI form of a `T`.
  let iterable = queryInterface[IIterableVtbl[T]](collection)
  var cursor: pointer
  (iterable.vtbl.First)(iterable.raw, cursor.addr).check("IIterable.First")
  let owner = adopt[WinRtObject](cursor)
  let it = queryInterface[IIteratorVtbl[T]](owner)
  var more: bool
  (it.vtbl.get_HasCurrent)(it.raw, more.addr).check("IIterator.get_HasCurrent")
  while more:
    var item: A
    (it.vtbl.get_Current)(it.raw, item.addr).check("IIterator.get_Current")
    yield item
    (it.vtbl.MoveNext)(it.raw, more.addr).check("IIterator.MoveNext")

proc takeSeq*[M, R](collection: pointer): R =
  ## Every element of a WinRT collection, as a `seq`, the collection
  ## released. `M` is the metadata type — `IVectorViewVtbl[T]`, `IVectorVtbl[T]`
  ## or `IIterableVtbl[T]` — and only a vector can be indexed, so an iterable
  ## is walked instead.
  if collection.isNil: return
  try:
    when M is IIterableVtbl:
      for item in elements[M.T, Abi(M.T)](collection):
        result.add readValue[M.T, Api(M.T), Abi(M.T)](item)
    else:
      # `IObservableVector<T>` declares only its change event; the reading
      # is `IVector<T>`, which it requires.
      when M is IObservableVectorVtbl:
        let it = queryInterface[IVectorVtbl[M.T]](collection)
      else:
        let it = queryInterface[M](collection)
      var count: uint32
      (it.vtbl.get_Size)(it.raw, count.addr).check("collection.get_Size")
      for i in 0'u32 ..< count:
        var item: Abi(M.T)
        (it.vtbl.GetAt)(it.raw, i, item.addr).check("collection.GetAt")
        result.add readValue[M.T, Api(M.T), Abi(M.T)](item)
  finally:
    release(collection)

proc takeTable*[M, R](map: pointer): R =
  ## Every entry of a WinRT map, as a `Table`, the map released. A map is
  ## read by iterating it: `IMapView<K, V>` is an `IIterable<IKeyValuePair<K,
  ## V>>`. `Lookup` exists too, but only iteration gives everything without
  ## knowing the keys first.
  if map.isNil: return
  try:
    for raw in elements[IKeyValuePairVtbl[M.K, M.V], pointer](map):
      let pair = adopt[WinRtObject](raw)
      let it = queryInterface[IKeyValuePairVtbl[M.K, M.V]](pair)
      var k: Abi(M.K)
      var v: Abi(M.V)
      (it.vtbl.get_Key)(it.raw, k.addr).check("IKeyValuePair.get_Key")
      (it.vtbl.get_Value)(it.raw, v.addr).check("IKeyValuePair.get_Value")
      result[readValue[M.K, Api(M.K), Abi(M.K)](k)] =
        readValue[M.V, Api(M.V), Abi(M.V)](v)
  finally:
    release(map)

proc borrowSeq*[M, R](collection: pointer): R =
  ## A collection we were lent — a delegate's argument — read without
  ## taking it.
  addRef(collection)
  takeSeq[M, R](collection)

proc borrowTable*[M, R](map: pointer): R =
  ## A map we were lent, read without taking it.
  addRef(map)
  takeTable[M, R](map)

# -------------------------------------------------------------- handing over

proc abiValue*[E, V](value: V): WinRtObject
  ## An element as it goes into a collection or a map: see below.

proc asCollection*[E, S](items: S): WinRtObject =
  ## `items` as an object WinRT can read as an `IIterable<E>`, an
  ## `IVectorView<E>` or an `IVector<E>`: a view over the seq's contents,
  ## which the callee keeps for as long as it likes. Released when the
  ## returned value goes out of scope; the callee holds its own reference.
  let iterable = iid(IIterableVtbl[E])
  let view = iid(IVectorViewVtbl[E])
  let cursor = iid(IIteratorVtbl[E])
  when E is string:
    adopt[WinRtObject](asIterableString(items, iterable, view, cursor,
                                        iid(IVectorVtbl[E])))
  elif E is WinRtObject or E is IUnknownVtbl:
    # Each element narrowed to `E`, and a reference of each handed to the
    # view: the wrappers below let go of theirs when this returns.
    var owned: seq[WinRtObject]
    var raws: seq[pointer]
    for x in items:
      owned.add abiValue[E, Api(E)](x)
      addRef(owned[^1].raw)
      raws.add owned[^1].raw
    adopt[WinRtObject](asIterable(raws, iterable, view, cursor,
                                  iid(IVectorVtbl[E])))
  else:
    mixin toAbi
    when compiles(toAbi(items[0])):
      var abis: seq[Abi(E)]
      for x in items: abis.add toAbi(x)
      adopt[WinRtObject](asIterableValue[Abi(E)](abis, iterable, view, cursor))
    else:
      adopt[WinRtObject](asIterableValue[E](items, iterable, view, cursor))

proc asMap*[K, V, Entries](entries: Entries): WinRtObject =
  ## `entries` as an object WinRT can read as an `IMap<K, V>`, an
  ## `IMapView<K, V>` or iterate as pairs. Released when the returned value
  ## goes out of scope; the callee holds its own reference.
  let iids = MapIids(iterable: iid(IIterableVtbl[IKeyValuePairVtbl[K, V]]),
                     cursor: iid(IIteratorVtbl[IKeyValuePairVtbl[K, V]]),
                     pair: iid(IKeyValuePairVtbl[K, V]),
                     view: iid(IMapViewVtbl[K, V]), map: iid(IMapVtbl[K, V]))
  when V is WinRtObject or V is IUnknownVtbl:
    # Values go in as the interface the map is declared over.
    var narrowed: Table[Api(K), WinRtObject]
    for k, v in entries: narrowed[k] = abiValue[V, Api(V)](v)
    adopt[WinRtObject](mapview.asMap(narrowed, iids))
  else:
    adopt[WinRtObject](mapview.asMap(entries, iids))

proc abiValue*[E, V](value: V): WinRtObject =
  ## An object as a collection or map of `E` holds it: narrowed to `E`'s
  ## interface, or, for a nested collection, built. The result owns one
  ## reference.
  when E is IVectorViewVtbl or E is IVectorVtbl or E is IIterableVtbl:
    asCollection[E.T, V](value)
  elif E is IMapViewVtbl or E is IMapVtbl:
    asMap[E.K, E.V, V](value)
  elif E is IReferenceVtbl:
    WinRtObject(raw: asReference[Api(E.T)](value).raw)
  else:
    if value.isNil: return WinRtObject()
    let p = queryInterface(value.raw, elementIid[E]())
    if p.isNil:
      raise newException(WinRtError, "winrt: " & runtimeClassName(value) &
        " does not implement " & $E)
    WinRtObject(raw: p)

# --------------------------------------------------------------- arrays

# WinRT passes an array as two arguments — a count and a pointer — and who
# frees it depends on the direction. An argument we pass is ours throughout.
# A *received* array was allocated by the callee with `CoTaskMemAlloc` and is
# ours to free, and if its elements are strings or objects then each of those
# is ours as well.

proc takeArray*[E, R](size: uint32, data: pointer): R =
  ## A received array, its elements taken and the buffer released.
  if data.isNil: return
  let items = cast[ptr UncheckedArray[Abi(E)]](data)
  result = newSeq[Api(E)](int(size))
  for i in 0 ..< int(size):
    result[i] = readValue[E, Api(E), Abi(E)](move(items[i]))
  comFree(data)

proc borrowArray*[E, R](size: uint32, data: pointer): R =
  ## An array we were lent — a delegate's argument — read element by
  ## element, nothing taken.
  if data.isNil: return
  let items = cast[ptr UncheckedArray[Abi(E)]](data)
  result = newSeq[Api(E)](int(size))
  for i in 0 ..< int(size):
    result[i] = borrowValue[E, Api(E), Abi(E)](items[i])

type PassedArray*[E] = object
  ## An array on its way in, for the length of a call: `count` and `data`
  ## are what the method takes. Strings and objects are converted into a
  ## buffer of their own, and what the buffer points at is owned here for as
  ## long as this lives; values are pointed at where they lie.
  count*: uint32
  data*: ptr Abi(E)
  buffer: seq[Abi(E)]
  strings: seq[WinRtString]
  objects: seq[WinRtObject]

proc asArray*[E, X](items: openArray[X]): PassedArray[E] =
  ## `items` as the count and the pointer a call takes, for as long as the
  ## value returned here lives.
  result.count = uint32(items.len)
  when E is string:
    for s in items:
      result.strings.add toWinRtString(s)
      result.buffer.add result.strings[^1].handle
  elif E is WinRtObject or E is IUnknownVtbl:
    for x in items:
      result.objects.add abiValue[E, X](x)
      result.buffer.add result.objects[^1].raw
  else:
    mixin toAbi
    when compiles(toAbi(items[0])):
      for x in items: result.buffer.add toAbi(x)
    else:
      for x in items: result.buffer.add x
  if result.buffer.len > 0: result.data = result.buffer[0].addr
