## Emit an idiomatic Nim API on top of the generated ABI layer.
##
## ```
## nim c -r tools/wrappers.nim <winmd> <namespace-prefix> <out.nim>
## ```
##
## `generate.nim` emits what the ABI *is* — IIDs, slot numbers, raw signatures.
## This emits what a person wants to write: `window.title = "Hi"` rather than a
## QueryInterface, a slot index and a manually released HSTRING.
##
## ## Shape
##
## Every runtime class becomes a Nim object in a real inheritance chain, so a
## derived value passes where a base is expected and an inherited method
## resolves without being emitted again. A method is generated once, on the
## class whose own interfaces declare it. Emitting the full inherited surface
## per class instead would mean 94,521 procs rather than about 4,900, for
## exactly the same API.
##
## The first attempt used `distinct pointer` plus a `converter` to each
## ancestor, which does not scale: Nim weighs every converter in scope at every
## type mismatch, and 1,715 of them took one module from 3.6 seconds to over
## seven minutes to compile.
##
## ## Why every call re-queries
##
## Each wrapper QueryInterfaces the receiver before dispatching, and every
## class-typed argument before passing it. That is not free, but it makes the
## worst bug in this codebase unrepresentable: slots are numbered per
## interface, so reaching one through the wrong interface is not an error, it
## is a silent wrong function or a crash. WinUI calls happen at the speed of a
## person clicking, so correctness wins.

import std/[os, algorithm, sequtils, strformat, strutils, tables, sets]
import ./winmd
import ./foreign
import ./piid
import ./nimgen

const tdInterface = 0x20'u32

const GenericIidMarker = "##<computed-iids>##\n"
const ImportsMarker = "##<imports>##\n"
  ## Where the computed IIDs are spliced in. They have to precede every proc
  ## that names one, but are only discovered while those procs are emitted.

const builtinTypeNames = [
  "pointer", "string", "int", "int8", "int16", "int32", "int64", "uint",
  "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64",
  "bool", "char", "byte", "cstring", "seq", "set", "array", "openarray",
  "range", "auto", "any", "typedesc", "void", "natural", "positive"]

func safeMemberName(pascal: string): string =
  ## Lower-case the first letter, unless doing so would shadow a builtin type.
  ##
  ## `PointerRoutedEventArgs.Pointer` is a real property, and `proc pointer*`
  ## makes the word `pointer` ambiguous in every module that imports this one,
  ## including this library's own. Keeping the metadata's capital does not help
  ## either — `Pointer` is also the name of the WinUI class, so the proc would
  ## redefine the type. Hence a suffix: `pointerValue`.
  if pascal.len == 0: return pascal
  let lowered = toLowerAscii(pascal[0]) & pascal[1 .. ^1]
  if lowered.toLowerAscii in builtinTypeNames: lowered & "Value" else: lowered

type
  Ctx = object
    classes: HashSet[string]             ## full names of classes we emit
    enums: HashSet[string]               ## enums the ABI module emits
    ifaceIid: HashSet[string]            ## interfaces that have an IID
    localIface: HashSet[string]          ## ...and whose IID this module can name
    classOfIface: Table[string, string]  ## default interface -> the class it is
    structs: HashSet[string]             ## structs the ABI module laid out
    aliases: Table[string, string]       ## metadata name -> existing Nim type
    defaultIface: Table[string, string]  ## class -> its default interface
    collide: HashSet[string]             ## short names meaning two things
    delegates: Table[string, seq[SigType]]  ## delegate -> its Invoke params
    renamed: Table[string, string]       ## types written under another name

const
  AsyncOps = [
    "Windows.Foundation.IAsyncOperation`1",
    "Windows.Foundation.IAsyncOperationWithProgress`2",
  ]
  AsyncActions = [
    "Windows.Foundation.IAsyncAction",
    "Windows.Foundation.IAsyncActionWithProgress`1",
  ]

# Mutually recursive with the shape helpers below: an async result can be a
# collection, a collection element can be a class, and both ask what a type
# spells as.
func skipReason(c: Ctx, t: SigType, inReturn = false): string
func apiName(c: Ctx, full: string): string =
  ## A class as this module must spell it.
  ##
  ## Two names in the whole of `Windows.winmd` mean one thing as a class and
  ## another as an enum — `Panel` is a XAML layout container and a camera's
  ## front-or-back, `PackageStatus` is a class and a deployment state. Both
  ## are in scope in every module now, so both get qualified; nothing else
  ## does, and unqualified is what a reader should see.
  let n = c.renamed.getOrDefault(full, shortName(full))
  if n in c.collide: "classes." & n else: n

func ifaceName(c: Ctx, full: string): string =
  ## An interface as the ABI spelled its `IID_`, `Slot_` and `Fn_` constants.
  c.renamed.getOrDefault(full, shortName(full))

func abiName(c: Ctx, full: string): string =
  ## The same, for the enum or struct side of such a pair.
  ##
  ## `renamed` is the other way a spelling can differ: two enums in the whole
  ## of the metadata share a short name, so the ABI wrote the second under a
  ## qualified one and this has to agree or it names a type that is not there.
  let n = c.renamed.getOrDefault(full, shortName(full))
  if n in c.collide: "types." & n else: n

func nimTypeOf(c: Ctx, t: SigType, inReturn = false): string
func collectionElement(c: Ctx, t: SigType): SigType
func elementSpelling(c: Ctx, e: SigType): string

func abiSpelling(c: Ctx, t: SigType): string =
  ## A type as it crosses the ABI: objects are pointers, strings are HSTRINGs,
  ## and everything else is itself.
  case t.kind
  of skInterface, skObject: "pointer"
  of skString: "HSTRING"
  else: c.nimTypeOf(t)

func fromAbi(c: Ctx, t: SigType, name: string): string =
  ## The expression turning an ABI argument called `name` into what a caller's
  ## closure expects. Objects are *borrowed*: the runtime owns the argument for
  ## the duration of the call.
  case t.kind
  of skInterface:
    let cls = if t.name in c.classes: c.apiName(t.name)
              elif t.name in c.classOfIface: c.apiName(c.classOfIface[t.name])
              else: "WinRtObject"
    &"borrow[{cls}]({name})"
  of skObject: &"borrow[WinRtObject]({name})"
  of skString: "$" & name
  else: name

func delegateSpelling(c: Ctx, args: seq[SigType],
                      names: openArray[string] = []): string =
  ## A delegate with these `Invoke` arguments, as the Nim closure a caller
  ## would write — or "" if one of them has no spelling.
  ##
  ## Three at most, which is what `delegate.nim` has trampolines for; no
  ## delegate in the metadata takes more. `names` are for the parameters
  ## where the metadata's convention supplies them — an event's `sender` and
  ## `args`.
  if args.len > 3: return ""
  var parts, types: seq[string]
  for i, a in args:
    if a.byRef: return ""
    let n = c.nimTypeOf(a)
    if n.len == 0: return ""
    let name = if i < names.len: names[i] else: &"a{i}"
    parts.add &"{name}: {n}"
    types.add n
  # An event's shape has a name of its own in `core`.
  if names.len == 2 and args.len == 2: &"EventHandler[{types[0]}, {types[1]}]"
  else: "proc(" & parts.join(", ") & ")"

func delegateArgs(c: Ctx, t: SigType): tuple[found: bool, args: seq[SigType]] =
  ## The `Invoke` arguments of a delegate-typed parameter, named or
  ## parameterised. `TypedEventHandler<S, A>.Invoke(S, A)`, and
  ## `EventHandler<A>.Invoke(Object, A)`.
  if t.kind == skInterface and t.name in c.delegates:
    (true, c.delegates[t.name])
  elif t.kind == skUnsupported and
       t.name == "Windows.Foundation.TypedEventHandler`2" and t.args.len == 2:
    (true, t.args)
  elif t.kind == skUnsupported and
       t.name == "Windows.Foundation.EventHandler`1" and t.args.len == 1:
    (true, @[SigType(kind: skObject), t.args[0]])
  else:
    (false, @[])

func asyncResult(c: Ctx, t: SigType): tuple[isAsync: bool, res: SigType] =
  ## Whether `t` is an async operation, and what it eventually produces.
  ##
  ## An action produces nothing; an operation's first type argument is the
  ## result, and a `WithProgress` variant's second is progress reporting this
  ## does not surface.
  if t.kind == skInterface and t.name in AsyncActions:
    (true, SigType(kind: skVoid))
  elif t.kind == skUnsupported and t.name in AsyncActions:
    (true, SigType(kind: skVoid))
  elif t.kind == skUnsupported and t.name in AsyncOps and t.args.len >= 1:
    (true, t.args[0])
  else:
    (false, SigType(kind: skVoid))

const ReferenceIface = "Windows.Foundation.IReference`1"

func boxSlot(v: SigType): int =
  ## Which `PropertyValue.CreateX` boxes this, or -1 if none does.
  ##
  ## Read off `IPropertyValueStatics`, whose slots run in the order the
  ## interface declares them. There is no `CreateEnum` and no way to box an
  ## arbitrary struct, so those stay unboxable.
  case v.kind
  of skU1: 7
  of skI2: 8
  of skU2: 9
  of skI4: 10
  of skU4: 11
  of skI8: 12
  of skU8: 13
  of skF4: 14
  of skF8: 15
  of skChar: 16
  of skBool: 17
  of skString: 18
  of skStruct:
    case v.name
    of "System.Guid": 20
    of "Windows.Foundation.DateTime": 21
    of "Windows.Foundation.TimeSpan": 22
    of "Windows.Foundation.Point": 23
    of "Windows.Foundation.Size": 24
    of "Windows.Foundation.Rect": 25
    else: -1
  else: -1

func selfBoxed(v: SigType): bool =
  ## Whether a value has to go into an `IReference<T>` this library implements
  ## itself, because `PropertyValue` has no `CreateX` for it. Enums and the
  ## structs the runtime has never heard of — `Windows.UI.Color` above all.
  boxSlot(v) < 0 and v.kind in {skEnum, skStruct}

func referenceValue(c: Ctx, t: SigType): SigType =
  ## The type inside an `IReference<T>`, if `t` is one.
  if t.kind == skUnsupported and t.args.len == 1 and t.name == ReferenceIface:
    t.args[0]
  else:
    SigType(kind: skVoid)

const CollectionIfaces = [
  "Windows.Foundation.Collections.IVectorView`1",
  "Windows.Foundation.Collections.IVector`1",
  "Windows.Foundation.Collections.IIterable`1",
  "Windows.Foundation.Collections.IObservableVector`1",
]

const PassableIfaces = [
  "Windows.Foundation.Collections.IIterable`1",
  "Windows.Foundation.Collections.IVectorView`1",
  "Windows.Foundation.Collections.IVector`1",
]

const
  IterableIface = "Windows.Foundation.Collections.IIterable`1"
  VectorIface = "Windows.Foundation.Collections.IVector`1"
  PairIface = "Windows.Foundation.Collections.IKeyValuePair`2"

const MapIfaces = [
  "Windows.Foundation.Collections.IMapView`2",
  "Windows.Foundation.Collections.IMap`2",
  "Windows.Foundation.Collections.IObservableMap`2",
]

func readableAs(t: SigType): SigType =
  ## The interface a collection is actually read through.
  ##
  ## `IObservableVector<T>` declares only its change event; the reading is
  ## `IVector<T>`, which it requires. Same for `IObservableMap<K,V>` and
  ## `IMap<K,V>`. Narrowing to the observable one and calling slot 6 would
  ## reach `add_VectorChanged`.
  result = t
  if t.name == "Windows.Foundation.Collections.IObservableVector`1":
    result.name = "Windows.Foundation.Collections.IVector`1"
  elif t.name == "Windows.Foundation.Collections.IObservableMap`2":
    result.name = "Windows.Foundation.Collections.IMap`2"

func mapKeySpelling(c: Ctx, k: SigType): string =
  ## A map key as Nim spells it, or "" if it cannot be one.
  ##
  ## A `Table` needs a key it can hash and compare: strings, the value types
  ## — every generated struct carries a `hash`, and `GUID` has one in `core` —
  ## and objects, by identity, which is what the runtime means too.
  case k.kind
  of skString: "string"
  of skChar, skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4,
     skF8, skEnum, skStruct, skInterface, skObject:
    c.nimTypeOf(k)
  else: ""

func mapValue(c: Ctx, t: SigType): SigType =
  ## The value type, if `t` is a WinRT map Nim can spell as a `Table`.
  if t.kind == skUnsupported and t.args.len == 2 and t.name in MapIfaces and
     c.mapKeySpelling(t.args[0]).len > 0:
    t.args[1]
  else:
    SigType(kind: skVoid)

func mapValueSpelling(c: Ctx, v: SigType): string =
  case v.kind
  of skString: "string"
  of skObject: "WinRtObject"
  of skUnsupported:
    # `FileSavePicker.FileTypeChoices` is an `IMap<String, IVector<String>>`.
    let inner = c.collectionElement(v)
    if inner.kind == skVoid or inner.kind == skUnsupported: ""
    else:
      let es = c.elementSpelling(inner)
      if es.len > 0: "seq[" & es & "]" else: ""
  of skInterface:
    if v.name in c.classes: c.apiName(v.name)
    elif v.name in c.classOfIface: c.apiName(c.classOfIface[v.name])
    elif v.name in c.ifaceIid: "WinRtObject"
    else: ""
  of skChar, skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4,
     skF8, skEnum, skStruct:
    c.nimTypeOf(v)
  else: ""

func passableCollection(c: Ctx, t: SigType): SigType =
  ## The element type, if `t` is a collection a Nim seq can be passed as.
  ##
  ## `IVector<T>` is the mutable one, and `seqview` offers it over objects and
  ## strings only: `Append(T)` takes its element by value, so a vector of
  ## structs would need a different `Invoke` shape per struct.
  if t.kind == skUnsupported and t.args.len == 1 and t.name in PassableIfaces:
    if t.name == VectorIface and
       t.args[0].kind notin {skString, skInterface, skObject}:
      SigType(kind: skVoid)
    else:
      t.args[0]
  else:
    SigType(kind: skVoid)

func passableMap(c: Ctx, t: SigType): tuple[found: bool, key, val: SigType] =
  ## The key and value types, if `t` is a map a Nim `Table` can be passed as:
  ## `IMap<K, V>`, `IMapView<K, V>` or `IIterable<IKeyValuePair<K, V>>`.
  ##
  ## Keys are strings, GUIDs or enums and values are strings or objects — the
  ## shapes `mapview` has a vtable for; see there for why.
  var args: seq[SigType]
  if t.kind != skUnsupported: return
  if t.name in MapIfaces and t.args.len == 2:
    args = t.args
  elif t.name == IterableIface and t.args.len == 1 and
       t.args[0].kind == skUnsupported and t.args[0].name == PairIface and
       t.args[0].args.len == 2:
    args = t.args[0].args
  else:
    return
  let keyOk = args[0].kind == skString or args[0].kind == skEnum or
              (args[0].kind == skStruct and args[0].name == "System.Guid")
  let valOk = args[1].kind in {skString, skInterface, skObject} and
              c.mapValueSpelling(args[1]).len > 0
  if keyOk and valOk: (true, args[0], args[1])
  else: (false, SigType(kind: skVoid), SigType(kind: skVoid))

func passableMapCollection(c: Ctx, t: SigType):
    tuple[found: bool, key, val: SigType] =
  ## The key and value types, if `t` is a passable collection whose elements
  ## are passable maps — `IIterable<IIterable<IKeyValuePair<K, V>>>`, which
  ## is how a printer's collection-of-collections attribute arrives.
  if t.kind == skUnsupported and t.args.len == 1 and
     t.name in [IterableIface, "Windows.Foundation.Collections.IVectorView`1"]:
    let inner = c.passableMap(t.args[0])
    if inner.found: return inner
  (false, SigType(kind: skVoid), SigType(kind: skVoid))

func collectionElement(c: Ctx, t: SigType): SigType =
  ## The element type, if `t` is a read-only-walkable WinRT collection.
  ##
  ## `IVector` and `IVectorView` number `GetAt` and `get_Size` identically, and
  ## `IIterable` is what both narrow from, so one shape covers all three as far
  ## as reading goes. Writing to a vector is a different matter and is not
  ## claimed here.
  if t.kind == skUnsupported and t.args.len == 1 and t.name in CollectionIfaces:
    t.args[0]
  else:
    SigType(kind: skVoid)

func elementSpelling(c: Ctx, e: SigType): string =
  ## How an element arrives: a class, a string, a value, a collection of one
  ## of those, or nothing.
  case e.kind
  of skString: "string"
  of skObject: "WinRtObject"
  of skUnsupported:
    let mv = c.mapValue(e)
    if mv.kind != skVoid:
      # `IVectorView<IMapView<String, Object>>`: a seq of Tables.
      let vs = c.mapValueSpelling(mv)
      return if vs.len > 0: &"Table[{c.mapKeySpelling(e.args[0])}, {vs}]" else: ""
    let inner = c.collectionElement(e)
    if inner.kind == skVoid or inner.kind == skUnsupported: ""
    else:
      let es = c.elementSpelling(inner)
      if es.len > 0: "seq[" & es & "]" else: ""
  of skInterface:
    # A bare interface has no wrapper of its own, but it is still an object,
    # and handing back a `pointer` in a `seq` would be a reference nobody
    # released.
    if e.name in c.classes: c.apiName(e.name)
    elif e.name in c.classOfIface: c.apiName(c.classOfIface[e.name])
    elif e.name in c.ifaceIid: "WinRtObject"
    else: ""
  of skChar, skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4,
     skF8, skEnum, skStruct:
    c.nimTypeOf(e)
  else: ""

func elementIsValue(e: SigType): bool =
  ## Whether an element comes back by value rather than as a pointer.
  e.kind in {skChar, skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8,
             skF4, skF8, skEnum, skStruct}

func asyncSpelling(c: Ctx, res: SigType): string =
  ## What an async operation's result becomes in Nim. "void" is a real answer
  ## here — an action completes without producing anything — and "" means the
  ## result is a shape this cannot carry.
  ## Only the shapes `core` can fetch a result for: nothing, a string, or an
  ## object. A primitive result needs its own `GetResults` signature per width
  ## and a nested collection needs the walk as well, so both stay skipped and
  ## counted rather than half-supported.
  if res.kind == skVoid: return "void"
  # A collection, a map or a reference result is read after the wait, so it
  # reads as it would from any getter.
  let e = c.collectionElement(res)
  if e.kind != skVoid:
    let es = c.elementSpelling(e)
    return if es.len > 0: "seq[" & es & "]" else: ""
  let mv = c.mapValue(res)
  if mv.kind != skVoid:
    let vs = c.mapValueSpelling(mv)
    return if vs.len > 0: &"Table[{c.mapKeySpelling(res.args[0])}, {vs}]" else: ""
  let rv = c.referenceValue(res)
  if rv.kind != skVoid:
    let v = c.nimTypeOf(rv)
    return if v.len > 0: "Option[" & v & "]" else: ""
  case res.kind
  of skString: "string"
  of skObject: "WinRtObject"
  of skInterface:
    if res.name in c.classes: c.apiName(res.name)
    elif res.name in c.classOfIface: c.apiName(c.classOfIface[res.name])
    elif res.name in c.ifaceIid: "WinRtObject"
    else: ""
  of skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4, skF8:
    c.nimTypeOf(res)
  of skEnum:
    if res.name in c.enums: c.abiName(res.name) else: ""
  of skStruct:
    if res.name in c.aliases or res.name in c.structs or
       res.name in foreignEnums: c.nimTypeOf(res)
    else: ""
  else: ""

func trailing(s: string): seq[string] =
  ## The arguments `innerIidArg` returns, as items — it spells them as a
  ## trailing ", a, b" for the sites that splice them into a literal.
  if s.len == 0: @[] else: s[2 .. ^1].split(", ")

proc innerIidArg(c: Ctx, sigCtx: SigContext, elem: SigType,
                 mint: proc(iid: string, t: SigType): string): string =
  ## The trailing arguments naming what a nested element is read through —
  ## `, IID_IVector_1_String` for a collection, the iterable-of-pairs and the
  ## pair for a map — or nothing when `elem` is neither. `mint` is the
  ## module's constant-minting proc.
  if elem.kind != skUnsupported: return ""
  if c.mapValue(elem).kind != skVoid:
    let pairT = SigType(kind: skUnsupported, args: elem.args, name: PairIface)
    let iterT = SigType(kind: skUnsupported, args: @[pairT], name: IterableIface)
    let pc = sigCtx.parameterizedIid(pairT)
    let ic = sigCtx.parameterizedIid(iterT)
    if pc.len == 0 or ic.len == 0: return ""
    return ", " & mint(ic, iterT) & ", " & mint(pc, pairT)
  if c.collectionElement(elem).kind == skVoid: return ""
  let computed = sigCtx.parameterizedIid(readableAs(elem))
  if computed.len == 0: return ""
  ", " & mint(computed, readableAs(elem))

func skipReason(c: Ctx, t: SigType, inReturn = false): string =
  ## Why this type has no wrapper spelling. "" means it has one.
  ##
  ## `inReturn` matters for collections: reading one into a `seq` is
  ## straightforward, and building a WinRT collection out of a Nim `seq` to
  ## pass *in* is not, so they are carried one way only.
  if t.byRef:
    # WinRT gives a method one declared return and any number of `[out]`
    # parameters beside it. Nim spells that as a tuple, so an out-parameter is
    # fine as long as its own type is.
    var bare = t
    bare.byRef = false
    return if c.skipReason(bare, inReturn = true).len == 0: ""
           else: "a second out-parameter"
  case t.kind
  of skUnsupported:
    let (isDelegate, dargs) = c.delegateArgs(t)
    if isDelegate and not inReturn:
      return if c.delegateSpelling(dargs).len > 0: ""
             else: "a delegate with an argument that has no spelling"
    let a = c.asyncResult(t)
    let r = c.referenceValue(t)
    let e = c.collectionElement(t)
    let passable = c.passableCollection(t)
    if inReturn and a.isAsync and c.asyncSpelling(a.res).len > 0: ""
    elif inReturn and r.kind != skVoid and c.skipReason(r).len == 0: ""
    elif inReturn and e.kind != skVoid and c.elementSpelling(e).len > 0: ""
    elif inReturn and c.mapValueSpelling(c.mapValue(t)).len > 0: ""
    elif not inReturn and r.kind != skVoid and
         (boxSlot(r) >= 0 or selfBoxed(r)) and c.skipReason(r).len == 0: ""
    elif not inReturn and c.passableMap(t).found: ""
    elif not inReturn and c.passableMapCollection(t).found: ""
    elif not inReturn and passable.kind != skVoid and
         c.elementSpelling(passable).len > 0: ""
    elif t.name.len > 0 and t.args.len > 0: "generic: " & shortName(t.name)
    else: "a type variable or function pointer"
  of skArray:
    if t.args.len == 1 and c.elementSpelling(t.args[0]).len > 0: ""
    else: "an array"
  of skEnum:
    if t.name in c.enums: "" else: "an enum from another winmd"
  of skInterface:
    if inReturn and c.asyncResult(t).isAsync: ""
    elif t.name in c.delegates:
      if inReturn: ""
      elif c.delegateSpelling(c.delegates[t.name]).len > 0: ""
      else: "a delegate with an argument that has no spelling"
    elif t.name in c.classes or t.name in c.ifaceIid: ""
    else: "an interface from another winmd"
  of skStruct:
    if t.name in foreignEnums or t.name in c.aliases or t.name in c.structs: ""
    else: "a struct with no layout"
  else: ""

func nimTypeOf(c: Ctx, t: SigType, inReturn = false): string =
  ## The Nim spelling for a wrapper parameter or result, or "" if unsupported.
  ##
  ## A generic instantiation is mapped only where there is an honest Nim
  ## spelling for it. A readable collection becomes a `seq`; everything else —
  ## `IReference<T>`, the async operations, the maps — is left unmapped rather
  ## than spelled `pointer`, which would read as a typed API while giving none
  ## of the safety.
  if t.byRef:
    var bare = t
    bare.byRef = false
    return c.nimTypeOf(bare, inReturn = true)
  if inReturn:
    let a = c.asyncResult(t)
    if a.isAsync:
      let sp = c.asyncSpelling(a.res)
      return if sp == "void": "" else: sp
  if not inReturn:
    let (isDelegate, dargs) = c.delegateArgs(t)
    if isDelegate and t.kind == skUnsupported:
      return c.delegateSpelling(dargs)
  # `IReference<T>` in either direction: read out of the box, or put into one.
  let refv = c.referenceValue(t)
  if refv.kind != skVoid and not inReturn:
    if boxSlot(refv) < 0 and not selfBoxed(refv): return ""
    let v = c.nimTypeOf(refv)
    return if v.len > 0: "Option[" & v & "]" else: ""
  if not inReturn:
    let pm = c.passableMap(t)
    if pm.found:
      return &"Table[{c.mapKeySpelling(pm.key)}, {c.mapValueSpelling(pm.val)}]"
    let pmc = c.passableMapCollection(t)
    if pmc.found:
      return &"seq[Table[{c.mapKeySpelling(pmc.key)}, {c.mapValueSpelling(pmc.val)}]]"
  if inReturn:
    let mv = c.mapValue(t)
    if mv.kind != skVoid:
      let ks = c.mapKeySpelling(t.args[0])
      let vs = c.mapValueSpelling(mv)
      return if vs.len > 0: &"Table[{ks}, {vs}]" else: ""
    # `IReference<T>` is WinRT's nullable, and Nim already has that word.
    let r = c.referenceValue(t)
    if r.kind != skVoid:
      let v = c.nimTypeOf(r)
      return if v.len > 0: "Option[" & v & "]" else: ""
  let elem = c.collectionElement(t)
  if elem.kind != skVoid:
    let e = c.elementSpelling(elem)
    if e.len == 0: return ""
    # Readable in either direction, writable only out of a read-only shape.
    if inReturn or c.passableCollection(t).kind != skVoid:
      return "seq[" & e & "]"
    return ""
  case t.kind
  of skBool: "bool"
  of skChar: "uint16"
  of skI1: "int8"
  of skU1: "uint8"
  of skI2: "int16"
  of skU2: "uint16"
  of skI4: "int32"
  of skU4: "uint32"
  of skI8: "int64"
  of skU8: "uint64"
  of skF4: "float32"
  of skF8: "float64"
  of skString: "string"
  of skObject:
    # `IInspectable` — the base every runtime class shares, and the element
    # type of every untyped collection and property bag. Spelling it `pointer`
    # made a getter leak: the reference it hands over is the caller's to
    # release, and nothing in a bare pointer says so. `WinRtObject` is that
    # pointer with the destructor attached.
    "WinRtObject"
  of skEnum:
    if t.name in c.enums: c.abiName(t.name) else: ""
  of skInterface:
    # The resolved name is a runtime class for most parameters and a bare
    # interface for the rest. A class becomes its wrapper type; an interface
    # stays a pointer, because there is no wrapper to give it.
    if t.name in c.delegates:
      # A delegate is a closure on the way in and an object on the way out:
      # one the runtime hands back is a COM object with an `invoke`, and the
      # wrapper type for it is emitted like any class's.
      if inReturn: c.apiName(t.name) else: c.delegateSpelling(c.delegates[t.name])
    elif t.name in c.classes: c.apiName(t.name)
    elif t.name in c.classOfIface: c.apiName(c.classOfIface[t.name])
    elif t.name in c.ifaceIid:
      # An interface with no class of its own — `IStorageItem`, `IUICommand`
      # — or one that several classes share as their default. Still an
      # object, so still counted; a caller narrows it with `queryInterface`
      # or passes it on, and any class passes where it is expected because
      # every class derives from `WinRtObject`.
      "WinRtObject"
    else: ""
  of skStruct:
    # Structs cross by value and the ABI module has already laid out the ones it
    # could, so a wrapper can name them directly — this is what makes `Margin`,
    # `Padding` and `Color` reachable at all.
    if t.name in foreignEnums: "int32"
    elif t.name in c.aliases: c.aliases[t.name]
    elif t.name in c.structs: c.abiName(t.name)
    else: ""
  of skArray:
    # A count and a pointer, which for values is what an `openArray` already
    # is — they are pointed at where they lie. Strings and objects are
    # marshalled into a buffer of their own, so they arrive as an `openArray`
    # too and go back as a `seq`.
    if t.args.len != 1: ""
    else:
      let e = c.elementSpelling(t.args[0])
      if e.len == 0: ""
      elif inReturn: "seq[" & e & "]"
      else: "openArray[" & e & "]"
  else: ""

type Emission = tuple
  classes, procs, ctors, events, skipped: int

type Part = enum
  ## Which half of the API layer a call writes.
  ##
  ## Classes are mutually recursive across every namespace there is: a
  ## `StorageFile` method returns a `IRandomAccessStream`, a `Geopoint` is a
  ## parameter in `Windows.Services.Maps`, and `Windows.UI` and
  ## `Windows.Graphics` name each other throughout. Nim has no mutually
  ## recursive modules, so no arrangement of eighteen self-contained ones can
  ## express that, and the previous one paid for it by skipping any method
  ## that mentioned a type from a group it did not import — 1,188 of them.
  ##
  ## A wrapper type is one pointer and costs nothing to declare, so all 4,482
  ## go in one module and the groups carry only their own members. Every
  ## signature can then name every type, which is what a projection has to be
  ## able to do.
  pEverything    ## one self-contained module (the single-prefix mode)
  pClasses       ## the wrapper types, their lifetimes, for every namespace
  pMembers       ## the members of one group's classes

proc emitModule(md: WinMd; iids: Table[int, string];
                winmdPath, ownPrefix, outPath, corePath, abiPath: string;
                part = pEverything): Emission =
  ## Write the API layer, over the ABI module at `abiPath`.
  ##
  ## `ownPrefix` is what this module *writes*. What it may *name* is wider:
  ## everything, unless this is the single-prefix mode, where there is nothing
  ## else to name.
  let prefix = if part == pEverything: ownPrefix else: "Windows"
  let classesPath = corePath.rsplit('/', 1)[0] & "/classes"
  let delegatePath = corePath.rsplit('/', 1)[0] & "/delegate"
  let impls = md.interfaceImpls()
  let attrs = md.attributeNames()

  var byName = initTable[string, int]()
  for t in md.types: byName[t.fullName] = t.index

  var c = Ctx()
  # Which ABI module declares each interface's IID, slots and signatures, and
  # which of those this module turns out to need. Importing all nineteen is
  # correct and costs half a minute of compile time per module; importing the
  # three or four a group actually calls into costs nothing and is the same
  # code. The set is only known once the members have been walked, so the
  # imports are spliced in at a marker like the others.
  var ifaceGroup = initTable[string, string]()
  var usedAbi: HashSet[string]
  proc useIface(full: string) =
    let g = ifaceGroup.getOrDefault(full, "")
    if g.len > 0: usedAbi.incl moduleName(g)
  # Both layers reduce a full name to its last segment, and two namespaces in
  # one group can end in the same one — `Windows.UI.Composition` and
  # `Windows.UI.Xaml.Media` both declare `CompositionTarget`. Whichever comes
  # first in the metadata wins, and this has to make the same choice
  # `generate.nim` did: name the loser and the emitted code refers to a slot
  # that was never written.
  var takenIface, takenEnum: HashSet[string]
  # Before the walk: the alias table decides which enums the ABI declined to
  # write, and the walk has to agree with it.
  for (name, nim) in foreignAliases:
    c.aliases[name] = nim
  for t in md.types:
    # Interfaces, and delegates: a delegate has an IID, a vtable and one method
    # of its own, and the wrapper type it gets below reaches `Invoke` through
    # exactly the machinery an interface's methods use.
    if t.index in iids and
       ((t.flags and tdInterface) != 0 or md.isDelegate(t.index)):
      c.ifaceIid.incl t.fullName
      ifaceGroup[t.fullName] = topGroup(t.namespace)
      # `IID_X` and `Slot_X_Y` come from the ABI, which a split module imports
      # whole: a class here may well implement an interface from elsewhere —
      # a `Windows.Networking` class implementing `IBackgroundTask` — and the
      # constants for it are in scope either way.
      if t.namespace.startsWith(prefix):
        # The rule the ABI applies to a second interface with a taken short
        # name, so `IID_XamlIFrameworkView` here is `IID_XamlIFrameworkView`
        # there.
        var k = sanitize(t.name)
        if nimIdent(k) in takenIface:
          k = sanitize(t.namespace.split('.')[^1]) & k
          if nimIdent(k) in takenIface: continue
          c.renamed[t.fullName] = k
        takenIface.incl nimIdent(k)
        c.localIface.incl t.fullName
    # Every enum is nameable: `abi/types` declares the lot, so the signature
    # this layer calls through and the wrapper over it always agree — as long
    # as this arrives at the same name, which means applying the same rule for
    # a short name that is already taken.
    if t.namespace.startsWith(prefix) and md.isEnum(t.index) and
       t.fullName notin c.aliases and md.enumMembers(t.index).len > 0:
      # Exactly the filters and the order `generate.nim` uses, because this is
      # the same decision made twice and a divergence names a type that is not
      # there.
      var k = sanitize(t.name)
      if k in takenEnum:
        k = sanitize(t.namespace.split('.')[^1]) & k
        if k in takenEnum: continue
        c.renamed[t.fullName] = k
      takenEnum.incl k
      c.enums.incl t.fullName
  # Mirror what `generate.nim` emitted: the foreign table, plus in-namespace
  # value types. A struct it could not lay out is absent from the ABI module, so a
  # wrapper naming it would not compile.
  for (name, _) in foreignStructs:
    c.structs.incl name
  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue
    let (ff, fs) = md.fieldRange(t.index)
    if fs > ff: c.structs.incl t.fullName

  # Delegates, so an event can declare the closure it actually wants. A WinRT
  # delegate's shape lives in its own `Invoke`, not in the `add_*` that takes
  # it, so this has to be looked up separately.
  var delegates = initTable[string, seq[SigType]]()
  for t in md.types:
    if not md.isDelegate(t.index): continue
    if t.index notin iids: continue
    ifaceGroup[t.fullName] = topGroup(t.namespace)
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      if md.str(md.cell(tMethodDef, mi, "Name")) != "Invoke": continue
      delegates[t.fullName] = md.methodSignature(mi).params
      c.delegates[t.fullName] = delegates[t.fullName]
      break

  # Everything needed to compute a parameterised interface's IID. A generic
  # like `TypedEventHandler<Sender, Args>` has no GUID anywhere — WinRT derives
  # one by hashing a signature string — so without this, 235 events cannot be
  # generated at all.
  var sigCtx = SigContext(md: md, guidOf: iids)
  for t in md.types:
    sigCtx.indexOf[t.fullName] = t.index

  # Runtime classes: not interfaces, enums, delegates or plain structs.
  let staticIfaces = md.attributeTypeArgs("StaticAttribute")
  let activatableFactories = md.attributeTypeArgs("ActivatableAttribute")
  var staticOnly: HashSet[string]
  # Classes whose default interface is a parameterised one: `TransitionCollection`
  # is an `IVector<Transition>` and nothing else, so there is no declared IID to
  # find and the class used to be dropped — along with the 77 methods that pass
  # one. The IID is computed, but not here: that needs every class's default
  # interface to be known already, and this loop is what works them out.
  var paramDefault = initTable[string, SigType]()
  var shared: HashSet[string]   ## default interfaces claimed by two classes
  var classOrder: seq[TypeRow]
  var takenNames: HashSet[string]
  var usesAsync = false
  var usesSeqView = false
  var usesMapView = false
  var usesReference = false
  for t in md.types:
    # Every class is walked, so this module can *name* any of them in a
    # signature. Only its own are written here.
    let mine = t.namespace.startsWith(ownPrefix)
    if not t.namespace.startsWith(prefix): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index): continue
    # A delegate is a class too, for the way *out*: a method that returns one
    # hands back a COM object, and the wrapper for it is an object with an
    # `invoke`. It is its own only interface, so the loop below emits that
    # method through the same path as any other. The open generics —
    # `TypedEventHandler`2` itself, not an instantiation — are not: nothing
    # is ever one of those.
    if md.isDelegate(t.index) and '`' in t.name: continue
    let own = if md.isDelegate(t.index):
                # Its own TypeDef row, as the coded TypeDefOrRef the table
                # would hold: tag 0 in the low two bits.
                (if t.index in iids: @[t.index shl 2] else: @[])
              else: impls.getOrDefault(t.index, @[])
    # No base and no interfaces means no instance — which is either a plain
    # struct, or a static class whose whole API hangs off its factory.
    if md.baseName(t.index) == "" and own.len == 0 and
       t.index notin staticIfaces: continue
    # WinRT lists a class's default interface first.
    var default = ""
    for coded in own:
      let n = md.typeDefOrRefName(coded)
      if n in c.localIface:
        default = n
        break
    if default.len == 0:
      for coded in own:
        let sg = md.typeDefOrRefSig(coded)
        if sg.kind == skUnsupported and sg.args.len > 0:
          paramDefault[t.fullName] = sg
          sigCtx.paramDefault[t.fullName] = sg
          break
    if default.len == 0 and t.fullName notin paramDefault and
       md.baseName(t.index) == "" and not md.isDelegate(t.index):
      # No instance to have. If the metadata gives it a static interface it is
      # a class like `PowerManager` — real API, reached through the activation
      # factory — so it is kept, as a name to hang those members on.
      if t.index notin staticIfaces: continue
      staticOnly.incl t.fullName
    # Seven classes in the metadata share a short name with another —
    # `Windows.ApplicationModel.SuspendingEventArgs` and
    # `Windows.UI.WebUI.SuspendingEventArgs` both want `SuspendingEventArgs`.
    # The second is written under its namespace's last segment,
    # `WebUISuspendingEventArgs`, the same rule the ABI applies to an enum.
    var ident = shortName(t.fullName)
    if nimIdent(ident) in takenNames:
      ident = sanitize(t.namespace.split('.')[^1]) & ident
      if nimIdent(ident) in takenNames: continue
      c.renamed[t.fullName] = ident
    takenNames.incl nimIdent(ident)
    c.classes.incl t.fullName
    if default.len > 0:
      c.defaultIface[t.fullName] = default
      sigCtx.defaultIface[t.fullName] = default
      # A factory returns the class's default interface rather than the class,
      # so this is what lets `CreateUri` be typed as returning a `Uri`. Only
      # where the answer is unique: `IUICommand` is the default of both
      # `UICommand` and `UICommandSeparator`, and adopting one as the other
      # would put the wrong type name on a live object.
      if default in c.classOfIface: shared.incl default
      else: c.classOfIface[default] = t.fullName
    if mine: classOrder.add t
  for iface in shared: c.classOfIface.del iface

  if part == pMembers:
    var valueNames: HashSet[string]
    for n in c.enums: valueNames.incl shortName(n)
    for n in c.structs: valueNames.incl shortName(n)
    for n in c.classes:
      if shortName(n) in valueNames: c.collide.incl shortName(n)

  proc asClass(name: string): string =
    ## The class a type name stands for: itself if it is one, or the class it
    ## is the default interface of. A factory hands back `IUriRuntimeClass`,
    ## and what the caller wants is a `Uri`.
    if name in c.classes: name
    else: c.classOfIface.getOrDefault(name, "")

  proc ancestorsOf(full: string): seq[string] =
    var cur = md.baseName(byName[full])
    var guard = 0
    while cur.len > 0 and cur in c.classes and guard < 16:
      result.add cur
      cur = md.baseName(byName[cur])
      guard.inc

  var buf = newStringOfCap(8 shl 20)
  buf.add "## Generated by tools/wrappers.nim - do not edit.\n##\n"
  buf.add &"## Source:    {winmdPath.extractFilename}\n"
  if part == pClasses:
    buf.add "## Every runtime class in the metadata.\n##\n"
  else:
    buf.add &"## Namespace: {ownPrefix}\n##\n"
  buf.add "## Each class is a Nim object in a real inheritance chain, so an\n"
  buf.add "## inherited method resolves without being emitted again for every\n"
  buf.add "## subclass, and a derived value passes where a base is expected.\n\n"
  # Which ABI groups and which runtime modules this one needs is only known
  # once its members have been walked, so the import block is spliced in at
  # the end: a module with no async method does not drag `std/asyncdispatch`
  # into programs that never await.
  buf.add ImportsMarker
  # `withIface`, `withStatics`, `takeString`, `activateAs`, `composeAs`,
  # `adopt` and `borrow` are not emitted here. They are the same in every
  # module, so eighteen copies collided the moment a program imported two of
  # them; they live in `core` and arrive through the import above.

  buf.add GenericIidMarker
  if part != pMembers: buf.add "type\n"
  var byDepth: seq[(int, TypeRow)]

  proc argumentNames(mi: int, count: int, isPut: bool): seq[string] =
    ## What to call each parameter.
    ##
    ## The metadata names them — `lampIndex`, `desiredColor` — and using those
    ## is the difference between a signature you can read and one you have to
    ## look up. A property setter is always `value`, whatever the metadata says,
    ## because that is the name Nim's `x=` convention gives it.
    ##
    ## Falls back to `aN` for a parameter with no Param row, and disambiguates
    ## anything that would collide with the receiver, a temporary, or itself.
    if isPut: return @["value"]
    let named = md.paramNames(mi)
    var taken = ["self", "it", "result", "op", "tmp", "coll"].toHashSet
    for i in 0 ..< count:
      var n = ""
      if (i + 1) in named:
        n = lowerFirst(sanitize(named[i + 1]))
      if n.len == 0 or n in taken or n.startsWith("p") and n.len <= 2:
        n = &"a{i + 1}"
      while n in taken:
        n = n & $(i + 1)
      taken.incl n
      result.add escapeIdent(n)

  for t in classOrder:
    byDepth.add (ancestorsOf(t.fullName).len, t)
  byDepth.sort(proc (a, b: (int, TypeRow)): int = cmp(a[0], b[0]))
  for (_, t) in byDepth:
    if part == pMembers: break
    let n = c.apiName(t.fullName)
    let base = md.baseName(t.index)
    if t.fullName in staticOnly:
      # Never constructed, never held: it exists so that `PowerManager.x`
      # resolves. No pointer, so no reference counting either.
      buf.add &"  {n}* = object\n"
    elif base.len > 0 and base in c.classes:
      buf.add &"  {n}* = object of {c.apiName(base)}\n"
    else:
      buf.add &"  {n}* = object of WinRtObject\n"
  buf.add "\n"

  # Reference counting is `WinRtObject`'s, in `core`, and every class above
  # derives from it: one `=destroy`, `=copy`, `=sink` and `isNil` for the
  # whole projection rather than a set per inheritance root.

  # Computed IIDs, emitted as constants at the end and referred to by name.
  # Keyed by the IID itself so two spellings of the same instantiation share
  # one constant.
  var genericIids: Table[string, string]
  var genericIidOrder: seq[(string, string)]
  var usedIidNames: HashSet[string]

  proc genericIidConst(iid: string, t: SigType): string =
    ## The name of a constant holding `iid`, minting one if needed.
    if iid in genericIids: return genericIids[iid]
    var base = "IID_" & shortName(t.name)
    for a in t.args:
      base.add "_"
      base.add (if a.name.len > 0: shortName(a.name)
                elif a.kind == skObject: "Object"
                else: sanitize(($a.kind)[2 .. ^1]))
    # Two instantiations can reduce to the same short spelling — different
    # namespaces, same type name — so the name is disambiguated rather than
    # silently reused for the wrong GUID.
    var name = base
    var n = 2
    while name in usedIidNames:
      name = base & $n
      n.inc
    usedIidNames.incl name
    genericIids[iid] = name
    genericIidOrder.add (name, iid)
    name

  var procs, skipped, ctors, events = 0
  var skipReasons = initCountTable[string]()
  let dumpSkips = existsEnv("WINRT_DUMP_SKIPS")

  proc brief(t: SigType): string =
    result = $t.kind & ":" & t.name
    if t.args.len > 0:
      result.add "<" & t.args.mapIt(brief(it)).join(",") & ">"

  proc noteSkip(sig: MethodSig, where: string) =
    ## Record the first thing about a signature that has no wrapper spelling.
    for p in sig.params:
      let r = c.skipReason(p)
      if r.len > 0:
        skipReasons.inc r
        if dumpSkips: stderr.writeLine r & "	" & where & "	" & brief(p)
        return
    let r = c.skipReason(sig.returns, inReturn = true)
    skipReasons.inc (if r.len > 0: r else: "already emitted, or a duplicate name")
    if dumpSkips and r.len > 0:
      stderr.writeLine r & "	" & where & "	-> " & brief(sig.returns)

  for t in classOrder:
    if part == pClasses: break
    # `cls` is the type; `bare` is the same name where an identifier is being
    # built out of it, since `proc newclasses.Panel` is not one.
    let bare = c.renamed.getOrDefault(t.fullName, shortName(t.fullName))
    let cls = c.apiName(t.fullName)
    var emitted = initHashSet[string]()

    let a = attrs.getOrDefault(t.index, @[])
    # `ActivatableAttribute` comes in two forms and they mean opposite things.
    # With a factory interface as its argument it says "constructed through
    # this", and `RoActivateInstance` on such a class returns E_NOTIMPL — which
    # is what a generated `newUri()` used to do. Without one it says
    # "constructible with no arguments", which is the only case that proc is
    # right for. A class can carry both.
    let factories = activatableFactories.getOrDefault(t.index, @[])
    var plainActivations = 0
    for n in a:
      if n == "ActivatableAttribute": plainActivations.inc
    plainActivations -= factories.len

    if t.fullName notin staticOnly and t.fullName in c.defaultIface:
      useIface(c.defaultIface[t.fullName])
      let iface = c.ifaceName(c.defaultIface[t.fullName])
      if plainActivations > 0:
        buf.add &"proc new{bare}*(): {cls} =\n"
        buf.add &"  ## Activate a `{t.fullName}`.\n"
        buf.add &"  adopt[{cls}](activateAs(\"{t.fullName}\", IID_{iface}))\n\n"
        ctors.inc
      elif "ComposableAttribute" in a and factories.len == 0:
        # A composable class refuses RoActivateInstance and is built through
        # `I<Name>Factory.CreateInstance`. The slot is read rather than assumed
        # to be 6, since a factory may declare other methods first.
        let factoryFull = t.namespace & ".I" & t.name & "Factory"
        if factoryFull in c.localIface and factoryFull in byName:
          let (first, stop) = md.methodRange(byName[factoryFull])
          var slot = -1
          for mi in first ..< stop:
            if md.str(md.cell(tMethodDef, mi, "Name")) == "CreateInstance":
              slot = 6 + (mi - first)
              break
          if slot >= 0:
            useIface(factoryFull)
            let fac = c.ifaceName(factoryFull)
            buf.add &"proc new{bare}*(): {cls} =\n"
            buf.add &"  ## Compose a `{t.fullName}`.\n"
            buf.add &"  adopt[{cls}](composeAs(\"{t.fullName}\", IID_{fac},\n"
            buf.add &"                     IID_{iface}, {slot}))\n\n"
            ctors.inc

    # A class contributes members from two places: the interfaces it
    # implements, whose members need an instance, and the interfaces named by
    # its `StaticAttribute`, whose members do not and are reached through the
    # activation factory. `PowerManager` has only the second kind.
    var faces: seq[(string, bool)]
    if md.isDelegate(t.index):
      faces.add (t.fullName, false)          # `invoke`, and nothing else
    for coded in impls.getOrDefault(t.index, @[]):
      faces.add (md.typeDefOrRefName(coded), false)
    for n in staticIfaces.getOrDefault(t.index, @[]):
      faces.add (n, true)
    for n in factories:
      faces.add (n, true)

    for (ifaceFull, isStatic) in faces:
      if ifaceFull notin c.localIface or ifaceFull notin byName: continue
      useIface(ifaceFull)
      let iface = c.ifaceName(ifaceFull)
      # A static member hangs off the type, so it reads `PowerManager.x` at the
      # call site and takes a `typedesc` here.
      let recv = if isStatic: &"_: typedesc[{cls}]" else: &"self: {cls}"
      let enter =
        if isStatic: fill("  withStatics(", @['"' & t.fullName & '"', iface, "it"], "):")
        else: &"  withIface(self.p, {iface}, it):"
      let (first, stop) = md.methodRange(byName[ifaceFull])
      var seen = initCountTable[string]()
      for mi in first ..< stop:
        let raw = md.str(md.cell(tMethodDef, mi, "Name"))
        if raw == ".ctor": continue           # a delegate's, never callable
        # Keyed exactly as `generate.nim` keys it, on the identifier Nim will
        # see rather than on the metadata's spelling. `ITextRange` declares
        # both `get_Text` and `GetText`, and prefixed with `Slot_` those are one
        # identifier to the compiler — so the ABI suffixed the second, and this
        # has to arrive at the same name or it calls a signature that is not
        # there.
        seen.inc nimIdent(&"Slot_{iface}_{sanitize(raw)}")
        let dup = seen[nimIdent(&"Slot_{iface}_{sanitize(raw)}")]
        let tag = &"{iface}_{sanitize(raw)}" & (if dup > 1: $dup else: "")

        # An event is a pair: `add_X(handler) -> token` and `remove_X(token)`.
        # The handler's shape comes from the delegate's own `Invoke`, so the
        # generated proc can take a properly typed Nim closure.
        if raw.startsWith("add_"):
          let sigE = md.methodSignature(mi)
          let evName = sanitize(raw[4 .. ^1])
          # The handler is a delegate — declared, or a `TypedEventHandler<S, A>`
          # / `EventHandler<A>` whose IID is computed — and its `Invoke` says
          # what the Nim closure takes. Sender and arguments arrive typed: the
          # class each is, or `WinRtObject` where the metadata says `Object`.
          var handlerIid = ""
          var dargs: seq[SigType]
          if sigE.params.len == 1:
            let h = sigE.params[0]
            let (isDelegate, args) = c.delegateArgs(h)
            if isDelegate:
              dargs = args
              if h.kind == skInterface:
                useIface(h.name)
                handlerIid = "IID_" & c.ifaceName(h.name)
              else:
                let computed = sigCtx.parameterizedIid(h)
                if computed.len > 0: handlerIid = genericIidConst(computed, h)
          let closureType = c.delegateSpelling(dargs, ["sender", "args"])
          if handlerIid.len > 0 and closureType.len > 0:
            let key = "on" & evName & "/handler"
            if key notin emitted:
              emitted.incl key
              var formal, actual: seq[string]
              for k, a in dargs:
                formal.add &"a{k}: {c.abiSpelling(a)}"
                actual.add c.fromAbi(a, &"a{k}")
              # The closure the runtime gets is a named local: a lambda with a block
              # body does not sit well in an argument list.
              let shim =
                if dargs.len == 0: ""
                else: &"    proc shim({formal.join(\", \")}) =\n" &
                      fill("      handler(", actual, ")") & "\n"
              buf.add fill(&"proc on{evName}*(", @[recv, &"handler: {closureType}"],
                           "): EventRegistrationToken {.discardable.} =") & "\n"
              buf.add &"  ## {t.fullName}.{raw}\n"
              buf.add &"  ## The token is what `remove{evName}` takes.\n"
              buf.add enter & "\n"
              buf.add shim
              let fn = if dargs.len == 0: "handler" else: "shim"
              buf.add &"    let cb = newDelegate({handlerIid}, {fn}, event = true)\n"
              buf.add "    try:\n"
              buf.add &"      it.call({tag}, cb, result.addr)\n"
              buf.add "    finally:\n"
              buf.add "      release(cb)\n\n"
              events.inc
              continue
          skipped.inc
          skipReasons.inc "an event whose handler has no spelling"
          if dumpSkips:
            stderr.writeLine "an event whose handler has no spelling\t" & cls &
                             "." & raw & "\t" & brief(sigE.params[0])
          continue

        if raw.startsWith("remove_"):
          let sigE = md.methodSignature(mi)
          let evName = sanitize(raw[7 .. ^1])
          if sigE.params.len == 1 and sigE.params[0].kind == skStruct and
             sigE.params[0].name in c.structs:
            let key = "remove" & evName & "/token"
            if key notin emitted:
              emitted.incl key
              buf.add &"proc remove{evName}*({recv}, " &
                      "token: EventRegistrationToken) =\n"
              buf.add enter & "\n"
              buf.add &"    it.call({tag}, token)\n\n"
              events.inc
              continue
          skipped.inc
          skipReasons.inc "an event whose token is not one"
          continue

        let sig = md.methodSignature(mi)
        let isGet = raw.startsWith("get_")
        let isPut = raw.startsWith("put_")

        # Map every part before emitting any of it.
        # WinRT gives a method one declared return and any number of `[out]`
        # parameters beside it. Those are results, not arguments, so they leave
        # the parameter list and join the return as a tuple.
        # `[out]` is recorded in the Param table, not in the signature: WinRT
        # passes an `[in]` struct by reference too, so `GuidHelper.Equals` has
        # two by-reference *inputs*.
        let pflags = md.paramFlags(mi)
        var argTypes, outTypes: seq[string]
        var inputs, outputs: seq[int]
        var ok = true
        for i, p in sig.params:
          let isOut = p.byRef and
                      (pflags.getOrDefault(i + 1, 0) and paramOut) != 0
          let n = c.nimTypeOf(p, inReturn = p.byRef)
          if n.len == 0:
            ok = false
            break
          if isOut:
            outTypes.add n
            outputs.add i
          else:
            argTypes.add n
            inputs.add i
        if not ok:
          skipped.inc
          noteSkip(sig, cls & "." & raw)
          continue
        # An async *action* legitimately has no return type, so "unmapped" and
        # "produces nothing" have to be told apart before the guard below.
        let async = c.asyncResult(sig.returns)
        let asyncVoid = async.isAsync and c.asyncSpelling(async.res) == "void"
        let declared =
          if sig.returns.kind == skVoid: ""
          else: c.nimTypeOf(sig.returns, inReturn = true)
        if sig.returns.kind != skVoid and declared.len == 0 and not asyncVoid:
          skipped.inc
          noteSkip(sig, cls & "." & raw)
          continue
        if outputs.len > 0 and (async.isAsync or sig.returns.kind == skUnsupported):
          # A tuple of an awaited value, or of a collection walked after the
          # fact, is more than this knows how to assemble.
          skipped.inc
          skipReasons.inc "an out-parameter beside a generic return"
          continue
        let outNames = argumentNames(mi, sig.params.len, isPut)
        var retType = declared
        var valueField = "value"
        for i in outputs:
          if outNames[i] == valueField: valueField = "returned"
        if outputs.len > 0:
          var fields: seq[string]
          if declared.len > 0: fields.add &"{valueField}: {declared}"
          for k, i in outputs: fields.add &"{outNames[i]}: {outTypes[k]}"
          retType = "tuple[" & fields.join(", ") & "]"

        let bare =
          if isGet or isPut: safeMemberName(sanitize(raw[4 .. ^1]))
          else: safeMemberName(sanitize(raw))
        let name = if isPut: "`" & bare & "=`" else: escapeIdent(bare)
        let key = name & "/" & argTypes.join(",")
        # The same Nim signature reached through a second interface — `Close`
        # on a class implementing `IClosable` twice over — is not a method
        # lost, so it is not counted as one.
        if key in emitted: continue
        emitted.incl key

        var params = @[recv]
        for k, i in inputs:
          params.add &"{outNames[i]}: {argTypes[k]}"

        # A class argument needs a QueryInterface of its own, and a string
        # needs an HSTRING; both open a scope, so the body is built up as
        # lines with a running indent.
        var lines: seq[string]
        var outExpr: seq[string]
        var callArgs = @["it"]
        var indent = "  "
        lines.add enter
        indent.add "  "
        for i, p in sig.params:
          let pn = outNames[i]
          if p.byRef and p.kind == skArray:
            # A receive array: the callee allocates, so the count and the
            # buffer both come back and both are ours.
            if p.args.len != 1 or c.elementSpelling(p.args[0]).len == 0:
              ok = false
              break
            let ae = p.args[0]
            let raw = if ae.kind == skString: "HSTRING"
                      elif ae.kind in {skInterface, skObject}: "pointer"
                      else: c.nimTypeOf(ae)
            let es = c.elementSpelling(ae)
            lines.add &"{indent}var {pn}Size: uint32"
            lines.add &"{indent}var {pn}Buf: ptr {raw}"
            outExpr.add (
              if ae.kind == skString: &"takeArrayString({pn}Size, {pn}Buf)"
              elif ae.kind in {skInterface, skObject}:
                &"takeArrayObject[{es}]({pn}Size, {pn}Buf)"
              else: &"takeArray({pn}Size, {pn}Buf)")
            callArgs.add &"{pn}Size.addr"
            callArgs.add &"{pn}Buf.addr"
            continue
          if p.byRef:
            let isOut = (pflags.getOrDefault(i + 1, 0) and paramOut) != 0
            if isOut:
              # A local the call writes into; its value leaves in the tuple.
              # A string or an object arrives in its ABI shape and is converted
              # on the way out, exactly as a declared return would be.
              case p.kind
              of skString:
                lines.add &"{indent}var {pn}: HSTRING"
                outExpr.add &"takeString({pn})"
              of skInterface, skObject:
                lines.add &"{indent}var {pn}: pointer"
                let oc = asClass(p.name)
                outExpr.add (if oc.len > 0: &"adopt[{c.apiName(oc)}]({pn})"
                             else: &"adopt[WinRtObject]({pn})")
              else:
                lines.add &"{indent}var {pn}: {c.nimTypeOf(p, inReturn = true)}"
                outExpr.add pn
            else:
              # By-reference input: the callee wants an address, and a
              # parameter is immutable, so it is copied first.
              lines.add &"{indent}var by{i} = {pn}"
            callArgs.add (if isOut: &"{pn}.addr" else: &"by{i}.addr")
            continue
          case p.kind
          of skString:
            lines.add &"{indent}withHString({pn}, h{i}):"
            indent.add "  "
            callArgs.add &"h{i}"
          of skInterface:
            let (isDelegate, dargs) = c.delegateArgs(p)
            if isDelegate:
              # The caller wrote a closure over Nim types; the runtime needs a
              # COM object whose `Invoke` has the delegate's exact C signature.
              # `newDelegate` is generic over that signature, so the shim here
              # is typed at the ABI and converts on the way through.
              var iidExpr = ""
              if p.kind == skInterface:
                useIface(p.name)
                iidExpr = "IID_" & c.ifaceName(p.name)
              else:
                let computed = sigCtx.parameterizedIid(p)
                if computed.len == 0:
                  ok = false
                  break
                iidExpr = genericIidConst(computed, p)
              var formal, actual: seq[string]
              for k, a in dargs:
                formal.add &"a{k}: {c.abiSpelling(a)}"
                actual.add c.fromAbi(a, &"a{k}")
              let shim =
                if dargs.len == 0: pn
                else: &"proc({formal.join(\", \")}) = {pn}({actual.join(\", \")})"
              lines.add fill(&"{indent}let d{i} = newDelegate(", @[iidExpr, shim], ")")
              # The callee takes its own reference; this one was ours.
              lines.add &"{indent}defer: discard release(d{i})"
              callArgs.add &"d{i}"
              continue
            let pc = asClass(p.name)
            if pc.len > 0:
              let want = c.defaultIface.getOrDefault(pc, "")
              var iidExpr, what = ""
              if want.len > 0:
                useIface(want)
                iidExpr = c.ifaceName(want)
                what = c.ifaceName(want)
              elif pc in paramDefault:
                let ps = paramDefault[pc]
                let computed = sigCtx.parameterizedIid(ps)
                if computed.len == 0:
                  ok = false
                  break
                # A computed constant, so `withIface` gets its name minus the
                # `IID_` it will put back.
                iidExpr = genericIidConst(computed, ps)[4 .. ^1]
                what = shortName(ps.name)
              else:
                ok = false
                break
              lines.add &"{indent}withIface({pn}.p, {iidExpr}, p{i}):"
              indent.add "  "
              callArgs.add &"p{i}"
            elif p.name in c.ifaceIid:
              # A bare interface: whatever object arrived, the callee wants
              # this one interface of it.
              useIface(p.name)
              let wi = c.ifaceName(p.name)
              lines.add &"{indent}withIface({pn}.p, {wi}, p{i}):"
              indent.add "  "
              callArgs.add &"p{i}"
            else:
              callArgs.add pn
          of skEnum:
            callArgs.add pn
          of skObject:
            # An `IInspectable` argument is borrowed for the length of the
            # call: the callee retains it if it keeps it.
            callArgs.add &"{pn}.p"
          of skArray:
            # Two arguments at the ABI: how many, and where. An array of
            # values is pointed at where it lies; strings and objects have to
            # be converted into a buffer of their own first, which opens a
            # scope so that the buffer is freed even if the call fails.
            let ae = p.args[0]
            if ae.kind == skString:
              lines.add &"{indent}withStringArray({pn}, n{i}, d{i}):"
              indent.add "  "
            elif ae.kind in {skInterface, skObject}:
              let ac = asClass(ae.name)
              var iidExpr = ""
              if ae.kind == skObject:
                iidExpr = "IID_IInspectable"
              elif ac.len > 0 and c.defaultIface.hasKey(ac):
                useIface(c.defaultIface[ac])
                iidExpr = "IID_" & c.ifaceName(c.defaultIface[ac])
              elif ae.name in c.ifaceIid:
                useIface(ae.name)
                iidExpr = "IID_" & c.ifaceName(ae.name)
              else:
                ok = false
                break
              lines.add &"{indent}withObjectArray({pn}, {iidExpr}, n{i}, d{i}):"
              indent.add "  "
            else:
              lines.add &"{indent}let n{i} = uint32({pn}.len)"
              lines.add &"{indent}let d{i} = if {pn}.len > 0: " &
                        &"{pn}[0].unsafeAddr else: nil"
            callArgs.add &"n{i}"
            callArgs.add &"d{i}"
          of skUnsupported:
            let (isGenericDelegate, gargs) = c.delegateArgs(p)
            if isGenericDelegate:
              let computed = sigCtx.parameterizedIid(p)
              if computed.len == 0:
                ok = false
                break
              let iidExpr = genericIidConst(computed, p)
              var formal, actual: seq[string]
              for k, a in gargs:
                formal.add &"a{k}: {c.abiSpelling(a)}"
                actual.add c.fromAbi(a, &"a{k}")
              let shim =
                if gargs.len == 0: pn
                else: &"proc({formal.join(\", \")}) = {pn}({actual.join(\", \")})"
              lines.add fill(&"{indent}let d{i} = newDelegate(", @[iidExpr, shim], ")")
              lines.add &"{indent}defer: discard release(d{i})"
              callArgs.add &"d{i}"
              continue
            let boxed = c.referenceValue(p)
            if boxed.kind != skVoid:
              # `none` is a null pointer, which is exactly how WinRT spells an
              # absent `IReference<T>`. The box has to be narrowed to that
              # interface before it is handed over: `CreateX` returns an
              # `IInspectable`, and both are bare pointers at the ABI, so
              # passing the wrong one is silent.
              let computed = sigCtx.parameterizedIid(p)
              if computed.len == 0:
                ok = false
                break
              let rIid = genericIidConst(computed, p)
              let bs = boxSlot(boxed)
              let mk = if boxed.kind == skString:
                         &"boxStringAs({pn}.get, {rIid})"
                       elif bs < 0:
                         usesReference = true
                         &"newReference({pn}.get, {rIid})"
                       else: &"boxAs({pn}.get, {bs}, {rIid})"
              lines.add &"{indent}let p{i} = if {pn}.isSome: {mk} else: nil"
              lines.add &"{indent}defer: discard release(p{i})"
              callArgs.add &"p{i}"
              continue
            let pmc = c.passableMapCollection(p)
            if pmc.found:
              # A seq of Tables: each becomes a map, and a view over those maps
              # is what crosses. Eight instantiations, all computed here.
              let pairT = SigType(kind: skUnsupported, name: PairIface,
                                  args: @[pmc.key, pmc.val])
              let mapT = p.args[0]
              let shapes = [
                ("iterable", SigType(kind: skUnsupported, name: IterableIface,
                                     args: @[pairT])),
                ("cursor", SigType(kind: skUnsupported, args: @[pairT],
                                   name: "Windows.Foundation.Collections.IIterator`1")),
                ("pair", pairT),
                ("view", SigType(kind: skUnsupported, args: @[pmc.key, pmc.val],
                                 name: "Windows.Foundation.Collections.IMapView`2")),
                ("map", SigType(kind: skUnsupported, args: @[pmc.key, pmc.val],
                                name: "Windows.Foundation.Collections.IMap`2"))]
              var fields: seq[string]
              var outer: array[3, string]
              var made = true
              for (field, st) in shapes:
                let computed = sigCtx.parameterizedIid(st)
                if computed.len == 0:
                  made = false
                  break
                fields.add &"{field}: {genericIidConst(computed, st)}"
              for k, iface in ["Windows.Foundation.Collections.IIterable`1",
                               "Windows.Foundation.Collections.IVectorView`1",
                               "Windows.Foundation.Collections.IIterator`1"]:
                let st = SigType(kind: skUnsupported, name: iface, args: @[mapT])
                let computed = sigCtx.parameterizedIid(st)
                if computed.len == 0:
                  made = false
                  break
                outer[k] = genericIidConst(computed, st)
              if not made:
                ok = false
                break
              usesMapView = true
              usesSeqView = true
              lines.add &"{indent}var maps{i}: seq[WinRtObject]"
              lines.add &"{indent}for entries in {pn}:"
              lines.add fill(&"{indent}  maps{i}.add adopt[WinRtObject](asMap(entries, MapIids(",
                             fields, ")))")
              lines.add fill(&"{indent}let p{i} = asIterable[WinRtObject](maps{i}, ",
                             @outer, ")")
              lines.add &"{indent}defer: discard release(p{i})"
              callArgs.add &"p{i}"
              continue
            let pm = c.passableMap(p)
            if pm.found:
              # A Table the callee can read as a map or walk as pairs. Five
              # instantiations are involved and none is declared anywhere, so
              # all five IIDs are computed here.
              let pairT = SigType(kind: skUnsupported, name: PairIface,
                                  args: @[pm.key, pm.val])
              let shapes = [
                ("iterable", SigType(kind: skUnsupported, name: IterableIface,
                                     args: @[pairT])),
                ("cursor", SigType(kind: skUnsupported, args: @[pairT],
                                   name: "Windows.Foundation.Collections.IIterator`1")),
                ("pair", pairT),
                ("view", SigType(kind: skUnsupported, args: @[pm.key, pm.val],
                                 name: "Windows.Foundation.Collections.IMapView`2")),
                ("map", SigType(kind: skUnsupported, args: @[pm.key, pm.val],
                                name: "Windows.Foundation.Collections.IMap`2"))]
              var fields: seq[string]
              var made = true
              for (field, st) in shapes:
                let computed = sigCtx.parameterizedIid(st)
                if computed.len == 0:
                  made = false
                  break
                fields.add &"{field}: {genericIidConst(computed, st)}"
              if not made:
                ok = false
                break
              usesMapView = true
              lines.add fill(&"{indent}let p{i} = asMap({pn}, MapIids(", fields, "))")
              lines.add &"{indent}defer: discard release(p{i})"
              callArgs.add &"p{i}"
              continue
            # A seq the callee can iterate. All three IIDs are needed: the one
            # it asked for, the view it may narrow to, and the iterator it gets
            # from `First` — none of which is declared anywhere, so all three
            # are computed here. A mutable `IVector<T>` needs a fourth.
            let elem = c.passableCollection(p)
            let es = c.elementSpelling(elem)
            var iids: array[3, string]
            var made = true
            for k, iface in ["Windows.Foundation.Collections.IIterable`1",
                             "Windows.Foundation.Collections.IVectorView`1",
                             "Windows.Foundation.Collections.IIterator`1"]:
              let st = SigType(kind: skUnsupported, name: iface, args: @[elem])
              let computed = sigCtx.parameterizedIid(st)
              if computed.len == 0:
                made = false
                break
              iids[k] = genericIidConst(computed, st)
            if not made:
              ok = false
              break
            var vectorArg = ""
            if p.name == VectorIface:
              let st = SigType(kind: skUnsupported, name: VectorIface, args: @[elem])
              let computed = sigCtx.parameterizedIid(st)
              if computed.len == 0:
                ok = false
                break
              vectorArg = ", " & genericIidConst(computed, st)
            usesSeqView = true
            let ctor = if es == "string": "asIterableString"
                       elif elementIsValue(elem): &"asIterableValue[{es}]"
                       else: &"asIterable[{es}]"
            var collIids = @iids
            if vectorArg.len > 0: collIids.add vectorArg[2 .. ^1]
            lines.add fill(&"{indent}let p{i} = {ctor}({pn}, ", collIids, ")")
            lines.add &"{indent}defer: discard release(p{i})"
            callArgs.add &"p{i}"
          else:
            callArgs.add pn
        if not ok:
          skipped.inc
          skipReasons.inc "an argument whose IID could not be computed"
          continue

        let what = &"{cls}.{raw}"
        # With out-parameters the declared return is one field of a tuple, so
        # it lands in a local first.
        let sink = if outputs.len > 0: "ret" else: "result"
        if outputs.len > 0 and declared.len > 0:
          lines.add &"{indent}var ret: {declared}"

        if async.isAsync:
          # Starting the operation is quick — it hands back an object and the
          # work happens elsewhere — so the ABI call stays inside the dispatch
          # scope and the wait happens after that scope closes. Nothing is held
          # across the suspension: not the factory, not the narrowed interface,
          # not a temporary HSTRING.
          #
          # Two IIDs are needed and neither is declared anywhere. `GetResults`
          # is read through the operation's own instantiation, and the handler
          # object has to answer QueryInterface for the completion handler's.
          # WinRT derives both by hashing a signature string, which `piid` does
          # here so nothing has to at run time.
          # The `WithProgress` pair number their slots differently and complete
          # through a different handler, so both are decided from the
          # operation's name rather than from what it produces.
          let withProgress = sig.returns.name in [
            "Windows.Foundation.IAsyncActionWithProgress`1",
            "Windows.Foundation.IAsyncOperationWithProgress`2"]
          let layout = if withProgress: "alProgress" else: "alPlain"
          var opIid, handlerIid = ""
          if asyncVoid and not withProgress:
            # A plain action's handler is not parameterised, so its IID is
            # declared in the metadata like any other delegate's.
            useIface("Windows.Foundation.AsyncActionCompletedHandler")
            handlerIid = "IID_AsyncActionCompletedHandler"
          else:
            let hs =
              if asyncVoid:
                SigType(kind: skUnsupported, args: sig.returns.args,
                        name: "Windows.Foundation.AsyncActionWithProgressCompletedHandler`1")
              elif withProgress:
                SigType(kind: skUnsupported, args: sig.returns.args,
                        name: "Windows.Foundation.AsyncOperationWithProgressCompletedHandler`2")
              else:
                SigType(kind: skUnsupported, args: @[async.res],
                        name: "Windows.Foundation.AsyncOperationCompletedHandler`1")
            let hc = sigCtx.parameterizedIid(hs)
            let computed = sigCtx.parameterizedIid(sig.returns)
            if hc.len == 0 or computed.len == 0:
              skipped.inc
              skipReasons.inc "an operation whose IID could not be computed"
              if dumpSkips:
                stderr.writeLine "an operation whose IID could not be computed	-> " &
                                 brief(sig.returns)
              continue
            handlerIid = genericIidConst(hc, hs)
            opIid = genericIidConst(computed, sig.returns)
          usesAsync = true
          lines.add fill(&"{indent}it.call(", tag & callArgs[1 .. ^1] & "op.addr", ")")
          # Back out to the proc body, past every scope the arguments opened.
          let asyncElem = c.collectionElement(async.res)
          if asyncVoid:
            lines.add fill("  await awaitVoid(", @["op", handlerIid, layout, '"' & what & '"'], ")")
          elif retType == "string":
            lines.add fill("  result = await awaitString(",
                           @["op", opIid, handlerIid, layout, '"' & what & '"'], ")")
          elif c.mapValue(async.res).kind != skVoid:
            # The operation yields a map, read after the wait like any other.
            let pairT = SigType(kind: skUnsupported, args: async.res.args,
                                name: PairIface)
            let iterT = SigType(kind: skUnsupported, args: @[pairT],
                                name: IterableIface)
            let pc = sigCtx.parameterizedIid(pairT)
            let ic = sigCtx.parameterizedIid(iterT)
            if pc.len == 0 or ic.len == 0:
              skipped.inc
              skipReasons.inc "a map whose IID could not be computed"
              continue
            let ks = c.mapKeySpelling(async.res.args[0])
            let vs = c.mapValueSpelling(c.mapValue(async.res))
            let innerIid = c.innerIidArg(sigCtx, c.mapValue(async.res),
                                         genericIidConst)
            lines.add fill("  let coll = await awaitObject(",
                           @["op", opIid, handlerIid, layout, '"' & what & '"'], ")")
            lines.add fill(&"  result = toTable[{ks}, {vs}](",
                           @["coll", genericIidConst(ic, iterT),
                             genericIidConst(pc, pairT)] & trailing(innerIid), ")")
            lines.add "  discard release(coll)"
          elif c.referenceValue(async.res).kind != skVoid:
            # The operation yields an `IReference<T>`: a value, or nothing.
            let computed = sigCtx.parameterizedIid(async.res)
            if computed.len == 0:
              skipped.inc
              skipReasons.inc "a reference whose IID could not be computed"
              continue
            let inner = c.nimTypeOf(c.referenceValue(async.res))
            lines.add &"  let box = await awaitObject(op, {opIid}, " &
                      &"{handlerIid}, {layout}, \"{what}\")"
            lines.add fill(&"  result = readReference[{inner}](",
                           @["box", genericIidConst(computed, async.res),
                             '"' & what & '"'], ")")
            lines.add "  discard release(box)"
          elif asyncElem.kind != skVoid:
            # The operation yields a collection; walking it is the same as for
            # any other, once there is something to walk.
            let inner = sigCtx.parameterizedIid(readableAs(async.res))
            if inner.len == 0:
              skipped.inc
              skipReasons.inc "an operation whose collection IID could not be computed"
              continue
            let collIid = genericIidConst(inner, async.res)
            let es = c.elementSpelling(asyncElem)
            let innerIid = c.innerIidArg(sigCtx, asyncElem, genericIidConst)
            lines.add fill("  let coll = await awaitObject(",
                           @["op", opIid, handlerIid, layout, '"' & what & '"'], ")")
            lines.add fill(&"  result = toSeq[{es}](",
                           @["coll", collIid] & trailing(innerIid), ")")
            # Explicitly discarded: `release` returns a refcount, and the
            # `{.async.}` transform types a proc body by its last expression,
            # so leaving it bare makes the body a uint32.
            lines.add "  discard release(coll)"
          elif async.res.kind in {skBool, skI1, skU1, skI2, skU2, skI4, skU4,
                                  skI8, skU8, skF4, skF8, skEnum, skStruct}:
            lines.add fill(&"  result = await awaitValue[{retType}](",
                           @["op", opIid, handlerIid, layout, '"' & what & '"'], ")")
          else:
            lines.add fill(&"  result = adopt[{retType}](await awaitObject(",
                           @["op", opIid, handlerIid, layout, '"' & what & '"'], "))")
        elif sig.returns.kind == skVoid:
          lines.add fill(&"{indent}it.call(", tag & callArgs[1 .. ^1], ")")
        else:
          # The declared return is a trailing out-parameter at the ABI.
          let retElem = c.collectionElement(sig.returns)
          let retRef = c.referenceValue(sig.returns)
          let retMap = c.mapValue(sig.returns)
          var collectionIid, referenceIid, innerIid = ""
          var mapIterableIid, mapPairIid = ""
          if retMap.kind != skVoid:
            # Reading a map means iterating it, so the IIDs needed are the
            # pair's and the iterable-of-pairs', not the map's own.
            let pairT = SigType(kind: skUnsupported, args: sig.returns.args,
                                name: "Windows.Foundation.Collections.IKeyValuePair`2")
            let iterT = SigType(kind: skUnsupported, args: @[pairT],
                                name: "Windows.Foundation.Collections.IIterable`1")
            let pc = sigCtx.parameterizedIid(pairT)
            let ic = sigCtx.parameterizedIid(iterT)
            if pc.len == 0 or ic.len == 0:
              skipped.inc
              skipReasons.inc "a map whose IID could not be computed"
              continue
            mapPairIid = genericIidConst(pc, pairT)
            mapIterableIid = genericIidConst(ic, iterT)
          if retRef.kind != skVoid:
            let computed = sigCtx.parameterizedIid(sig.returns)
            if computed.len == 0:
              skipped.inc
              skipReasons.inc "a reference whose IID could not be computed"
              continue
            referenceIid = genericIidConst(computed, sig.returns)
          if retElem.kind != skVoid:
            # The IID of `IVectorView<Gamepad>` is declared nowhere: WinRT
            # derives it by hashing a signature string, which `piid` does at
            # generation time so nothing has to at run time.
            let computed = sigCtx.parameterizedIid(readableAs(sig.returns))
            if computed.len == 0:
              skipped.inc
              skipReasons.inc "a collection whose IID could not be computed"
              continue
            collectionIid = genericIidConst(computed, sig.returns)
            innerIid = c.innerIidArg(sigCtx, retElem, genericIidConst)

          case sig.returns.kind
          of skString: lines.add &"{indent}var tmp: HSTRING"
          of skInterface, skObject: lines.add &"{indent}var tmp: pointer"
          of skUnsupported: lines.add &"{indent}var tmp: pointer"
          of skArray:
            # A returned array is a count and a buffer, both written through,
            # and both then ours.
            let ae = sig.returns.args[0]
            let raw = if ae.kind == skString: "HSTRING"
                      elif ae.kind in {skInterface, skObject}: "pointer"
                      else: c.nimTypeOf(ae)
            lines.add &"{indent}var tmpSize: uint32"
            lines.add &"{indent}var tmp: ptr {raw}"
          else: lines.add &"{indent}var tmp: {declared}"
          if sig.returns.kind == skArray:
            lines.add fill(&"{indent}it.call(",
                           tag & callArgs[1 .. ^1] & @["tmpSize.addr", "tmp.addr"], ")")
          else:
            lines.add fill(&"{indent}it.call(", tag & callArgs[1 .. ^1] & "tmp.addr", ")")
          case sig.returns.kind
          of skString: lines.add &"{indent}{sink} = takeString(tmp)"
          of skEnum: lines.add &"{indent}{sink} = tmp"
          of skUnsupported:
            if retMap.kind != skVoid:
              let ks = c.mapKeySpelling(sig.returns.args[0])
              let vs = c.mapValueSpelling(retMap)
              let innerIid = c.innerIidArg(sigCtx, retMap, genericIidConst)
              lines.add fill(&"{indent}{sink} = toTable[{ks}, {vs}](",
                             @["tmp", mapIterableIid, mapPairIid] & trailing(innerIid),
                             ")")
            elif retRef.kind != skVoid:
              # `IReference<T>` is an interface, so "no value" arrives as a
              # null pointer rather than a sentinel.
              let inner = c.nimTypeOf(retRef)
              lines.add fill(&"{indent}{sink} = readReference[{inner}](",
                             @["tmp", referenceIid, '"' & what & '"'], ")")
            else:
              # The collection itself is ours to release; its elements were
              # adopted while walking it.
              let elemType = c.elementSpelling(retElem)
              lines.add fill(&"{indent}{sink} = toSeq[{elemType}](",
                             @["tmp", collectionIid] & trailing(innerIid), ")")
            lines.add &"{indent}release(tmp)"
          of skArray:
            let ae = sig.returns.args[0]
            let es = c.elementSpelling(ae)
            if ae.kind == skString:
              lines.add &"{indent}{sink} = takeArrayString(tmpSize, tmp)"
            elif ae.kind in {skInterface, skObject}:
              lines.add &"{indent}{sink} = takeArrayObject[{es}](tmpSize, tmp)"
            else:
              lines.add &"{indent}{sink} = takeArray(tmpSize, tmp)"
          of skObject:
            lines.add &"{indent}{sink} = adopt[WinRtObject](tmp)"
          of skInterface:
            lines.add &"{indent}{sink} = adopt[{declared}](tmp)"
          else: lines.add &"{indent}{sink} = tmp"

        # The out-parameters are locals inside whatever scopes the arguments
        # opened, so the tuple is assembled there and not after. Without this
        # the locals were written and then dropped, and every method with an
        # out-parameter returned a zeroed tuple.
        if outputs.len > 0:
          var fields: seq[string]
          if declared.len > 0: fields.add &"{valueField}: ret"
          for k, i in outputs: fields.add &"{outNames[i]}: {outExpr[k]}"
          lines.add &"{indent}result = (" & fields.join(", ") & ")"

        if async.isAsync:
          let r = if retType.len > 0: &": Future[{retType}]" else: ""
          buf.add fill(&"proc {name}*(", params, &"){r} {{.async.}} =") & "\n"
        else:
          let r = if retType.len > 0: ": " & retType else: ""
          buf.add fill(&"proc {name}*(", params, &"){r} =") & "\n"
        buf.add &"  ## {t.fullName}.{raw}\n"
        if async.isAsync:
          buf.add "  var op: pointer\n"
        for l in lines: buf.add l & "\n"
        buf.add "\n"
        procs.inc

  # The constants go above everything that names them. `buf` is built in one
  # pass, so they are spliced in at the marker rather than appended.
  var iidBlock = ""
  if genericIidOrder.len > 0:
    iidBlock.add "# IIDs of parameterised interfaces, computed from a signature\n"
    iidBlock.add "# string rather than read from metadata - see tools/piid.nim.\n"
    for (name, iid) in genericIidOrder:
      iidBlock.add "const " & name & "* = " & guidLiteral(iid) & "\n"
    iidBlock.add "\n"
  buf = buf.replace(GenericIidMarker, iidBlock)
  let asyncPath = corePath.rsplit('/', 1)[0] & "/asyncops"
  # `import ./core` and `import ./abi/[types, ...]`: everything a caller
  # needs to name what this module hands back is exported again, and the
  # runtime modules it merely uses are not.
  let here = corePath.rsplit('/', 1)[0]
  let coreName = corePath.split('/')[^1]
  var imports = &"import {corePath}\n"
  var exported = @[coreName]
  if part != pClasses:
    let groups = "types" & sorted(toSeq(usedAbi.items))
    imports.add fill(&"import {abiPath}/[", groups, "]") & "\n"
    exported.add groups
    var runtime: seq[string]
    if part == pMembers: runtime.add "classes"
    runtime.add "delegate"
    if usesAsync: runtime.add "asyncops"
    if usesSeqView: runtime.add "seqview"
    if usesMapView: runtime.add "mapview"
    if usesReference: runtime.add "reference"
    imports.add fill(&"import {here}/[", runtime, "]") & "\n"
    if part == pMembers: exported.add "classes"
    if usesAsync: exported.add "asyncops"
  imports.add fill("export ", exported) & "\n\n"
  buf = buf.replace(ImportsMarker, imports)

  writeFile(outPath, buf)
  echo outPath
  echo &"  classes    {classOrder.len}"
  echo &"  procs      {procs}  (constructors {ctors})"
  echo &"  events     {events}"
  echo &"  skipped    {skipped}"
  skipReasons.sort()
  for reason, count in skipReasons:
    echo &"    {count:>5}  {reason}"
  (classOrder.len, procs, ctors, events, skipped)


when isMainModule:
  if paramCount() < 3:
    quit "usage: wrappers <winmd> <prefix> <out.nim> [core-import] [abi-import]\n" &
         "       wrappers <winmd> --split <out-dir> [core-import] [abi-dir]"

  let winmdPath = paramStr(1)
  let md = load(winmdPath)
  let iids = md.guids()

  if paramStr(2) != "--split":
    discard emitModule(md, iids, winmdPath, paramStr(2), paramStr(3),
                       (if paramCount() >= 4: paramStr(4) else: "../core"),
                       (if paramCount() >= 5: paramStr(5) else: "./xaml_abi"))
    quit 0

  # `classes.nim` first with every wrapper type, then one module of members
  # per namespace group over it. The groups come from the metadata for the
  # same reason `generate.nim` takes them from there: a list written down
  # anywhere else is a list that can disagree with what was generated.
  let outDir = paramStr(3)
  let corePath = if paramCount() >= 4: paramStr(4) else: "./core"
  let abiDir = if paramCount() >= 5: paramStr(5) else: "./abi"
  createDir(outDir)

  var total = emitModule(md, iids, winmdPath, "Windows",
                         outDir / "classes.nim", corePath, abiDir,
                         part = pClasses)

  var groups: seq[string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    let g = topGroup(t.namespace)
    if g notin groups: groups.add g
  groups.sort()

  for g in groups:
    let m = moduleName(g)
    let e = emitModule(md, iids, winmdPath, g, outDir / (m & ".nim"),
                       corePath, abiDir, part = pMembers)
    total.procs += e.procs
    total.ctors += e.ctors
    total.events += e.events
    total.skipped += e.skipped

  echo ""
  echo &"  {groups.len + 1} modules  {total.classes} classes  {total.procs} procs" &
       &"  ({total.ctors} constructors)  {total.events} events"
  echo &"  {total.skipped} skipped"
