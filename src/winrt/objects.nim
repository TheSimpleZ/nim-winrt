## What a WinRT object is in Nim, and how a Nim type maps onto the ABI.
##
## Every runtime class and every interface the generated API hands out is an
## object one pointer wide, deriving from `WinRtObject`, whose reference
## counting is written here once. `adopt` and `borrow` are the two ways a raw
## pointer becomes one, and saying which applies is the whole of the lifetime
## contract.
##
## `Abi(T)` is the other half of this module: for a type as the API spells it,
## the type that crosses the ABI in its place — an object is a pointer, a
## string an `HSTRING`, a struct holding either has a twin — which is what the
## generic interfaces in the ABI are declared over.

import std/hashes
import ./[com, runtime]

# ------------------------------------------------------------------ objects

type
  WinRtObject* {.inheritable, pure.} = object
    ## One COM pointer, reference-counted by the compiler: a copy takes a
    ## reference and destruction drops one. `=destroy` and its companions are
    ## inherited, so these cover every class and interface the API declares.
    raw*: pointer

  WinRtInterface* = object of WinRtObject
    ## What an interface's wrapper derives from, so that an interface and a
    ## class can be told apart where that matters — a value of type
    ## `IInputStream` is an object known only by that interface.

  WinRtDelegate* = object of WinRtObject
    ## What a delegate's wrapper derives from: a callback object, whose one
    ## method is `Invoke`. `newDelegate` builds one around a Nim closure.

proc `=destroy`*(x: var WinRtObject) =
  if x.raw != nil: releaseIfLive(x.raw)

proc `=copy`*(dst: var WinRtObject, src: WinRtObject) =
  if dst.raw == src.raw: return
  `=destroy`(dst)
  wasMoved(dst)
  dst.raw = src.raw
  if dst.raw != nil: addRefIfLive(dst.raw)

proc `=sink`*(dst: var WinRtObject, src: WinRtObject) =
  # A move transfers the reference, so neither count changes.
  `=destroy`(dst)
  wasMoved(dst)
  dst.raw = src.raw

func isNil*(x: WinRtObject): bool {.inline.} = x.raw.isNil

func `==`*(a, b: WinRtObject): bool {.inline.} =
  ## Identity: two wrappers around one pointer are the same object, which is
  ## what the runtime means by equality as well.
  a.raw == b.raw

proc hash*(x: WinRtObject): Hash {.inline.} =
  ## By identity, so an object can key a `Table` — `IMap<Uri, String>` is one.
  hash(x.raw)

proc adopt*[T](p: pointer): T =
  ## Wrap a pointer that is already ours — anything a getter, a factory or a
  ## QueryInterface returned, all of which hand over a reference.
  ##
  ## The counterpart of `borrow`. Adopt something you were only lent and the
  ## wrapper releases a reference it never took.
  T(raw: p)

proc borrow*[T](p: pointer): T =
  ## Wrap a pointer we were *lent*, such as an event's sender or arguments.
  ##
  ## The wrapper releases on destruction, so adopting a borrowed pointer
  ## without this would over-release it and free an object still in use.
  if not p.isNil: addRef(p)
  T(raw: p)

proc runtimeClassName*(x: WinRtObject): string =
  ## What the object says it is: `Windows.Foundation.Uri`, whatever the
  ## wrapper's own type.
  runtimeClassName(x.raw)

proc tryQueryInterface*[V](obj: WinRtObject): Interface[V] =
  ## The interface `V` of `obj`, or one that `isNil` if it has none.
  tryQueryInterface[V](obj.raw)

proc queryInterface*[V](obj: WinRtObject): Interface[V] =
  ## The interface `V` of `obj`: what a generated method narrows to before
  ## calling. Raises if the object does not implement it.
  queryInterface[V](obj.raw)

proc activate*[T](): T =
  ## A new instance of the class `T`, which has a parameterless constructor:
  ## what a generated `newCalendar()` is. `className` and `defaultIid` are
  ## the generated `classes` module's.
  adopt[T](activate(className(T), defaultIid(T)))

proc compose*[F, T](): T =
  ## A new instance of the composable class `T`, through its factory `F`.
  adopt[T](compose[F](className(T), defaultIid(T)))

proc to*[T](obj: WinRtObject, _: typedesc[T]): T =
  ## `obj` as the class or interface `T`, if it is one: the way from a value
  ## typed only as `WinRtObject` — an event's untyped sender, an element of an
  ## `IVector<Object>` — back to a type with members. Raises if it is not.
  when T is WinRtInterface:
    let p = queryInterface(obj.raw, iid(T))
  else:
    let p = queryInterface(obj.raw, defaultIid(T))
  if p.isNil and not obj.isNil:
    raise newException(WinRtError, "winrt: " & runtimeClassName(obj) &
      " is not a " & $T)
  T(raw: p)

# ------------------------------------------------------------ the ABI form

template Abi*(T: typedesc): typedesc =
  ## The type that stands for `T` on the wire: a pointer for any object, an
  ## `HSTRING` for a string, and the type itself for a number, an enum, a
  ## struct of those. A struct that holds a string or a reference has a twin
  ## in the ABI module, and declares its own `Abi` there.
  when T is WinRtObject: pointer
  elif T is IUnknownVtbl: pointer
  elif T is string: HSTRING
  else: T

type Reference*[T] = object of WinRtObject
  ## An `IReference<T>` held rather than read: the form a nullable field takes
  ## inside a struct as it crosses the ABI. Being a `WinRtObject`, the struct
  ## keeps the box alive for as long as it is kept.

# A collection handed to Windows keeps values in a flat buffer, and copying or
# destroying one of those has to run the type's hooks — a struct holding a
# `WinRtString` owns a handle. `seqview` and `mapview` keep these two per
# column, instantiated for the element type at hand. The hooks of a WinRT
# value type are nothing at all or a COM call: they raise nothing and touch no
# GC memory, which the compiler cannot see through a generic hook, hence the
# casts.

type
  ValueCopy* = proc(dst, src: pointer) {.nimcall, raises: [], gcsafe.}
    ## `dst[] = src[]` for one value type, hooks included.
  ValueDestroy* = proc(p: pointer) {.nimcall, raises: [], gcsafe.}
    ## `=destroy(p[])` for one value type.

proc copyValue*[T](dst, src: pointer) {.nimcall, raises: [], gcsafe.} =
  {.cast(raises: []), cast(gcsafe).}:
    cast[ptr T](dst)[] = cast[ptr T](src)[]

proc destroyValue*[T](p: pointer) {.nimcall, raises: [], gcsafe.} =
  {.cast(raises: []), cast(gcsafe).}:
    `=destroy`(cast[ptr T](p)[])
