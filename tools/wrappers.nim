## Emit the API layer from Windows Metadata.
##
## ```
## nimble bindings                       # the whole package
## nim c -r tools/wrappers.nim <winmd> --split <out-dir>
## ```
##
## `generate.nim` emits what the ABI *is*. This emits what a person wants to
## write: `uri.host` rather than a QueryInterface, a vtable field and an
## HSTRING to delete.
##
## ## Shape
##
## `classes.nim` declares the types: every runtime class as an object in a
## real inheritance chain, every shared interface as an object of its own —
## `IInputStream`, the type of a value known only by that interface — and,
## for each shared interface, a type class `SomeInputStream` of everything
## that implements it. Then one module per namespace group carries the
## members:
##
## * a class's constructors, statics, and the methods of the interfaces that
##   exist only for it (`[ExclusiveTo]`), on `self: Uri`;
## * a shared interface's methods once, on `self: SomeInputStream`, so a
##   `StorageFile`, an `InMemoryRandomAccessStream` and an `IInputStream`
##   value all take them, and Nim's overload resolution picks an exact
##   class's method over a type class's where both exist.
##
## ## What a method body is
##
## Narrow the receiver to the interface that declares the method, convert the
## arguments, call the vtable field, check the HRESULT, convert what came
## back. Every conversion is a named plumbing proc generic over the
## *metadata* type — `takeSeq[IVectorViewVtbl[StorageFile]]` — because that is
## what decides the IIDs involved, and every IID is computed by the compiler
## from that spelling. Nothing here is a template, and no GUID is written.

import std/[os, strformat, strutils, tables, sets, algorithm, sequtils]
import ./winmd
import ./foreign
import ./nimgen
import ./piid

const
  tdInterface = 0x20'u32
  Iterable = "Windows.Foundation.Collections.IIterable`1"
  Iterator = "Windows.Foundation.Collections.IIterator`1"
  VectorView = "Windows.Foundation.Collections.IVectorView`1"
  Vector = "Windows.Foundation.Collections.IVector`1"
  ObservableVector = "Windows.Foundation.Collections.IObservableVector`1"
  MapView = "Windows.Foundation.Collections.IMapView`2"
  Map = "Windows.Foundation.Collections.IMap`2"
  ObservableMap = "Windows.Foundation.Collections.IObservableMap`2"
  KeyValuePair = "Windows.Foundation.Collections.IKeyValuePair`2"
  Reference = "Windows.Foundation.IReference`1"
  AsyncAction = "Windows.Foundation.IAsyncAction"
  AsyncActionWithProgress = "Windows.Foundation.IAsyncActionWithProgress`1"
  AsyncOperation = "Windows.Foundation.IAsyncOperation`1"
  AsyncOperationWithProgress = "Windows.Foundation.IAsyncOperationWithProgress`2"
  TypedEventHandler = "Windows.Foundation.TypedEventHandler`2"
  EventHandler = "Windows.Foundation.EventHandler`1"
  Collections = [VectorView, Vector, Iterable, ObservableVector]
  Maps = [MapView, Map, ObservableMap]
  AsyncOps = [AsyncOperation, AsyncOperationWithProgress]
  AsyncActions = [AsyncAction, AsyncActionWithProgress]
  ValueKinds = {skBool, skChar, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8,
                skF4, skF8, skEnum, skStruct}

const typeNames = ["int", "int8", "int16", "int32", "int64", "uint", "uint8",
                   "uint16", "uint32", "uint64", "float", "float32", "float64",
                   "bool", "char", "string", "cstring", "pointer", "byte", "seq",
                   "array", "set", "tuple", "object", "range", "ptr", "ref",
                   "void", "auto", "any", "typedesc", "untyped", "typed",
                   "varargs", "openArray", "Natural", "Positive", "Ordinal",
                   "Option", "Table", "Future", "Hash", "GUID", "HSTRING",
                   "HRESULT", "Char16", "WinRtObject", "WinRtInterface",
                   "Reference", "Interface", "Delegate", "Exception"]
  ## Types a member's camelCase name must not spell. Nim compares identifiers
  ## case-insensitively after the first character, so a static property
  ## `UInt32` would become `uInt32` — the type `uint32`, to Nim — and every
  ## `uint32` in the module would then name that proc.


# ------------------------------------------------------------------ model

type
  Iface = object
    ## A declared interface or delegate: one with an IID of its own.
    full, nim, namespace: string
    index: int
    isDelegate: bool
    exclusiveTo: string          ## the class it exists for, or ""
    factoryFor: string           ## the class whose constructors it holds, or ""
    staticsFor: string           ## the class whose statics it holds, or ""
    composableFor: string        ## the class derived classes compose through
    requires: seq[string]        ## interfaces this one requires
    implementers: seq[string]    ## classes listing it

  Class = object
    full, nim, namespace: string
    index: int
    base: string                 ## a class, or ""
    defaultIface: string         ## declared default interface, or ""
    genericDefault: SigType      ## the default, when it is an instantiation
    interfaces: seq[string]      ## declared interfaces it lists
    statics, factories: seq[string]
    activatable, composable, staticOnly: bool

  Model = object
    md: WinMd
    iids: Table[int, string]
    byName: Table[string, int]
    classes: Table[string, Class]
    ifaces: Table[string, Iface]
    names: Table[string, string]   ## full name -> Nim name, every type
    enums, structs, twinned: HashSet[string]
    aliases: Table[string, string]
    delegateArgs: Table[string, seq[SigType]]
    delegateNames: Table[string, seq[string]]  ## what a delegate calls them
    unions: HashSet[string]        ## interfaces with a `SomeX` type class
    typeIdents: HashSet[string]    ## every type name in scope, as Nim sees it

func shared(i: Iface): bool =
  ## An interface any class may implement, as against one that exists for a
  ## single class, holds a class's statics or constructs it.
  not i.isDelegate and i.exclusiveTo.len == 0 and i.factoryFor.len == 0 and
    i.staticsFor.len == 0 and i.composableFor.len == 0

func unionName(nim: string): string =
  ## `SomeInputStream` for `IInputStream`: Nim's own spelling for a type
  ## class, as in `SomeInteger`.
  "Some" & (if nim.len > 1 and nim[0] == 'I' and nim[1].isUpperAscii: nim[1 .. ^1]
            else: nim)

func boxable(t: SigType): bool =
  t.kind in {skBool, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4, skF8} or
    (t.kind == skStruct and t.name == "System.Guid")

func isReference(t: SigType): bool =
  t.kind == skUnsupported and t.name == Reference and t.args.len == 1

proc buildModel(md: WinMd, iids: Table[int, string]): Model =
  result.md = md
  result.iids = iids
  for (name, nim) in foreignAliases: result.aliases[name] = nim
  for t in md.types: result.byName[t.fullName] = t.index

  # The rule both generators apply to a short name that is already taken:
  # qualify by the namespace's last segment. Enums and interfaces are named
  # here exactly as `generate.nim` named them, in the same order.
  var takenEnums, takenIfaces, takenClasses: HashSet[string]
  let exclusive = md.attributeTypeArgs("ExclusiveToAttribute")
  let statics = md.attributeTypeArgs("StaticAttribute")
  let factories = md.attributeTypeArgs("ActivatableAttribute")
  let composable = md.attributeTypeArgs("ComposableAttribute")
  let attrs = md.attributeNames()
  let impls = md.interfaceImpls()

  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if md.isEnum(t.index):
      if t.fullName in result.aliases or md.enumMembers(t.index).len == 0: continue
      var k = sanitize(t.name)
      if k in takenEnums:
        k = sanitize(t.namespace.split('.')[^1]) & k
        if k in takenEnums: continue
      takenEnums.incl k
      result.enums.incl t.fullName
      result.names[t.fullName] = k
    elif (t.flags and tdInterface) != 0 or md.isDelegate(t.index):
      if '`' in t.name or t.index notin iids: continue
      var k = sanitize(t.name)
      if nimIdent(k) in takenIfaces:
        k = sanitize(t.namespace.split('.')[^1]) & k
        if nimIdent(k) in takenIfaces: continue
      takenIfaces.incl nimIdent(k)
      var i = Iface(full: t.fullName, nim: k, namespace: t.namespace,
                    index: t.index, isDelegate: md.isDelegate(t.index))
      let ex = exclusive.getOrDefault(t.index, @[])
      if ex.len > 0: i.exclusiveTo = ex[0]
      for coded in impls.getOrDefault(t.index, @[]):
        i.requires.add md.typeDefOrRefName(coded)
      result.ifaces[t.fullName] = i
      result.names[t.fullName] = k
      if i.isDelegate:
        let (first, stop) = md.methodRange(t.index)
        for mi in first ..< stop:
          if md.str(md.cell(tMethodDef, mi, "Name")) == "Invoke":
            let invoke = md.methodSignature(mi)
            result.delegateArgs[t.fullName] = invoke.params
            let named = md.paramNames(mi)
            var names: seq[string]
            for k in 0 ..< invoke.params.len:
              names.add (if (k + 1) in named: lowerFirst(sanitize(named[k + 1])) else: "")
            result.delegateNames[t.fullName] = names
    elif md.baseName(t.index) == "":
      # A struct, or a static class. `HResult` is a struct `com` already
      # spells as `HRESULT`.
      if t.fullName in result.aliases: continue
      let (ff, fs) = md.fieldRange(t.index)
      if fs > ff:
        result.structs.incl t.fullName
        result.names[t.fullName] = shortName(t.fullName)
        for fi in ff ..< fs:
          let ft = md.fieldType(fi)
          if ft.kind == skString or (isReference(ft) and boxable(ft.args[0])):
            result.twinned.incl t.fullName
  for (name, _) in foreignStructs:
    if name notin result.structs:
      result.structs.incl name
      result.names[name] = shortName(name)

  # Runtime classes: anything with a base, plus the static classes that have
  # nothing but a `StaticAttribute`.
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if (t.flags and tdInterface) != 0 or md.isEnum(t.index) or
       md.isDelegate(t.index): continue
    let own = impls.getOrDefault(t.index, @[])
    let isStatic = t.index in statics
    if md.baseName(t.index) == "" and own.len == 0 and not isStatic: continue
    var c = Class(full: t.fullName, namespace: t.namespace, index: t.index)
    c.base = md.baseName(t.index)
    if c.base notin result.byName or c.base.startsWith("System."): c.base = ""
    for coded in own:
      let n = md.typeDefOrRefName(coded)
      if n in result.ifaces:
        c.interfaces.add n
        if c.defaultIface.len == 0: c.defaultIface = n
      elif c.defaultIface.len == 0 and c.genericDefault.kind == skVoid:
        let sg = md.typeDefOrRefSig(coded)
        if sg.kind == skUnsupported and sg.args.len > 0: c.genericDefault = sg
    c.statics = statics.getOrDefault(t.index, @[])
    c.factories = factories.getOrDefault(t.index, @[])
    let names = attrs.getOrDefault(t.index, @[])
    var plainActivations = 0
    for n in names:
      if n == "ActivatableAttribute": plainActivations.inc
    # `ActivatableAttribute` with a factory means "constructed through it";
    # without one, "constructible with no arguments". A class can carry both.
    c.activatable = plainActivations > c.factories.len
    c.composable = "ComposableAttribute" in names
    c.staticOnly = c.defaultIface.len == 0 and c.genericDefault.kind == skVoid and
                   c.base.len == 0
    if c.staticOnly and not isStatic: continue
    var k = shortName(t.fullName)
    if nimIdent(k) in takenClasses:
      k = sanitize(t.namespace.split('.')[^1]) & k
      if nimIdent(k) in takenClasses: continue
    takenClasses.incl nimIdent(k)
    c.nim = k
    result.classes[t.fullName] = c
    result.names[t.fullName] = k
    for n in c.statics:
      if n in result.ifaces: result.ifaces[n].staticsFor = t.fullName
    for n in c.factories:
      if n in result.ifaces: result.ifaces[n].factoryFor = t.fullName
    for n in composable.getOrDefault(t.index, @[]):
      if n in result.ifaces: result.ifaces[n].composableFor = t.fullName
  for full, c in result.classes:
    for n in c.interfaces:
      if n in result.ifaces: result.ifaces[n].implementers.add full
  # A class whose name a value type also has would be ambiguous in every
  # module exporting both; the class takes its namespace's last segment.
  var valueNames: HashSet[string]
  for n in result.enums: valueNames.incl nimIdent(result.names[n])
  for n in result.structs: valueNames.incl nimIdent(result.names[n])
  for full, c in result.classes.mpairs:
    if nimIdent(c.nim) in valueNames:
      c.nim = sanitize(c.namespace.split('.')[^1]) & c.nim
      result.names[full] = c.nim
  for full, i in result.ifaces:
    if i.shared and (i.implementers.len > 0 or i.requires.len > 0):
      result.unions.incl full
  # An interface requiring a shared one belongs in its union too, so an
  # `IRandomAccessStream` value passes where an `IInputStream` is wanted.
  var requirers = initTable[string, seq[string]]()
  for full, i in result.ifaces:
    for r in i.requires:
      if r in result.ifaces and result.ifaces[r].shared and i.shared:
        requirers.mgetOrPut(r, @[]).add full
  for full, rs in requirers:
    result.unions.incl full
  for full in result.unions:
    discard requirers.mgetOrPut(full, @[])
  for full, rs in requirers:
    result.ifaces[full].requires = rs      # reused below as "required by"
  for t in typeNames: result.typeIdents.incl nimIdent(t)
  for _, n in result.names: result.typeIdents.incl nimIdent(n)
  for full in result.unions: result.typeIdents.incl nimIdent(unionName(result.ifaces[full].nim))

# ---------------------------------------------------------------- spelling

func classOf(m: Model, ifaceFull: string): string =
  ## The class an exclusive interface stands for, or "".
  if ifaceFull in m.ifaces: m.ifaces[ifaceFull].exclusiveTo else: ""

func isCollection(t: SigType): bool =
  t.kind == skUnsupported and t.name in Collections and t.args.len == 1

func isMap(t: SigType): bool =
  (t.kind == skUnsupported and t.name in Maps and t.args.len == 2) or
    (t.kind == skUnsupported and t.name == Iterable and t.args.len == 1 and
     t.args[0].kind == skUnsupported and t.args[0].name == KeyValuePair)

func mapArgs(t: SigType): seq[SigType] =
  if t.name == Iterable: t.args[0].args else: t.args

func asyncResult(t: SigType): tuple[isAsync, progress: bool, res: SigType] =
  ## Whether `t` is an async operation, whether it reports progress, and
  ## what it produces.
  if t.kind == skInterface and t.name == AsyncAction:
    (true, false, SigType(kind: skVoid))
  elif t.kind == skUnsupported and t.name == AsyncActionWithProgress:
    (true, true, SigType(kind: skVoid))
  elif t.kind == skUnsupported and t.name in AsyncOps and t.args.len >= 1:
    (true, t.name == AsyncOperationWithProgress, t.args[0])
  else:
    (false, false, SigType(kind: skVoid))

const reservedNames = [
  # The receiver, the temporaries a body declares, and every plumbing proc a
  # body calls: a parameter with one of these names would shadow it.
  "self", "it", "result", "op", "ret", "statics", "check", "adopt",
  "borrow", "future", "takeString", "toWinRtString", "asCollection", "asMap",
  "asReference", "asArray", "newDelegate", "borrowValue", "borrowArray",
  "readValue", "takeArray", "takeSeq", "takeTable", "takeReference", "toAbi",
  "fromAbi", "iid", "typeSignature", "activate", "compose", "release",
  "addRef", "raw", "vtbl", "handle", "cb", "shim"].toHashSet

proc namedAfterItsType(m: Model, t: SigType): string =
  ## What to call a parameter the metadata left unnamed: the type, in the
  ## lower case a value of it is written in — `commonFileQuery`, `uri`,
  ## `buffer` for an `IBuffer` — and `input` where the type is a number, a
  ## string or a collection and so names nothing.
  var n = ""
  case t.kind
  of skInterface, skEnum, skStruct:
    if t.name in m.aliases: n = m.aliases[t.name]
    elif t.name in m.names: n = m.names[t.name]
    # `IBuffer` describes a buffer; the `I` is the interface's, not the value's.
    if n.len > 2 and n[0] == 'I' and n[1].isUpperAscii: n = n[1 .. ^1]
  else: discard
  if n.len == 0: "input" else: lowerFirst(n)

proc delegateArgs(m: Model, t: SigType): tuple[found: bool, args: seq[SigType]] =
  ## The `Invoke` arguments of a delegate type, declared or parameterised.
  if t.kind == skInterface and t.name in m.delegateArgs:
    (true, m.delegateArgs[t.name])
  elif t.kind == skUnsupported and t.name == TypedEventHandler and t.args.len == 2:
    (true, t.args)
  elif t.kind == skUnsupported and t.name == EventHandler and t.args.len == 1:
    (true, @[SigType(kind: skObject), t.args[0]])
  else:
    (false, @[])

proc delegateParamNames(m: Model, t: SigType, args: seq[SigType]): seq[string] =
  ## What to call the arguments of the closure a delegate parameter is
  ## written as: the names the delegate gives them — `sender`, `args`,
  ## `operation` — and otherwise their types'.
  let declared = m.delegateNames.getOrDefault(t.name, @[])
  var taken = reservedNames
  for k, a in args:
    var n = if k < declared.len: declared[k] else: ""
    if n.len == 0 or (n.len <= 2 and n.startsWith("a")):
      n = m.namedAfterItsType(a)
    var unique = n
    var i = 2
    while unique in taken:
      unique = n & $i
      i.inc
    taken.incl unique
    result.add escapeIdent(unique)

var usedIfaces: HashSet[string]
  ## The declared interfaces the module being written narrows to, builds a
  ## delegate of, or names as a type argument, so that it imports their ABI
  ## groups — and no others.

proc metaType(m: Model, t: SigType): string
proc apiType(m: Model, t: SigType, param = false): string

proc primitive(t: SigType): string =
  case t.kind
  of skBool: "bool"
  of skChar: "Char16"
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
  else: ""

proc valueType(m: Model, t: SigType): string =
  ## An enum or struct by its Nim name, `GUID` and the other aliases
  ## included, or "".
  if t.kind == skEnum:
    if t.name in m.enums: m.names[t.name] else: "int32"
  elif t.kind == skStruct:
    if t.name in m.aliases: m.aliases[t.name]
    elif t.name in m.structs: m.names[t.name]
    else: ""
  else: primitive(t)

proc metaType(m: Model, t: SigType): string =
  ## A type as the plumbing is told it: the API's name for a value, a class or
  ## an interface, and the ABI's generic vtable for an instantiation —
  ## `IVectorViewVtbl[StorageFile]` — because that is what fixes its IID.
  case t.kind
  of skObject: "WinRtObject"
  of skInterface:
    if t.name in m.classes: m.names[t.name]
    elif t.name in m.ifaces:
      let i = m.ifaces[t.name]
      if i.exclusiveTo.len > 0 and i.exclusiveTo in m.classes: m.names[i.exclusiveTo]
      elif i.isDelegate or i.shared:
        usedIfaces.incl t.name    # its IID is read where this is instantiated
        if i.isDelegate: i.nim & "Vtbl" else: i.nim
      else: "WinRtObject"
    else: ""
  of skUnsupported:
    if t.name.len == 0 or t.args.len == 0: return ""
    var args: seq[string]
    for a in t.args:
      let s = m.metaType(a)
      if s.len == 0: return ""
      args.add s
    let generic = shortName(t.name.split('`')[0])
    generic & "Vtbl[" & args.join(", ") & "]"
  else: m.valueType(t)

proc apiType(m: Model, t: SigType, param = false): string =
  ## A type as a person sees it: what a parameter or a result is spelled as.
  ## `param` widens a shared interface to its `Some` type class.
  case t.kind
  of skObject: "WinRtObject"
  of skInterface:
    if t.name in m.classes: m.names[t.name]
    elif t.name in m.ifaces:
      let i = m.ifaces[t.name]
      if i.exclusiveTo.len > 0 and i.exclusiveTo in m.classes: m.names[i.exclusiveTo]
      elif i.isDelegate:
        if param:
          let (_, args) = m.delegateArgs(t)
          let names = m.delegateParamNames(t, args)
          var parts: seq[string]
          for k, a in args:
            let s = m.apiType(a)
            if s.len == 0: return ""
            parts.add &"{names[k]}: {s}"
          "proc(" & parts.join(", ") & ")"
        else: i.nim
      elif i.shared:
        if param and t.name in m.unions: unionName(i.nim) else: i.nim
      else: "WinRtObject"
    else: ""
  of skUnsupported:
    if isMap(t):
      let ka = mapArgs(t)
      let k = m.apiType(ka[0])
      let v = m.apiType(ka[1])
      if k.len == 0 or v.len == 0: "" else: &"Table[{k}, {v}]"
    elif isCollection(t):
      let e = m.apiType(t.args[0])
      if e.len == 0: "" else: &"seq[{e}]"
    elif isReference(t):
      let e = m.apiType(t.args[0])
      if e.len == 0: "" else: &"Option[{e}]"
    elif t.name == KeyValuePair and t.args.len == 2:
      let k = m.apiType(t.args[0])
      let v = m.apiType(t.args[1])
      if k.len == 0 or v.len == 0: "" else: &"tuple[key: {k}, value: {v}]"
    elif param and (t.name == TypedEventHandler or t.name == EventHandler):
      let (_, args) = m.delegateArgs(t)
      let s = m.apiType(args[0])
      let a = m.apiType(args[1])
      if s.len == 0 or a.len == 0: "" else: &"proc(sender: {s}, args: {a})"
    elif t.name.len > 0 and t.args.len > 0: "WinRtObject"
    else: ""
  of skArray:
    if t.args.len != 1: return ""
    let e = m.apiType(t.args[0])
    if e.len == 0: ""
    elif param and not t.byRef: &"openArray[{e}]"
    else: &"seq[{e}]"
  else: m.valueType(t)

proc abiType(m: Model, t: SigType): string =
  ## A type as it crosses in a delegate's `Invoke`.
  case t.kind
  of skObject, skInterface, skUnsupported: "pointer"
  of skString: "HSTRING"
  of skStruct:
    if t.name in m.twinned: m.names[t.name] & "Abi" else: m.valueType(t)
  else: m.valueType(t)

func isPlain(m: Model, t: SigType): bool =
  ## A value that needs no conversion between the API and the ABI.
  t.kind in ValueKinds and not (t.kind == skStruct and t.name in m.twinned)

proc readExpr(m: Model, t: SigType, name: string): string =
  ## What `name`, holding the ABI form of a `t` that is ours, reads as.
  ##
  ## Each conversion is named outright rather than left to one dispatcher,
  ## so the line says what happens, and each is given both the type on the
  ## wire and the Nim type it becomes.
  if m.isPlain(t): name
  elif t.kind == skString: &"takeString({name})"
  elif t.kind in {skInterface, skObject} and m.apiType(t).len > 0:
    &"adopt[{m.apiType(t)}]({name})"
  elif t.kind == skStruct and t.name in m.twinned: &"fromAbi({name})"
  elif isReference(t): &"takeReference[{m.apiType(t.args[0])}]({name})"
  elif isMap(t): &"takeTable[{m.metaType(t)}, {m.apiType(t)}]({name})"
  elif isCollection(t): &"takeSeq[{m.metaType(t)}, {m.apiType(t)}]({name})"
  else:
    &"readValue[{m.metaType(t)}, {m.apiType(t)}, {m.abiType(t)}]({name})"

proc borrowExpr(m: Model, t: SigType, name: string): string =
  ## The same for a value we were only lent, which a delegate's arguments
  ## are: nothing here takes a reference or a handle away from the caller.
  if m.isPlain(t): name
  elif t.kind == skString: &"${name}"
  elif t.kind in {skInterface, skObject} and m.apiType(t).len > 0:
    &"borrow[{m.apiType(t)}]({name})"
  elif t.kind == skStruct and t.name in m.twinned: &"fromAbi({name})"
  elif isReference(t): &"readReference[{m.apiType(t.args[0])}]({name})"
  elif isMap(t): &"borrowTable[{m.metaType(t)}, {m.apiType(t)}]({name})"
  elif isCollection(t): &"borrowSeq[{m.metaType(t)}, {m.apiType(t)}]({name})"
  else:
    &"borrowValue[{m.metaType(t)}, {m.apiType(t)}, {m.abiType(t)}]({name})"

proc narrowVtbl(m: Model, t: SigType): string =
  ## The vtable an object argument of type `t` is narrowed to before it is
  ## passed: the interface itself, or a class's default interface.
  if t.kind == skInterface and t.name in m.ifaces:
    usedIfaces.incl t.name
    m.ifaces[t.name].nim & "Vtbl"
  elif t.kind == skInterface and t.name in m.classes:
    let c = m.classes[t.name]
    if c.defaultIface.len > 0:
      usedIfaces.incl c.defaultIface
      m.ifaces[c.defaultIface].nim & "Vtbl"
    elif c.genericDefault.kind != skVoid: m.metaType(c.genericDefault)
    else: ""
  else: ""

proc shimArgs(m: Model, dargs: seq[SigType]): tuple[formal, actual: seq[string], ok: bool] =
  ## A delegate's `Invoke` arguments as the closure handed to `newDelegate`
  ## takes them — at the ABI — and as the caller's closure is called with
  ## them. An array is two ABI arguments, a count and a pointer.
  for k, a in dargs:
    if a.kind == skArray:
      if a.args.len != 1 or m.metaType(a.args[0]).len == 0: return
      result.formal.add &"a{k}Size: uint32"
      result.formal.add &"a{k}: ptr {m.abiType(a.args[0])}"
      result.actual.add &"borrowArray[{m.metaType(a.args[0])}, " &
                        &"seq[{m.apiType(a.args[0])}]](a{k}Size, a{k})"
    else:
      let mt = m.metaType(a)
      if mt.len == 0 or m.apiType(a).len == 0: return
      result.formal.add &"a{k}: {m.abiType(a)}"
      result.actual.add m.borrowExpr(a, &"a{k}")
  result.ok = result.formal.len <= 3    # what `delegate` has trampolines for

# --------------------------------------------------------------- emission

type
  Receiver = object
    ## Who a method is emitted for.
    recv: string     ## the first parameter as written: `self: Uri`
    what: string     ## the prefix of a failure message: `Uri`
    isStatic: bool

  Emission = tuple
    classes, interfaces, procs, ctors, events, skipped: int

proc memberName(m: Model, raw: string): string =
  ## `GetFileAsync` -> `getFileAsync`. A name that would be a type's is left
  ## as the metadata spells it, `UInt32`, which differs in the one character
  ## Nim is case-sensitive about; where that is a type too — `Pointer`, the
  ## property, on `PointerRoutedEventArgs` — it becomes `getPointer`.
  let camel = lowerFirst(sanitize(raw))
  if nimIdent(camel) notin m.typeIdents: return escapeIdent(camel)
  let pascal = sanitize(raw)
  if nimIdent(pascal) notin m.typeIdents: return escapeIdent(pascal)
  escapeIdent("get" & pascal)

proc argumentNames(m: Model, mi: int, params: seq[SigType],
                   resultField = ""): seq[string] =
  ## The metadata names the parameters — `lampIndex`, `desiredColor` — and
  ## using those is the difference between a signature you can read and one
  ## you have to look up. Where it leaves one unnamed, the type names it.
  ##
  ## An out-parameter's name is also a field of the tuple the method returns,
  ## so where the declared return takes a field of its own, `resultField`
  ## names it and no parameter may have it.
  let named = m.md.paramNames(mi)
  var taken = reservedNames
  if resultField.len > 0: taken.incl resultField
  for i, p in params:
    var n = ""
    if (i + 1) in named: n = lowerFirst(sanitize(named[i + 1]))
    # `a0`, `a1`: what a body calls the argument it converted.
    if n.len == 0 or (n.len <= 2 and n.startsWith("a")):
      n = m.namedAfterItsType(p)
    var unique = n
    var k = 2
    while unique in taken:
      unique = n & $k
      k.inc
    taken.incl unique
    result.add escapeIdent(unique)

type Body = object
  ## A method body under construction.
  lines: seq[string]      ## before the call
  args: seq[string]       ## what the vtable field is called with
  outs: seq[(string, string)]  ## (name, expression) of each out-parameter
  ok: bool

proc pass(m: Model, b: var Body, p: SigType, name: string, i: int, isOut: bool) =
  ## Convert one argument and add it to the call.
  if p.kind == skArray:
    if p.args.len != 1 or m.metaType(p.args[0]).len == 0:
      b.ok = false
      return
    let e = p.args[0]
    if p.byRef:
      # A receive array: the callee allocates, so the count and the buffer
      # both come back and both are ours.
      b.lines.add &"  var {name}Size: uint32"
      b.lines.add &"  var {name}Buf: ptr {m.abiType(e)}"
      b.args.add &"{name}Size.addr"
      b.args.add &"{name}Buf.addr"
      b.outs.add (name, &"takeArray[{m.metaType(e)}, seq[{m.apiType(e)}]]" &
                        &"({name}Size, {name}Buf)")
    else:
      b.lines.add &"  let a{i} = asArray[{m.metaType(e)}, {m.apiType(e)}]({name})"
      b.args.add &"a{i}.count"
      b.args.add &"a{i}.data"
    return
  if p.byRef:
    if isOut:
      # A local the call writes into; its value leaves in the tuple.
      var bare = p
      bare.byRef = false
      if m.apiType(bare).len == 0:
        b.ok = false
        return
      b.lines.add &"  var {name}: {m.abiType(bare)}"
      b.args.add &"{name}.addr"
      b.outs.add (name, m.readExpr(bare, name))
    else:
      # A by-reference input: the callee wants an address, and a parameter
      # is immutable, so it is copied first.
      b.lines.add &"  var by{i} = {name}"
      b.args.add &"by{i}.addr"
    return
  case p.kind
  of skString:
    b.lines.add &"  let a{i} = toWinRtString({name})"
    b.args.add &"a{i}.handle"
  of skObject:
    # An `IInspectable` argument is borrowed for the length of the call: the
    # callee retains it if it keeps it.
    b.args.add &"{name}.raw"
  of skInterface:
    let (isDelegate, dargs) = m.delegateArgs(p)
    if isDelegate:
      # The caller wrote a closure over Nim types; the runtime needs a COM
      # object whose `Invoke` has the delegate's exact C signature, so the
      # closure handed over is typed at the ABI and converts on the way.
      let (formal, actual, ok) = m.shimArgs(dargs)
      if not ok:
        b.ok = false
        return
      usedIfaces.incl p.name
      let vtbl = m.ifaces[p.name].nim & "Vtbl"
      if dargs.len == 0:
        b.lines.add fill(&"  let d{i} = newDelegate(", @[vtbl, name], ")")
      else:
        b.lines.add fill(&"  proc shim{i}(", formal, ") =")
        b.lines.add fill(&"    {name}(", actual, ")")
        b.lines.add fill(&"  let d{i} = newDelegate(", @[vtbl, &"shim{i}"], ")")
      b.args.add &"d{i}.raw"
      return
    let vtbl = m.narrowVtbl(p)
    if vtbl.len == 0:
      b.ok = false
      return
    b.lines.add &"  let a{i} = queryInterface[{vtbl}]({name})"
    b.args.add &"a{i}.raw"
  of skUnsupported:
    let (isGenericDelegate, gargs) = m.delegateArgs(p)
    if isGenericDelegate:
      let (formal, actual, ok) = m.shimArgs(gargs)
      if not ok:
        b.ok = false
        return
      let vtbl = m.metaType(p)
      b.lines.add fill(&"  proc shim{i}(", formal, ") =")
      b.lines.add fill(&"    {name}(", actual, ")")
      b.lines.add fill(&"  let d{i} = newDelegate(", @[vtbl, &"shim{i}"], ")")
      b.args.add &"d{i}.raw"
      return
    let mt = m.metaType(p)
    if mt.len == 0 or m.apiType(p, param = true).len == 0:
      b.ok = false
      return
    if isReference(p):
      b.lines.add &"  let a{i} = asReference[{m.metaType(p.args[0])}]({name})"
    elif isMap(p):
      let ka = mapArgs(p)
      b.lines.add fill(&"  let a{i} = asMap[",
                       @[m.metaType(ka[0]), m.metaType(ka[1]),
                         &"Table[{m.apiType(ka[0])}, {m.apiType(ka[1])}]"],
                       &"]({name})")
    elif isCollection(p):
      b.lines.add fill(&"  let a{i} = asCollection[",
                       @[m.metaType(p.args[0]), &"seq[{m.apiType(p.args[0])}]"],
                       &"]({name})")
    else:
      # Another interface pointer — an operation, a handler — passed as the
      # `IInspectable` it is.
      b.args.add &"{name}.raw"
      return
    b.args.add &"a{i}.raw"
  of skStruct:
    if p.name in m.twinned:
      b.lines.add &"  let a{i} = toAbi({name})"
      b.args.add &"a{i}"
    else:
      b.args.add name
  else:
    b.args.add name

proc emitMethod(m: Model, buf: var string, iface: Iface, mi: int, r: Receiver,
                enter: string, emitted: var HashSet[string],
                stats: var Emission, skips: var CountTable[string],
                field: string): bool =
  ## One method, property accessor or event, on the receiver `r`, entered
  ## with `enter` — the line that narrows `self` to `iface`. Returns whether
  ## something was written.
  let md = m.md
  let raw = md.str(md.cell(tMethodDef, mi, "Name"))
  let sig = md.methodSignature(mi)
  let flags = md.paramFlags(mi)
  let isGet = raw.startsWith("get_") and sig.params.len == 0
  let isPut = raw.startsWith("put_") and sig.params.len == 1
  let isAdd = raw.startsWith("add_")
  let isRemove = raw.startsWith("remove_")
  let what = r.what & "." & (if isGet or isPut or isAdd or isRemove:
                              lowerFirst(sanitize(raw[raw.find('_') + 1 .. ^1]))
                            else: lowerFirst(sanitize(raw)))

  if isRemove:
    # The second half of an event: emitted with its `add_`.
    return false
  if isAdd:
    # An event is a pair: `add_X(handler) -> token` and `remove_X(token)`.
    # The handler's shape comes from the delegate's own `Invoke`, so the
    # generated proc can take a properly typed Nim closure.
    if sig.params.len != 1: return false
    let h = sig.params[0]
    let (isDelegate, dargs) = m.delegateArgs(h)
    let closure = m.apiType(h, param = true)
    if not isDelegate or closure.len == 0:
      skips.inc "an event whose handler has no spelling"
      stats.skipped.inc
      return false
    let evName = sanitize(raw[4 .. ^1])
    let key = &"on{evName}/{r.recv}"
    if key in emitted: return false
    emitted.incl key
    let (formal, actual, ok) = m.shimArgs(dargs)
    if not ok:
      skips.inc "an event whose handler has no spelling"
      stats.skipped.inc
      return false
    if h.kind == skInterface: usedIfaces.incl h.name
    let vtbl = m.metaType(h)
    buf.add fill(&"proc on{evName}*(", @[r.recv, &"handler: {closure}"],
                 "): EventRegistrationToken {.discardable.} =") & "\n"
    buf.add &"  ## {iface.full}.{raw}\n"
    buf.add &"  ## The token is what `remove{evName}` takes.\n"
    buf.add enter & "\n"
    if dargs.len == 0:
      buf.add fill("  let cb = newDelegate(", @[vtbl, "handler", "event = true"], ")") & "\n"
    else:
      buf.add fill("  proc shim(", formal, ") =") & "\n"
      buf.add fill("    handler(", actual, ")") & "\n"
      buf.add fill("  let cb = newDelegate(", @[vtbl, "shim", "event = true"], ")") & "\n"
    buf.add fill(&"  check it.vtbl.{field}(", @["it.raw", "cb.raw", "result.addr"],
                 &"), \"{what}\"") & "\n\n"
    # `remove_X` follows `add_X` in the metadata, and shares its field name.
    let removeField = "remove_" & raw[4 .. ^1]
    buf.add fill(&"proc remove{evName}*(", @[r.recv, "token: EventRegistrationToken"],
                 ") =") & "\n"
    buf.add &"  ## {iface.full}.{removeField}\n"
    buf.add enter & "\n"
    buf.add fill(&"  check it.vtbl.{escapeIdent(sanitize(removeField))}(",
                 @["it.raw", "token"], &"), \"{what}\"") & "\n\n"
    stats.events.inc
    return true

  # Inputs and out-parameters. An out-parameter comes back in a tuple beside
  # the declared return.
  var body = Body(ok: true)
  var params = @[r.recv]
  # A method with both a declared return and out-parameters returns a tuple:
  # `ok` where the return is the success of a `TryX`, `value` otherwise.
  var resultField = ""
  if sig.returns.kind != skVoid:
    for i, p in sig.params:
      if p.byRef and (flags.getOrDefault(i + 1, 0) and paramOut) != 0:
        resultField = if sig.returns.kind == skBool: "ok" else: "value"
        break
  let names = m.argumentNames(mi, sig.params, resultField)
  var argTypes: seq[string]
  for i, p in sig.params:
    let isOut = p.byRef and (flags.getOrDefault(i + 1, 0) and paramOut) != 0
    if not isOut:
      var bare = p
      bare.byRef = false
      let s = m.apiType(bare, param = true)
      if s.len == 0:
        skips.inc "a parameter with no spelling"
        stats.skipped.inc
        return false
      params.add (if isPut: "value: " & s else: &"{names[i]}: {s}")
      argTypes.add s
    m.pass(body, p, (if isPut: "value" else: names[i]), i, isOut)
    if not body.ok:
      skips.inc "an argument with no conversion"
      stats.skipped.inc
      return false

  # The result.
  let async = asyncResult(sig.returns)
  var ret = ""            # the declared return's Nim type
  var resultExpr = ""
  if async.isAsync:
    # The operation's vtable: `IAsyncActionVtbl` for the one declared
    # operation, the generic instantiation for the rest.
    let op = if sig.returns.kind == skInterface: "IAsyncActionVtbl"
             else: m.metaType(sig.returns)
    let res = if async.res.kind == skVoid: "void" else: m.apiType(async.res)
    if op.len == 0 or res.len == 0:
      skips.inc "an operation with no spelling"
      stats.skipped.inc
      return false
    if body.outs.len > 0:
      skips.inc "an out-parameter beside an operation"
      stats.skipped.inc
      return false
    ret = &"Future[{res}]"
    body.lines.add "  var op: pointer"
    body.args.add "op.addr"
    if async.progress:
      let pt = m.apiType(sig.returns.args[^1])
      if pt.len == 0:
        skips.inc "a progress value with no spelling"
        stats.skipped.inc
        return false
      params.add &"progress: proc(value: {pt}) = nil"
      resultExpr = fill(&"future[", @[op, res, pt],
                        &"](op, \"{what}\", progress)")
    else:
      resultExpr = fill(&"future[", @[op, res], &"](op, \"{what}\")")
  elif sig.returns.kind == skArray:
    if sig.returns.args.len != 1 or m.metaType(sig.returns.args[0]).len == 0:
      skips.inc "a returned array with no spelling"
      stats.skipped.inc
      return false
    let e = sig.returns.args[0]
    ret = m.apiType(sig.returns)
    body.lines.add "  var retSize: uint32"
    body.lines.add &"  var ret: ptr {m.abiType(e)}"
    body.args.add "retSize.addr"
    body.args.add "ret.addr"
    resultExpr = &"takeArray[{m.metaType(e)}, seq[{m.apiType(e)}]](retSize, ret)"
  elif sig.returns.kind != skVoid:
    ret = m.apiType(sig.returns)
    if ret.len == 0:
      skips.inc "a result with no spelling"
      stats.skipped.inc
      return false
    body.lines.add &"  var ret: {m.abiType(sig.returns)}"
    body.args.add "ret.addr"
    resultExpr = m.readExpr(sig.returns, "ret")

  # An out-parameter is a result: the only one becomes the result itself, and
  # several come back as a tuple, with `value` for the declared return.
  var retType = ret
  if body.outs.len > 0:
    var outTypes: seq[string]
    for i, p in sig.params:
      if p.byRef and (flags.getOrDefault(i + 1, 0) and paramOut) != 0:
        var bare = p
        bare.byRef = false
        outTypes.add m.apiType(bare)
    if ret.len == 0 and body.outs.len == 1:
      retType = outTypes[0]
      resultExpr = body.outs[0][1]
    else:
      var fields, exprs: seq[string]
      if ret.len > 0:
        fields.add &"{resultField}: {ret}"
        exprs.add &"{resultField}: " & resultExpr
      for k, (n, e) in body.outs:
        fields.add &"{n}: {outTypes[k]}"
        exprs.add &"{n}: {e}"
      retType = "tuple[" & fields.join(", ") & "]"
      resultExpr = "(" & exprs.join(", ") & ")"

  # The Nim name, and the overload key that keeps a method reached through
  # two interfaces from being emitted twice.
  let bare = if isGet or isPut: m.memberName(raw[4 .. ^1]) else: m.memberName(raw)
  let name = if isPut: "`" & bare.strip(chars = {'`'}) & "=`" else: bare
  let key = name & "/" & r.recv & "/" & argTypes.join(",")
  if key in emitted: return false
  emitted.incl key

  let head = fill(&"proc {name}*(", params,
                  (if retType.len > 0: &"): {retType} =" else: ") ="))
  buf.add head & "\n"
  buf.add &"  ## {iface.full}.{raw}\n"
  buf.add enter & "\n"
  for l in body.lines: buf.add l & "\n"
  buf.add fill(&"  check it.vtbl.{field}(", @["it.raw"] & body.args,
               &"), \"{what}\"") & "\n"
  if resultExpr.len > 0:
    buf.add "  " & resultExpr & "\n"
  buf.add "\n"
  stats.procs.inc
  true

proc fieldNames(md: WinMd, ifaceIndex: int): Table[int, string] =
  ## Method row -> the vtable field `generate.nim` gave it, keyed as it keys
  ## them so a second overload gets the same suffix here that it got there.
  let (first, stop) = md.methodRange(ifaceIndex)
  var seen = initCountTable[string]()
  for mi in first ..< stop:
    let raw = md.str(md.cell(tMethodDef, mi, "Name"))
    if raw == ".ctor": continue
    seen.inc nimIdent(sanitize(raw))
    let dup = seen[nimIdent(sanitize(raw))]
    result[mi] = escapeIdent(sanitize(raw) & (if dup > 1: $dup else: ""))

proc emitInterface(m: Model, buf: var string, iface: Iface, r: Receiver,
                   enter: string, emitted: var HashSet[string],
                   stats: var Emission, skips: var CountTable[string]) =
  ## Every method of `iface`, on the receiver `r`.
  let md = m.md
  let fields = fieldNames(md, iface.index)
  let (first, stop) = md.methodRange(iface.index)
  for mi in first ..< stop:
    if mi notin fields: continue
    discard m.emitMethod(buf, iface, mi, r, enter, emitted, stats, skips, fields[mi])

proc emitConstructors(m: Model, buf: var string, c: Class,
                      stats: var Emission, skips: var CountTable[string]) =
  ## `newX()` for a class that activates, and `newX(args)` for each factory
  ## method, or `X.createFoo(args)` where two factory methods would collide.
  let md = m.md
  if c.activatable and (c.defaultIface.len > 0 or c.genericDefault.kind != skVoid):
    buf.add &"proc new{c.nim}*(): {c.nim} =\n"
    buf.add &"  ## A `{c.full}`.\n"
    buf.add &"  activate[{c.nim}]()\n\n"
    stats.ctors.inc
  elif c.composable and c.factories.len == 0 and c.defaultIface.len > 0:
    # A composable class refuses RoActivateInstance and is built through a
    # composition factory's `CreateInstance(outer, inner)`, where one of its
    # factories has that method with no arguments of its own.
    for _, f in m.ifaces:
      if f.composableFor != c.full: continue
      let (first, stop) = md.methodRange(f.index)
      var found = false
      for mi in first ..< stop:
        if md.str(md.cell(tMethodDef, mi, "Name")) == "CreateInstance" and
           md.methodSignature(mi).params.len == 2:
          found = true
      if not found: continue
      buf.add &"proc new{c.nim}*(): {c.nim} =\n"
      buf.add &"  ## A `{c.full}`.\n"
      buf.add &"  compose[{f.nim}Vtbl, {c.nim}]()\n\n"
      usedIfaces.incl f.full
      stats.ctors.inc
      break
  # Factory methods: constructors with arguments. Two with the same argument
  # types cannot both be `newX`, so those keep their own names.
  var arities = initCountTable[string]()
  for f in c.factories:
    if f notin m.ifaces: continue
    let (first, stop) = md.methodRange(m.ifaces[f].index)
    for mi in first ..< stop:
      let sig = md.methodSignature(mi)
      var types: seq[string]
      for p in sig.params: types.add m.apiType(p, param = true)
      arities.inc types.join(",")
  for f in c.factories:
    if f notin m.ifaces: continue
    let iface = m.ifaces[f]
    let fields = fieldNames(md, iface.index)
    let (first, stop) = md.methodRange(iface.index)
    var emitted: HashSet[string]
    for mi in first ..< stop:
      if mi notin fields: continue
      let raw = md.str(md.cell(tMethodDef, mi, "Name"))
      let sig = md.methodSignature(mi)
      var params, types: seq[string]
      var body = Body(ok: true)
      let names = m.argumentNames(mi, sig.params)
      for i, p in sig.params:
        let s = m.apiType(p, param = true)
        if s.len == 0 or p.byRef:
          body.ok = false
          break
        params.add &"{names[i]}: {s}"
        types.add s
        m.pass(body, p, names[i], i, false)
      if not body.ok:
        skips.inc "a constructor argument with no spelling"
        stats.skipped.inc
        echo &"    skipped constructor {c.full}.{raw}"
        continue
      let asNew = arities[types.join(",")] == 1
      let name = if asNew: &"new{c.nim}" else: m.memberName(raw)
      let key = name & "/" & types.join(",")
      if key in emitted: continue
      emitted.incl key
      let head = if asNew: fill(&"proc {name}*(", params, &"): {c.nim} =")
                 else: fill(&"proc {name}*(", @[&"_: typedesc[{c.nim}]"] & params,
                            &"): {c.nim} =")
      buf.add head & "\n"
      buf.add &"  ## {iface.full}.{raw}\n"
      buf.add &"  let it = statics[{iface.nim}Vtbl](className({c.nim}))\n"
      for l in body.lines: buf.add l & "\n"
      buf.add "  var ret: pointer\n"
      buf.add fill(&"  check it.vtbl.{fields[mi]}(", @["it.raw"] & body.args & "ret.addr",
                   &"), \"{c.nim}.new\"") & "\n"
      buf.add &"  adopt[{c.nim}](ret)\n\n"
      stats.ctors.inc

# --------------------------------------------------------------- modules

proc header(buf: var string, winmdPath, what: string, lines: openArray[string]) =
  buf.add "## Generated by tools/wrappers.nim - do not edit.\n##\n"
  buf.add &"## Source: {winmdPath.extractFilename}\n"
  buf.add &"## {what}\n##\n"
  for l in lines: buf.add "## " & l & "\n"
  buf.add "\n"

proc emitClasses(m: Model, winmdPath, outPath: string): Emission =
  ## `classes.nim`: every class, every shared interface and delegate as an
  ## object, the `Some` type class of each shared interface, and the
  ## constants `className(T)` and `defaultIid(T)` read.
  var buf = newStringOfCap(1 shl 20)
  header(buf, winmdPath, "Every class and interface as a Nim type.", [
    "A class is an object one pointer wide in a real inheritance chain, so a",
    "derived value passes where a base is expected. An interface is an object",
    "too — `IInputStream` is a value known only by that interface — and",
    "`SomeInputStream` is everything that implements it: the classes listing",
    "it, the interfaces requiring it, and `IInputStream` itself. A method of",
    "a shared interface is written once, over that type class."])
  buf.add "import ../winrt\nexport winrt\n\n"

  var byDepth: seq[(int, Class)]
  proc depth(c: Class): int =
    var cur = c.base
    while cur.len > 0 and cur in m.classes:
      result.inc
      cur = m.classes[cur].base
  for _, c in m.classes: byDepth.add (depth(c), c)
  byDepth.sort(proc (a, b: (int, Class)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmp(a[1].nim, b[1].nim))

  buf.add "type\n"
  for (_, c) in byDepth:
    if c.staticOnly:
      # Never constructed, never held: it exists so that `PowerManager.x`
      # resolves. No pointer, so no reference counting either.
      buf.add &"  {c.nim}* = object\n"
    elif c.base.len > 0 and c.base in m.classes:
      buf.add &"  {c.nim}* = object of {m.names[c.base]}\n"
    else:
      buf.add &"  {c.nim}* = object of WinRtObject\n"
    result.classes.inc
  buf.add "\n"
  var shared: seq[Iface]
  for _, i in m.ifaces:
    if i.shared or i.isDelegate: shared.add i
  shared.sort(proc (a, b: Iface): int = cmp(a.nim, b.nim))
  for i in shared:
    let base = if i.isDelegate: "WinRtDelegate" else: "WinRtInterface"
    buf.add &"  {i.nim}* = object of {base}\n"
    result.interfaces.inc
  buf.add "\n"
  for i in shared:
    if i.full notin m.unions: continue
    var members = @[i.nim]
    for r in i.requires: members.add m.ifaces[r].nim
    for c in i.implementers: members.add m.names[c]
    members = members.deduplicate
    members.sort()
    buf.add fill(&"  {unionName(i.nim)}* = ", members.mapIt(it), "", width = 80)
      .replace(",", " |") & "\n"
  buf.add "\n"

  # What a class is called in the metadata and which interface is its
  # default: the constants `className(T)` and `defaultIid(T)` read, and so
  # `typeSignature(T)` and `activate[T]()`. A class whose default is an
  # instantiation — `IVector<Block>` — has that instantiation's IID, hashed
  # from its signature here exactly as `iid(IVectorVtbl[Block])` would hash
  # it at compile time.
  var context = SigContext(guidOf: m.iids, indexOf: m.byName, md: m.md)
  for full, c in m.classes:
    if c.defaultIface.len > 0: context.defaultIface[full] = c.defaultIface
    elif c.genericDefault.kind != skVoid: context.paramDefault[full] = c.genericDefault
  var sorted: seq[Class]
  for _, c in m.classes: sorted.add c
  sorted.sort(proc (a, b: Class): int = cmp(a.nim, b.nim))
  buf.add "const\n"
  for c in sorted:
    buf.add &"  ClassName_{c.nim}* = \"{c.full}\"\n"
  buf.add "\n"
  buf.add "const\n"
  for c in sorted:
    var iid = ""
    if c.defaultIface.len > 0: iid = m.iids[m.ifaces[c.defaultIface].index]
    elif c.genericDefault.kind != skVoid: iid = context.parameterizedIid(c.genericDefault)
    if iid.len == 0: continue
    buf.add &"  DefaultIid_{c.nim}* = {guidLiteral(iid)}\n"
  writeFile(outPath, buf)

proc emitGroup(m: Model, winmdPath, prefix, outPath: string): Emission =
  ## One namespace group's members: each class's constructors, statics and
  ## exclusive interfaces, then each shared interface once.
  proc owned(ns: string): bool = ns == prefix or ns.startsWith(prefix & ".")
  var buf = newStringOfCap(4 shl 20)
  header(buf, winmdPath, &"Namespace: {prefix}", [
    "A class's constructors, statics and own methods are written on the",
    "class; a shared interface's methods are written once, over the type",
    "class of everything that implements it. Every call narrows the object to",
    "the interface that declares the method, and every conversion is named."])
  buf.add "import ../winrt\nimport ./classes\n"
  buf.add "##<abi-imports>##\n"
  if prefix != "Windows.Foundation":
    buf.add "import ./foundation\nexport foundation\n"
  buf.add "\n"
  var skips = initCountTable[string]()
  var usedAbi: HashSet[string]
  proc use(iface: Iface) = usedAbi.incl moduleName(topGroup(iface.namespace))
  usedIfaces.clear()

  var classes: seq[Class]
  for _, c in m.classes:
    if owned(c.namespace): classes.add c
  classes.sort(proc (a, b: Class): int = cmp(a.nim, b.nim))
  var emitted: HashSet[string]
  for c in classes:
    buf.add &"# ---- {c.full}\n\n"
    var before = buf.len
    m.emitConstructors(buf, c, result, skips)
    for f in c.factories:
      if f in m.ifaces: use(m.ifaces[f])
    for s in c.statics:
      if s notin m.ifaces: continue
      let iface = m.ifaces[s]
      use(iface)
      let enter = &"  let it = statics[{iface.nim}Vtbl](className({c.nim}))"
      m.emitInterface(buf, iface, Receiver(recv: &"_: typedesc[{c.nim}]", what: c.nim,
                                           isStatic: true), enter, emitted, result, skips)
    for n in c.interfaces:
      let iface = m.ifaces[n]
      if iface.exclusiveTo != c.full: continue
      use(iface)
      let enter = &"  let it = queryInterface[{iface.nim}Vtbl](self)"
      m.emitInterface(buf, iface, Receiver(recv: &"self: {c.nim}", what: c.nim),
                      enter, emitted, result, skips)
    if buf.len == before:
      buf.setLen(before - (&"# ---- {c.full}\n\n").len)   # nothing to say

  var shared: seq[Iface]
  for _, i in m.ifaces:
    if owned(i.namespace) and (i.shared or i.isDelegate): shared.add i
  shared.sort(proc (a, b: Iface): int = cmp(a.nim, b.nim))
  for iface in shared:
    use(iface)
    let recv = if iface.full in m.unions: unionName(iface.nim) else: iface.nim
    buf.add &"# ---- {iface.full}\n\n"
    let enter = &"  let it = queryInterface[{iface.nim}Vtbl](self)"
    m.emitInterface(buf, iface, Receiver(recv: &"self: {recv}", what: iface.nim),
                    enter, emitted, result, skips)

  # Two shared interfaces of one class may declare the same method; the
  # class gets its own, so that a call on the class is not ambiguous.
  var owners = initTable[string, seq[string]]()
  for _, i in m.ifaces:
    if not i.shared: continue
    let (first, stop) = m.md.methodRange(i.index)
    for mi in first ..< stop:
      let raw = m.md.str(m.md.cell(tMethodDef, mi, "Name"))
      let sig = m.md.methodSignature(mi)
      var key = m.memberName(raw)
      for p in sig.params: key.add "/" & m.apiType(p, param = true)
      for c in i.implementers:
        owners.mgetOrPut(c & "|" & key, @[]).add i.full
  for c in classes:
    var done: HashSet[string]
    for ck, ifaces in owners:
      if not ck.startsWith(c.full & "|") or ifaces.deduplicate.len < 2: continue
      let iface = m.ifaces[ifaces[0]]
      if iface.full in done: continue
      done.incl iface.full
      buf.add &"# ---- {c.full}, disambiguating {iface.nim}\n\n"
      let enter = &"  let it = queryInterface[{iface.nim}Vtbl](self)"
      m.emitInterface(buf, iface, Receiver(recv: &"self: {c.nim}", what: c.nim),
                      enter, emitted, result, skips)

  # The ABI groups this module reached into, imported and handed on. Handed
  # on because an IID is a constant declared beside its vtable, and the
  # generic that reads one is instantiated where the method is called: a
  # program calling `PowerManager.batteryStatus` has to be able to see
  # `IID_IPowerManagerStatics`. Each is aliased, since `winrt/abi/foundation`
  # and `winrt/foundation` are both `foundation` to an export list.
  for full in usedIfaces:
    if full in m.ifaces: use(m.ifaces[full])
  var groups = usedAbi.toSeq
  groups.sort()
  var head = "import ./abi/[types, generic]\n"
  var exported = @["winrt", "classes", "types", "generic"]
  for g in groups:
    let alias = "abi" & g[0].toUpperAscii & g[1 .. ^1]
    head.add &"import ./abi/{g} as {alias}\n"
    exported.add alias
  head.add fill("export ", exported, "") & "\n"
  buf = buf.replace("##<abi-imports>##\n", head)
  writeFile(outPath, buf)
  if skips.len > 0:
    skips.sort()
    for reason, count in skips:
      echo &"    {count:>5}  {reason}"

when isMainModule:
  if paramCount() < 3 or paramStr(2) != "--split":
    quit "usage: wrappers <winmd> --split <out-dir>"
  let winmdPath = paramStr(1)
  let outDir = paramStr(3)
  let md = load(winmdPath)
  let m = buildModel(md, md.guids())
  createDir(outDir)

  var total = emitClasses(m, winmdPath, outDir / "classes.nim")
  echo &"  classes           {total.classes:>5} classes {total.interfaces:>5} interfaces  {m.unions.len} type classes"

  var groups: seq[string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    let g = topGroup(t.namespace)
    if g notin groups: groups.add g
  groups.sort()
  for g in groups:
    let e = emitGroup(m, winmdPath, g, outDir / (moduleName(g) & ".nim"))
    echo &"  {moduleName(g):<16} {e.procs:>6} procs {e.ctors:>4} constructors {e.events:>5} events  {e.skipped} skipped"
    total.procs += e.procs
    total.ctors += e.ctors
    total.events += e.events
    total.skipped += e.skipped
  echo ""
  echo &"  {groups.len + 1} modules  {total.classes} classes  {total.procs} procs  " &
       &"({total.ctors} constructors)  {total.events} events  {total.skipped} skipped"
