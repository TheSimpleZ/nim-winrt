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

import std/[os, algorithm, strformat, strutils, tables, sets]
import ./winmd
import ./foreign
import ./piid
import ./nimgen
import ./grouping

const tdInterface = 0x20'u32

const GenericIidMarker = "##<computed-iids>##\n"
const AsyncImportMarker = "##<async-import>##\n"
const SeqViewImportMarker = "##<seqview-import>##\n"
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
func nimTypeOf(c: Ctx, t: SigType, inReturn = false): string

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
]

const PassableIfaces = [
  ## The read-only shapes, which is all a seq can honestly stand in for.
  ## `IVector<T>` is mutable — a callee may append to it — and handing over
  ## something that refuses would be worse than not generating the method.
  "Windows.Foundation.Collections.IIterable`1",
  "Windows.Foundation.Collections.IVectorView`1",
]

func passableCollection(c: Ctx, t: SigType): SigType =
  ## The element type, if `t` is a collection a Nim seq can be passed as.
  if t.kind == skUnsupported and t.args.len == 1 and t.name in PassableIfaces:
    t.args[0]
  else:
    SigType(kind: skVoid)

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
  ## How an element arrives: a class, a string, or nothing we can carry.
  case e.kind
  of skString: "string"
  of skInterface:
    if e.name in c.classes: shortName(e.name)
    elif e.name in c.classOfIface: shortName(c.classOfIface[e.name])
    else: ""
  else: ""

func asyncSpelling(c: Ctx, res: SigType): string =
  ## What an async operation's result becomes in Nim. "void" is a real answer
  ## here — an action completes without producing anything — and "" means the
  ## result is a shape this cannot carry.
  ## Only the shapes `core` can fetch a result for: nothing, a string, or an
  ## object. A primitive result needs its own `GetResults` signature per width
  ## and a nested collection needs the walk as well, so both stay skipped and
  ## counted rather than half-supported.
  if res.kind == skVoid: return "void"
  # A collection result is walked after the wait, so it reads as a `seq`.
  let e = c.collectionElement(res)
  if e.kind != skVoid:
    let es = c.elementSpelling(e)
    return if es.len > 0: "seq[" & es & "]" else: ""
  case res.kind
  of skString: "string"
  of skInterface:
    if res.name in c.classes: shortName(res.name)
    elif res.name in c.classOfIface: shortName(c.classOfIface[res.name])
    else: ""
  of skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4, skF8:
    c.nimTypeOf(res)
  of skEnum:
    if res.name in c.enums: shortName(res.name) else: ""
  of skStruct:
    if res.name in c.aliases or res.name in c.structs or
       res.name in foreignEnums: c.nimTypeOf(res)
    else: ""
  else: ""

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
    let a = c.asyncResult(t)
    let r = c.referenceValue(t)
    let e = c.collectionElement(t)
    let passable = c.passableCollection(t)
    if inReturn and a.isAsync and c.asyncSpelling(a.res).len > 0: ""
    elif inReturn and r.kind != skVoid and c.skipReason(r).len == 0: ""
    elif inReturn and e.kind != skVoid and c.elementSpelling(e).len > 0: ""
    elif not inReturn and passable.kind != skVoid and
         c.elementSpelling(passable).len > 0: ""
    elif t.name.len > 0 and t.args.len > 0: "generic: " & shortName(t.name)
    else: "a type variable or function pointer"
  of skArray:
    # A `[in]` array of values crosses as a count and a pointer, which Nim
    # spells `openArray`. Objects and strings would each need a marshalled
    # copy of the whole array, and a returned array is allocated by the callee
    # and owned by us — neither is done.
    if inReturn: "an array"
    elif t.args.len == 1 and t.args[0].kind in
         {skBool, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4, skF8,
          skEnum, skStruct} and c.skipReason(t.args[0]).len == 0: ""
    else: "an array"
  of skEnum:
    if t.name in c.enums: "" else: "an enum from another winmd"
  of skInterface:
    if inReturn and c.asyncResult(t).isAsync: ""
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
  if inReturn:
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
  of skObject: "pointer"
  of skEnum:
    if t.name in c.enums: shortName(t.name) else: ""
  of skInterface:
    # The resolved name is a runtime class for most parameters and a bare
    # interface for the rest. A class becomes its wrapper type; an interface
    # stays a pointer, because there is no wrapper to give it.
    if t.name in c.classes: shortName(t.name)
    elif t.name in c.classOfIface: shortName(c.classOfIface[t.name])
    elif t.name in c.ifaceIid: "pointer"
    else: ""
  of skStruct:
    # Structs cross by value and the ABI module has already laid out the ones it
    # could, so a wrapper can name them directly — this is what makes `Margin`,
    # `Padding` and `Color` reachable at all.
    if t.name in foreignEnums: "int32"
    elif t.name in c.aliases: c.aliases[t.name]
    elif t.name in c.structs: shortName(t.name)
    else: ""
  of skArray:
    # An incoming array of values is a count and a pointer, which is what
    # `openArray` already is — but only of values. A `seq[string]` is not an
    # array of HSTRINGs and a `seq[SomeClass]` is not an array of interface
    # pointers; each would need the whole array marshalled into a second
    # buffer, which is not done. `nimTypeOf` is the gate the generator
    # actually consults, so the restriction has to live here and not only in
    # `skipReason`.
    if inReturn or t.args.len != 1: ""
    elif t.args[0].kind notin {skBool, skI1, skU1, skI2, skU2, skI4, skU4,
                               skI8, skU8, skF4, skF8, skEnum, skStruct}: ""
    else:
      let e = c.nimTypeOf(t.args[0])
      if e.len > 0: "openArray[" & e & "]" else: ""
  else: ""

type Emission = tuple
  classes, procs, ctors, events, skipped: int

proc emitModule(md: WinMd; iids: Table[int, string];
                winmdPath, prefix, outPath, corePath, abiPath: string;
                peers: seq[string] = @[]): Emission =
  ## Write the API layer for one namespace, over the ABI module at `abiPath`.
  let delegatePath = corePath.rsplit('/', 1)[0] & "/delegate"
  let impls = md.interfaceImpls()
  let attrs = md.attributeNames()

  var byName = initTable[string, int]()
  for t in md.types: byName[t.fullName] = t.index

  # The groups whose API modules this one imports.
  var peerGroups: HashSet[string]
  for p in peers: peerGroups.incl p
  var c = Ctx()
  # Both layers reduce a full name to its last segment, and two namespaces in
  # one group can end in the same one — `Windows.UI.Composition` and
  # `Windows.UI.Xaml.Media` both declare `CompositionTarget`. Whichever comes
  # first in the metadata wins, and this has to make the same choice
  # `generate.nim` did: name the loser and the emitted code refers to a slot
  # that was never written.
  var takenIface, takenEnum: HashSet[string]
  for t in md.types:
    if t.index in iids and (t.flags and tdInterface) != 0:
      c.ifaceIid.incl t.fullName
      # `IID_X` and `Slot_X_Y` come from the ABI module this one imports, which
      # covers this namespace and no other. A class here may well implement an
      # interface from elsewhere — a Windows.Networking class implementing
      # `IBackgroundTask` — and those members are skipped rather than named.
      # Reachable means "this module or one it imports". A peer's classes and
      # interfaces arrive through that import, so a method mentioning one can
      # be generated rather than skipped.
      if t.namespace.startsWith(prefix) or topGroup(t.namespace) in peerGroups:
        let k = nimIdent(sanitize(t.name))
        if k notin takenIface:
          takenIface.incl k
          c.localIface.incl t.fullName
    # Enums and structs are *not* widened to peers, only interfaces are. An
    # enum appears in the ABI signature this layer calls through, and the ABI
    # module could not always name a peer's — a cut dependency cycle leaves
    # `Windows.System.VirtualKey` spelled `int32` in `abi/devices`. Naming it
    # here would mean the two layers disagreed about the same parameter.
    if t.namespace.startsWith(prefix) and md.isEnum(t.index):
      let k = nimIdent(sanitize(t.name))
      if k notin takenEnum:
        takenEnum.incl k
        c.enums.incl t.fullName
  # Mirror what `generate.nim` emitted: the foreign table, plus in-namespace
  # value types. A struct it could not lay out is absent from the ABI module, so a
  # wrapper naming it would not compile.
  for (name, _) in foreignStructs:
    c.structs.incl name
  for (name, nim) in foreignAliases:
    c.aliases[name] = nim
  for t in md.types:
    # Prefix-only, for the same reason as enums: a struct crosses by value in
    # the ABI signature this layer calls through, and the ABI module could not
    # always name a peer's. `Windows.Devices.Geolocation.BasicGeoposition` is
    # spelled out in `abi/devices` and absent from `abi/services`, so naming it
    # here would generate a call to a signature that was never emitted.
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
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      if md.str(md.cell(tMethodDef, mi, "Name")) != "Invoke": continue
      delegates[t.fullName] = md.methodSignature(mi).params
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
  var classOrder: seq[TypeRow]
  var takenNames: HashSet[string]
  var usesAsync = false
  var usesSeqView = false
  for t in md.types:
    # A peer's classes are walked too, so this module can *name* them in a
    # signature. Only its own are written here — the peer emits its own types,
    # its own destructors and its own members.
    let mine = t.namespace.startsWith(prefix)
    if not mine and topGroup(t.namespace) notin peerGroups: continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    let own = impls.getOrDefault(t.index, @[])
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
    if default.len == 0 and md.baseName(t.index) == "":
      # No instance to have. If the metadata gives it a static interface it is
      # a class like `PowerManager` — real API, reached through the activation
      # factory — so it is kept, as a name to hang those members on.
      if t.index notin staticIfaces: continue
      staticOnly.incl t.fullName
    # Two namespaces under one group can declare the same short name:
    # `Windows.UI.Composition.CompositionTarget` and
    # `Windows.UI.Xaml.Media.CompositionTarget` both want `CompositionTarget`.
    # The ABI layer keeps whichever comes first and so must this, or the two
    # disagree about what the name means.
    if nimIdent(shortName(t.fullName)) in takenNames: continue
    takenNames.incl nimIdent(shortName(t.fullName))
    c.classes.incl t.fullName
    if default.len > 0:
      c.defaultIface[t.fullName] = default
      sigCtx.defaultIface[t.fullName] = default
      # A factory returns the class's default interface rather than the class,
      # so this is what lets `CreateUri` be typed as returning a `Uri`.
      c.classOfIface[default] = t.fullName
    if mine: classOrder.add t

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
  buf.add &"## Namespace: {prefix}\n##\n"
  buf.add "## Each class is a Nim object in a real inheritance chain, so an\n"
  buf.add "## inherited method resolves without being emitted again for every\n"
  buf.add "## subclass, and a derived value passes where a base is expected.\n\n"
  buf.add &"import {corePath}\n"
  buf.add &"import {abiPath}\n"
  for p in peers:
    buf.add &"import ./{moduleName(p)}\n"
    buf.add &"export {moduleName(p)}\n"
  buf.add &"import {delegatePath}\n"
  buf.add &"export {corePath.split('/')[^1]}, {abiPath.split('/')[^1]}\n"
  # Whether this namespace has any async method is only known once its members
  # have been walked, so the import is spliced in at the end. A module without
  # one does not drag `std/asyncdispatch` into programs that never await.
  buf.add AsyncImportMarker
  buf.add SeqViewImportMarker
  buf.add "\n"
  # `withIface`, `withStatics`, `takeString`, `activateAs`, `composeAs`,
  # `adopt` and `borrow` are not emitted here. They are the same in every
  # module, so eighteen copies collided the moment a program imported two of
  # them; they live in `core` and arrive through the import above.

  buf.add GenericIidMarker
  buf.add "type\n"
  var roots: seq[string]
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
    let n = shortName(t.fullName)
    let base = md.baseName(t.index)
    if t.fullName in staticOnly:
      # Never constructed, never held: it exists so that `PowerManager.x`
      # resolves. No pointer, so no reference counting either.
      buf.add &"  {n}* = object\n"
    elif base.len > 0 and base in c.classes:
      buf.add &"  {n}* = object of {shortName(base)}\n"
    else:
      buf.add &"  {n}* {{.inheritable, pure.}} = object\n"
      buf.add "    p*: pointer\n"
      roots.add n
  buf.add "\n"

  # Reference counting, done by the compiler.
  #
  # WinRT is COM: a getter hands back a reference that is the caller's to
  # release. There are 633 such getters here, so leaving that to the caller
  # means a GUI leaks a reference every time it reads a property — unbounded
  # growth in exactly the long-running tray-style app this is meant for.
  #
  # Nim's `=destroy` and `=copy` on the *root* of each hierarchy are inherited
  # by every derived type, so one pair per root covers all 894 classes and the
  # objects stay one pointer wide.
  for r in roots:
    buf.add &"proc `=destroy`*(x: var {r}) =\n"
    buf.add "  if x.p != nil: releaseIfLive(x.p)\n"
    buf.add &"proc `=copy`*(dst: var {r}, src: {r}) =\n"
    buf.add "  if dst.p == src.p: return\n"
    buf.add "  `=destroy`(dst)\n"
    buf.add "  wasMoved(dst)\n"
    buf.add "  dst.p = src.p\n"
    buf.add "  if dst.p != nil: addRefIfLive(dst.p)\n"
    buf.add &"proc `=sink`*(dst: var {r}, src: {r}) =\n"
    buf.add "  # A move transfers the reference, so neither count changes.\n"
    buf.add "  `=destroy`(dst)\n"
    buf.add "  wasMoved(dst)\n"
    buf.add "  dst.p = src.p\n"
  buf.add "\n"

  for t in classOrder:
    if t.fullName in staticOnly: continue   # no pointer to be nil
    let n = shortName(t.fullName)
    buf.add &"func isNil*(x: {n}): bool {{.inline.}} = x.p.isNil\n"
  buf.add "\n"

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

  proc noteSkip(sig: MethodSig) =
    ## Record the first thing about a signature that has no wrapper spelling.
    for p in sig.params:
      let r = c.skipReason(p)
      if r.len > 0:
        skipReasons.inc r
        return
    let r = c.skipReason(sig.returns, inReturn = true)
    skipReasons.inc (if r.len > 0: r else: "already emitted, or a duplicate name")

  for t in classOrder:
    let cls = shortName(t.fullName)
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
      let iface = shortName(c.defaultIface[t.fullName])
      if plainActivations > 0:
        buf.add &"proc new{cls}*(): {cls} =\n"
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
            let fac = shortName(factoryFull)
            buf.add &"proc new{cls}*(): {cls} =\n"
            buf.add &"  ## Compose a `{t.fullName}`.\n"
            buf.add &"  adopt[{cls}](composeAs(\"{t.fullName}\", IID_{fac},\n"
            buf.add &"                     IID_{iface}, {slot}))\n\n"
            ctors.inc

    # A class contributes members from two places: the interfaces it
    # implements, whose members need an instance, and the interfaces named by
    # its `StaticAttribute`, whose members do not and are reached through the
    # activation factory. `PowerManager` has only the second kind.
    var faces: seq[(string, bool)]
    for coded in impls.getOrDefault(t.index, @[]):
      faces.add (md.typeDefOrRefName(coded), false)
    for n in staticIfaces.getOrDefault(t.index, @[]):
      faces.add (n, true)
    for n in factories:
      faces.add (n, true)

    for (ifaceFull, isStatic) in faces:
      if ifaceFull notin c.localIface or ifaceFull notin byName: continue
      let iface = shortName(ifaceFull)
      # A static member hangs off the type, so it reads `PowerManager.x` at the
      # call site and takes a `typedesc` here.
      let recv = if isStatic: &"_: typedesc[{cls}]" else: &"self: {cls}"
      let enter =
        if isStatic: &"withStatics(\"{t.fullName}\", IID_{iface}, it):"
        else: &"withIface(self.p, IID_{iface}, \"{iface}\", it):"
      let (first, stop) = md.methodRange(byName[ifaceFull])
      var seen = initCountTable[string]()
      for mi in first ..< stop:
        let raw = md.str(md.cell(tMethodDef, mi, "Name"))
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
          # The handler is either a delegate declared in this winmd, or a
          # `TypedEventHandler<S, A>` / `EventHandler<A>` — a parameterised
          # delegate whose IID has to be computed. Both end up as a two-argument
          # Invoke, which is the vtable `delegate.nim` implements.
          var handlerArgs: seq[SigType]
          var handlerIid = ""          # the expression naming its IID
          if sigE.params.len == 1:
            let h = sigE.params[0]
            if h.kind == skInterface and h.name in delegates:
              handlerArgs = delegates[h.name]
              handlerIid = "IID_" & shortName(h.name)
            elif h.kind == skUnsupported and h.args.len > 0:
              let computed = sigCtx.parameterizedIid(h)
              if computed.len > 0:
                # `TypedEventHandler<S, A>.Invoke(S, A)`, and
                # `EventHandler<A>.Invoke(Object, A)`.
                handlerArgs =
                  if h.args.len == 2: h.args
                  else: @[SigType(kind: skObject), h.args[0]]
                handlerIid = genericIidConst(computed, h)

          if handlerIid.len > 0:
            if handlerArgs.len == 2:
              let argsType =
                if handlerArgs[1].name in c.classes: shortName(handlerArgs[1].name)
                else: "pointer"
              let dlgName = handlerIid
              let key = "on" & evName & "/handler"
              if key notin emitted:
                emitted.incl key
                buf.add &"proc on{evName}*({recv},\n"
                buf.add &"    handler: proc(sender: pointer, args: {argsType})): " &
                        "EventRegistrationToken {.discardable.} =\n"
                buf.add &"  ## {t.fullName}.{raw}\n"
                buf.add "  ##\n"
                buf.add "  ## The token is what `remove" & evName &
                        "` needs. The delegate is released here because the\n"
                buf.add "  ## event source took its own reference.\n"
                buf.add &"  {enter}\n"
                buf.add &"    let cb = newEventDelegate({dlgName},\n"
                if argsType == "pointer":
                  buf.add "      proc(s, a: pointer) = handler(s, a))\n"
                else:
                  buf.add "      proc(s, a: pointer) = handler(s, " &
                          &"borrow[{argsType}](a)))\n"
                buf.add "    try:\n"
                buf.add &"      vcall(it, Slot_{tag}, Fn_{tag})(it, cb, result.addr)\n"
                buf.add &"        .check(\"{cls}.{raw}\")\n"
                buf.add "    finally:\n"
                buf.add "      release(cb)\n\n"
                events.inc
                continue
          skipped.inc
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
              buf.add &"  {enter}\n"
              buf.add &"    vcall(it, Slot_{tag}, Fn_{tag})(it, token)" &
                      &".check(\"{cls}.{raw}\")\n\n"
              events.inc
              continue
          skipped.inc
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
          noteSkip(sig)
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
          noteSkip(sig)
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
        if key in emitted:
          skipped.inc
          continue
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
        lines.add &"{indent}{enter}"
        indent.add "  "
        for i, p in sig.params:
          let pn = outNames[i]
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
                outExpr.add (if oc.len > 0: &"adopt[{shortName(oc)}]({pn})"
                             else: pn)
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
            let pc = asClass(p.name)
            if pc.len > 0:
              let want = c.defaultIface.getOrDefault(pc, "")
              if want.len == 0:
                ok = false
                break
              let wi = shortName(want)
              lines.add &"{indent}withIface({pn}.p, IID_{wi}, \"{wi}\", p{i}):"
              indent.add "  "
              callArgs.add &"p{i}"
            else:
              callArgs.add pn
          of skEnum:
            callArgs.add pn
          of skArray:
            # Two arguments at the ABI: how many, and where. An empty
            # openArray has no first element to take the address of.
            lines.add &"{indent}let n{i} = uint32({pn}.len)"
            lines.add &"{indent}let d{i} = if {pn}.len > 0: " &
                      &"{pn}[0].unsafeAddr else: nil"
            callArgs.add &"n{i}"
            callArgs.add &"d{i}"
          of skUnsupported:
            # A seq the callee can iterate. All three IIDs are needed: the one
            # it asked for, the view it may narrow to, and the iterator it gets
            # from `First` — none of which is declared anywhere, so all three
            # are computed here.
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
            usesSeqView = true
            let ctor = if es == "string": "asIterableString"
                       else: &"asIterable[{es}]"
            lines.add &"{indent}let p{i} = {ctor}({pn}, {iids[0]}, " &
                      &"{iids[1]}, {iids[2]})"
            lines.add &"{indent}defer: discard release(p{i})"
            callArgs.add &"p{i}"
          else:
            callArgs.add pn
        if not ok:
          skipped.inc
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
          var opIid, handlerIid = ""
          if asyncVoid:
            # An action's handler is not parameterised, so its IID is declared
            # in the metadata like any other delegate's.
            handlerIid = "IID_AsyncActionCompletedHandler"
          else:
            let hs = SigType(kind: skUnsupported, args: @[async.res],
                             name: "Windows.Foundation.AsyncOperationCompletedHandler`1")
            let hc = sigCtx.parameterizedIid(hs)
            let computed = sigCtx.parameterizedIid(sig.returns)
            if hc.len == 0 or computed.len == 0:
              skipped.inc
              skipReasons.inc "an operation whose IID could not be computed"
              continue
            handlerIid = genericIidConst(hc, hs)
            opIid = genericIidConst(computed, sig.returns)
          usesAsync = true
          lines.add &"{indent}vcall(it, Slot_{tag}, Fn_{tag})(" &
                    callArgs.join(", ") & &", op.addr).check(\"{what}\")"
          # Back out to the proc body, past every scope the arguments opened.
          let asyncElem = c.collectionElement(async.res)
          if asyncVoid:
            lines.add &"  await awaitVoid(op, {handlerIid}, \"{what}\")"
          elif retType == "string":
            lines.add &"  result = await awaitString(op, {opIid}, " &
                      &"{handlerIid}, \"{what}\")"
          elif asyncElem.kind != skVoid:
            # The operation yields a collection; walking it is the same as for
            # any other, once there is something to walk.
            let inner = sigCtx.parameterizedIid(async.res)
            if inner.len == 0:
              skipped.inc
              skipReasons.inc "an operation whose collection IID could not be computed"
              continue
            let collIid = genericIidConst(inner, async.res)
            let es = c.elementSpelling(asyncElem)
            lines.add &"  let coll = await awaitObject(op, {opIid}, " &
                      &"{handlerIid}, \"{what}\")"
            if es == "string":
              lines.add &"  result = toSeqString(coll, {collIid})"
            else:
              lines.add &"  result = toSeq[{es}](coll, {collIid})"
            # Explicitly discarded: `release` returns a refcount, and the
            # `{.async.}` transform types a proc body by its last expression,
            # so leaving it bare makes the body a uint32.
            lines.add "  discard release(coll)"
          elif async.res.kind in {skBool, skI1, skU1, skI2, skU2, skI4, skU4,
                                  skI8, skU8, skF4, skF8, skEnum, skStruct}:
            lines.add &"  result = await awaitValue[{retType}](op, {opIid}, " &
                      &"{handlerIid}, \"{what}\")"
          else:
            lines.add &"  result = adopt[{retType}](await awaitObject(" &
                      &"op, {opIid}, {handlerIid}, \"{what}\"))"
        elif sig.returns.kind == skVoid:
          lines.add &"{indent}vcall(it, Slot_{tag}, Fn_{tag})(" &
                    callArgs.join(", ") & &").check(\"{what}\")"
        else:
          # The declared return is a trailing out-parameter at the ABI.
          let retElem = c.collectionElement(sig.returns)
          let retRef = c.referenceValue(sig.returns)
          var collectionIid, referenceIid = ""
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
            let computed = sigCtx.parameterizedIid(sig.returns)
            if computed.len == 0:
              skipped.inc
              skipReasons.inc "a collection whose IID could not be computed"
              continue
            collectionIid = genericIidConst(computed, sig.returns)

          case sig.returns.kind
          of skString: lines.add &"{indent}var tmp: HSTRING"
          of skInterface, skObject: lines.add &"{indent}var tmp: pointer"
          of skUnsupported: lines.add &"{indent}var tmp: pointer"
          else: lines.add &"{indent}var tmp: {declared}"
          lines.add &"{indent}vcall(it, Slot_{tag}, Fn_{tag})(" &
                    callArgs.join(", ") & &", tmp.addr).check(\"{what}\")"
          case sig.returns.kind
          of skString: lines.add &"{indent}{sink} = takeString(tmp)"
          of skEnum: lines.add &"{indent}{sink} = tmp"
          of skUnsupported:
            if retRef.kind != skVoid:
              # `IReference<T>` is an interface, so "no value" arrives as a
              # null pointer rather than a sentinel.
              let inner = c.nimTypeOf(retRef)
              lines.add &"{indent}{sink} = readReference[{inner}](" &
                        &"tmp, {referenceIid}, \"{what}\")"
            else:
              # The collection itself is ours to release; its elements were
              # adopted while walking it.
              let elemType = c.elementSpelling(retElem)
              if elemType == "string":
                lines.add &"{indent}{sink} = toSeqString(tmp, {collectionIid})"
              else:
                lines.add &"{indent}{sink} = toSeq[{elemType}](tmp, {collectionIid})"
            lines.add &"{indent}release(tmp)"
          of skInterface:
            if asClass(sig.returns.name).len > 0:
              lines.add &"{indent}{sink} = adopt[{declared}](tmp)"
            else:
              lines.add &"{indent}{sink} = tmp"
          else: lines.add &"{indent}{sink} = tmp"

        if async.isAsync:
          let r = if retType.len > 0: &": Future[{retType}]" else: ""
          buf.add &"proc {name}*(" & params.join(", ") &
                  &"){r} {{.async.}} =\n"
        else:
          buf.add &"proc {name}*(" & params.join(", ") & ")" &
                  (if retType.len > 0: ": " & retType else: "") & "  =\n"
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
  buf = buf.replace(AsyncImportMarker,
    if usesAsync: &"import {asyncPath}\nexport asyncops\n" else: "")
  let seqPath = corePath.rsplit('/', 1)[0] & "/seqview"
  buf = buf.replace(SeqViewImportMarker,
    if usesSeqView: &"import {seqPath}\n" else: "")

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

  # One module per namespace group, and the groups come from the metadata for
  # the same reason `generate.nim` takes them from there: a list written down
  # anywhere else is a list that can disagree with what was generated. An SDK
  # that adds a top-level namespace would otherwise produce an ABI module with
  # no API module over it, and nothing would say so.
  let outDir = paramStr(3)
  let corePath = if paramCount() >= 4: paramStr(4) else: "./core"
  let abiDir = if paramCount() >= 5: paramStr(5) else: "./abi"
  createDir(outDir)

  # The API layer needs a wider dependency graph than the ABI layer: a class
  # parameter is that class's wrapper type here, where at the ABI it was a bare
  # pointer. So the order is recomputed counting interfaces too, and each
  # module imports the ones before it that it actually names.
  let plan = groupPlan(md, @hoisted, withInterfaces = true)

  var total: Emission
  var written: seq[string]
  for g in plan.order:
    let m = moduleName(g)
    # Only the root. Importing every dependency recovers about 1,800 more
    # methods and takes `import winrt/ui` from under two seconds to sixty-four,
    # because an API module is far larger than the ABI module under it and the
    # graph is dense. `foundation` is the exception worth paying for: nearly
    # everything names something in it, and it is one of the smallest.
    var peers: seq[string]
    for dep in plan.deps[g]:
      if dep == rootGroup and moduleName(dep) in written: peers.add dep
    let e = emitModule(md, iids, winmdPath, g, outDir / (m & ".nim"),
                       corePath, abiDir & "/" & m, peers)
    written.add m
    total.classes += e.classes
    total.procs += e.procs
    total.ctors += e.ctors
    total.events += e.events
    total.skipped += e.skipped

  echo ""
  echo &"  {plan.order.len} modules  {total.classes} classes  {total.procs} procs" &
       &"  ({total.ctors} constructors)  {total.events} events"
  echo &"  {total.skipped} skipped"
