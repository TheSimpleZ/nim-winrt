## Emit the ABI layer from Windows Metadata.
##
## ```
## nimble bindings                       # the whole package
## nim c -r tools/generate.nim <winmd> --split <out-dir> [package-path]
## ```
##
## The ABI layer is what the Windows Runtime *is* on the wire, spelled in Nim:
##
## * `types.nim` — every enum and struct, with the layout a call crosses.
## * `generic.nim` — the parameterised interfaces and delegates,
##   `IVector<T>` and the rest, as generic vtable objects.
## * one module per namespace group — `foundation.nim`, `storage.nim` — with
##   an IID constant and a vtable object per interface: its methods, in
##   order, as typed fields.
##
## Taking all of this from metadata removes the whole class of bug where a
## GUID digit or a slot number is transcribed wrong — the kind that does not
## fail loudly but calls the wrong function.
##
## ## The WinRT calling convention
##
## Every WinRT method returns `HRESULT`. The *declared* return type becomes a
## trailing out-parameter, so `get_Title() -> HSTRING` is
## `proc(self: pointer, value: ptr HSTRING): HRESULT`. Getting this backwards
## is silent memory corruption, so it is applied here once rather than at
## thousands of call sites.
##
## ## Partial by design
##
## A signature that cannot be spelled is emitted as a `pointer` field rather
## than guessed at, so the methods after it still line up and a caller can
## cast it by hand. Emitting a *wrong* ABI type would be worse than none.

import std/[os, strformat, strutils, tables, sets, algorithm, sequtils]
import ./winmd
import ./foreign
import ./nimgen

const
  tdInterface = 0x20'u32
  ReferenceIface = "Windows.Foundation.IReference`1"

func asUint32(v: int64): uint32 =
  ## A flags enum's underlying type is UInt32, so its values stay unsigned —
  ## `ContactQuerySearchFields.All` is 0xFFFFFFFF, and as an int32 that reads
  ## back as -1.
  uint32(v)

func asInt32(v: int64): int32 =
  ## WinRT enums are backed by int32 *or* uint32, and a uint32-backed one can
  ## hold values above `int32.high` — `ApplicationHighContrastAdjustment.Auto`
  ## is `0xFFFFFFFF`. Four bytes cross the ABI either way, so the bit pattern is
  ## what matters; this keeps it and lets the sign fall where it may.
  cast[int32](uint32(v))

let aliasOf = block:
  ## Metadata name -> a type this library already declares. Kept as a table so
  ## `nimType` can answer in one lookup.
  var t = initTable[string, string]()
  for (name, nim) in foreignAliases: t[name] = nim
  t

# Cumulative across the run. A type is written once, and every module written
# afterwards refers to it through an import.
var structNames: HashSet[string]
  ## Full names of structs that got a Nim layout. A struct without one leaves
  ## every signature that mentions it unmapped.
var twinned: HashSet[string]
  ## Full names of structs whose ABI layout is a twin — `SortEntryAbi` —
  ## because a field is a string or a reference. The API layer declares the
  ## struct a person sees under the plain name, and the vtables take the twin.
var runDefines: HashSet[string]   ## short names this run will define from metadata
var emittedEnums: HashSet[string] ## Nim names of the enums written
var enumFullNames: HashSet[string]
var renamed: Table[string, string]
  ## Full name -> the Nim name it was written under, where those differ.
  ##
  ## A handful of types share a short name with another: `AnimationDirection`
  ## is a composition easing and a XAML slide, `IFrameworkView` is an app
  ## model interface and a XAML one. The second is written under its
  ## namespace's last segment — `PrimitivesAnimationDirection`,
  ## `XamlIFrameworkView` — and every signature that names it is redirected
  ## here. The API generator applies the same rule so the two layers agree.
var runtimeNames: seq[(string, string)]
  ## (Nim name, metadata name) of every enum and struct written, for the
  ## table `typeSignature(T)` reads a type's metadata name from.
var typeVars: seq[string]
  ## While a generic interface is being written: its parameters' names, so
  ## `!0` in a signature spells as `Abi(T)`.

proc nimType(t: SigType): string =
  ## Map a signature type to its Nim ABI spelling, or "" when unsupported.
  ##
  ## Interfaces and objects are bare pointers: at the ABI every WinRT
  ## interface is an `IInspectable`, so one pointer type serves for all of
  ## them and the IID is what distinguishes them at runtime.
  let base =
    case t.kind
    of skVoid: "void"
    of skBool: "bool"          # one byte on the wire, matching Nim's bool
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
    of skString: "HSTRING"
    of skObject, skInterface: "pointer"
    of skEnum:
      # int32 on the wire, but say which enum: `ptr BatteryStatus` rather than
      # `ptr int32` is the difference between reading a result and decoding
      # one. Falls back to the raw width for an enum from another winmd, which
      # has no type here to name.
      if t.name in enumFullNames:
        renamed.getOrDefault(t.name, shortName(t.name))
      else: "int32"
    of skStruct:
      # A struct crosses by value, so Nim must know its exact layout. Nim emits
      # these as plain C structs, which means the C compiler applies the same
      # x64 ABI that Windows' own C++ was built with. A struct holding a string
      # or a reference crosses as its twin.
      if t.name in foreignEnums: "int32"
      elif t.name in aliasOf: aliasOf[t.name]
      elif t.name in twinned: shortName(t.name) & "Abi"
      elif t.name in structNames:
        renamed.getOrDefault(t.name, shortName(t.name))
      else: ""
    of skTypeVar:
      # A generic interface's own parameter: whatever the instantiation says,
      # in its ABI form.
      let i = parseInt(t.name)
      if i < typeVars.len: "Abi(" & typeVars[i] & ")" else: ""
    of skUnsupported:
      # A generic instantiation is still an interface pointer on the wire —
      # `IVector<T>` and `TypedEventHandler<S, A>` cross the ABI exactly as
      # `IButton` does. What is special about them is only the *IID*, which is
      # computed rather than declared, and an IID is not part of a signature.
      # Everything else that lands here — a function pointer — genuinely has no
      # shape, and is told apart by having no name or no arguments.
      if t.name.len > 0 and t.args.len > 0: "pointer" else: ""
    of skArray: ""
  if base.len == 0: return ""
  if t.byRef: "ptr " & base else: base

func boxable(t: SigType): bool =
  ## Whether `IReference<t>` inside a struct can be a `Reference[T]`: the
  ## value types `Reference` knows the IID of.
  t.kind in {skBool, skU1, skI2, skU2, skI4, skU4, skI8, skU8, skF4, skF8} or
    (t.kind == skStruct and t.name == "System.Guid")

func isReference(t: SigType): bool =
  t.kind == skUnsupported and t.name == ReferenceIface and t.args.len == 1

proc owning(t: SigType): bool =
  ## Whether a struct field of this type owns something at the ABI, making
  ## the struct one with a twin.
  t.kind == skString or (isReference(t) and boxable(t.args[0])) or
    (t.kind == skStruct and t.name in twinned)

proc fieldType(t: SigType): string =
  ## A struct field's ABI spelling: as `nimType`, except that a string or an
  ## `IReference<T>` inside a struct *owns* what it holds — `WinRtString`,
  ## `Reference[T]` — so that a struct read out of Windows can be kept and
  ## one built here handed over.
  if t.kind == skString: "WinRtString"
  elif isReference(t) and boxable(t.args[0]): "Reference[" & nimType(t.args[0]) & "]"
  else: nimType(t)

proc paramName(i: int, t: SigType): string =
  ## Name a parameter after the interface it expects.
  ##
  ## Every interface is a bare `pointer` at the ABI, so the type system cannot
  ## stop you passing `IButton` where `UIElement` is wanted. A WinRT callee is
  ## entitled to use the pointer as exactly the declared interface, so the
  ## wrong one walks the wrong vtable and takes the process down rather than
  ## returning an error. Putting the expected name in the signature is what
  ## makes that visible at the call site.
  if t.kind in {skObject, skInterface} and t.name.len > 0:
    &"a{i + 1}{shortName(t.name)}"
  else:
    &"a{i + 1}"

proc abiProc(sig: MethodSig; head = "proc("): string =
  ## The full `proc(...)` type for a method, or "" if any part is unmapped.
  ## `head` is what the type is written after — a vtable field's name — so
  ## the folding lines up under the first parameter.
  var parts = @["self: pointer"]
  for i, p in sig.params:
    if p.kind == skArray:
      # An array crosses as two arguments: how many, and where. Which two
      # depends on who allocates. A pass array and a fill array both point at
      # a buffer the caller already has — `(UINT32, T*)`. A *receive* array is
      # allocated by the callee and handed back, so both halves are written
      # through: `(UINT32*, T**)`. The metadata says which by marking the
      # receive kind by-reference, and getting it wrong writes a pointer over
      # a caller's count.
      if p.args.len == 0: return ""
      let e = nimType(p.args[0])
      if e.len == 0 or e == "void": return ""
      if p.byRef:
        parts.add &"{paramName(i, p)}Size: ptr uint32"
        parts.add &"{paramName(i, p)}: ptr ptr {e}"
      else:
        parts.add &"{paramName(i, p)}Size: uint32"
        parts.add &"{paramName(i, p)}: ptr {e}"
      continue
    let n = nimType(p)
    if n.len == 0 or n == "void": return ""
    parts.add &"{paramName(i, p)}: {n}"
  # The declared return becomes a trailing out-parameter; only `void` has none.
  if sig.returns.kind == skArray:
    if sig.returns.args.len == 0: return ""
    let e = nimType(sig.returns.args[0])
    if e.len == 0 or e == "void": return ""
    parts.add "valueSize: ptr uint32"
    parts.add &"value: ptr ptr {e}"
  elif sig.returns.kind != skVoid:
    let r = nimType(sig.returns)
    if r.len == 0: return ""
    parts.add &"value: ptr {r}"
  fill(head, parts, "): HRESULT {.abi.}", width = 78)

proc header(buf: var string, winmdPath, what: string, lines: openArray[string]) =
  buf.add "## Generated by tools/generate.nim - do not edit.\n##\n"
  buf.add &"## Source: {winmdPath.extractFilename}\n"
  buf.add &"## {what}\n##\n"
  for l in lines: buf.add "## " & l & "\n"
  buf.add "\n"

type Emission = tuple
  enums, enumMembers, structs, interfaces, slots, typed, untyped: int

# ---------------------------------------------------------------- values

proc emitValues(md: WinMd, winmdPath, outPath, pkg: string): Emission =
  ## `types.nim`: every enum and struct in the metadata, in dependency order.
  var buf = newStringOfCap(2 shl 20)
  header(buf, winmdPath, "Every enum and struct in the metadata.", [
    "An enum is a Nim enum pinned to the int32 on the wire, or, marked",
    "[Flags], a distinct uint32 with the bitwise operators. A struct is an",
    "object with the exact layout a call crosses; one holding a string or an",
    "IReference<T> is written as `<Name>Abi`, with `WinRtString` and",
    "`Reference[T]` fields that own what they hold, and the API layer",
    "declares the `<Name>` a person sees over it."])
  buf.add "import std/hashes\nexport hashes\n"
  buf.add &"import {pkg}/[com, objects]\nexport com, objects\n"
  buf.add &"include {pkg}/abidef\n\n"

  var enums, enumMembers, structs = 0

  # Enums first: they are what call sites actually pass, and getting one
  # backwards is silent. `Orientation.Vertical` is 0 in XAML and 1 in WPF, and
  # the wrong one lays a panel out sideways without reporting anything.
  #
  # Most become a real Nim enum. `{.size: 4.}` pins the representation to the
  # int32 that crosses the wire, and `{.pure.}` keeps the members behind the
  # type name — necessary rather than stylistic, since `None`, `All` and
  # `Unknown` appear in dozens of unrelated enums.
  #
  # Two shapes cannot be one:
  #
  # * An enum marked `[Flags]` holds combinations, and no Nim enum can — a
  #   `set` would be the idiomatic answer but its members must be small
  #   ordinals and these run to 2^31. Those stay `distinct uint32` and get the
  #   bitwise operators instead, so they can at least be combined.
  # * Nim requires enum values to be unique and ascending. Eight enums in the
  #   whole of `Windows.winmd` give one value two names, so those are emitted
  #   once and the other name becomes a `const` alias.
  let attrs = md.attributeNames()
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if (t.flags and tdInterface) != 0: continue
    if not md.isEnum(t.index): continue
    if t.fullName in aliasOf: continue
    let members = md.enumMembers(t.index)
    if members.len == 0: continue
    var ident = sanitize(t.name)
    if ident in emittedEnums:
      # Qualified by the namespace it came from, which is what tells the two
      # apart for a reader as well as for the compiler.
      let parts = t.namespace.split('.')
      ident = sanitize(parts[^1]) & ident
      if ident in emittedEnums: continue
      renamed[t.fullName] = ident
    emittedEnums.incl ident
    enumFullNames.incl t.fullName
    runtimeNames.add (ident, t.fullName)

    var isFlags = false
    for a in attrs.getOrDefault(t.index, @[]):
      if a == "FlagsAttribute": isFlags = true

    buf.add &"## {t.fullName}  (enum)\n"
    if isFlags:
      # Unsigned, because the type system says so: "an enum with an underlying
      # type of UInt32 must carry the FlagsAttribute. An enum with an
      # underlying type of Int32 must not." Signed is not merely untidy here —
      # `ContactQuerySearchFields.All` is 0xFFFFFFFF, which as an int32 reads
      # back as -1.
      buf.add &"type {ident}* = distinct uint32\n"
      buf.add &"proc `==`*(a, b: {ident}): bool {{.borrow.}}\n"
      buf.add &"proc `or`*(a, b: {ident}): {ident} {{.borrow.}}\n"
      buf.add &"proc `and`*(a, b: {ident}): {ident} {{.borrow.}}\n"
      buf.add &"proc `not`*(a: {ident}): {ident} {{.borrow.}}\n"
      buf.add &"proc contains*(a, b: {ident}): bool =\n"
      buf.add  "  ## Is every bit of `b` set in `a`?\n"
      buf.add &"  (uint32(a) and uint32(b)) == uint32(b)\n"
      buf.add &"proc `$`*(v: {ident}): string =\n"
      buf.add  "  ## The set bits by name, or the number if none match.\n"
      buf.add &"  var rest = uint32(v)\n"
      buf.add  "  result = \"\"\n"
      for (name, value) in members:
        if asUint32(value) == 0: continue
        buf.add &"  if (rest and {asUint32(value)}'u32) == {asUint32(value)}'u32:\n"
        buf.add  "    if result.len > 0: result.add \" or \"\n"
        buf.add &"    result.add \"{name}\"\n"
        buf.add &"    rest = rest and not {asUint32(value)}'u32\n"
      buf.add  "  if rest != 0 or result.len == 0:\n"
      buf.add &"    if result.len > 0: result.add \" or \"\n"
      buf.add &"    result.add \"{ident}(\" & $rest & \")\"\n"
      for (name, value) in members:
        buf.add &"const {ident}_{sanitize(name)}* = {ident}({asUint32(value)}'u32)\n"
        enumMembers.inc
    else:
      # Sorted, because Nim needs ascending values and the metadata is in
      # declaration order. Aliases follow as consts.
      var seen: Table[int32, string]
      var uniq: seq[(int32, string)]
      var aliases: seq[(string, string)]
      for (name, value) in members:
        let v = asInt32(value)
        if v in seen: aliases.add (sanitize(name), seen[v])
        else:
          seen[v] = sanitize(name)
          uniq.add (v, sanitize(name))
      uniq.sort(proc (a, b: (int32, string)): int = cmp(a[0], b[0]))

      buf.add &"type {ident}* {{.pure, size: 4.}} = enum\n"
      for (v, name) in uniq:
        buf.add &"  {escapeIdent(name)} = {v}'i32\n"
      for (alias, orig) in aliases:
        buf.add &"const {ident}_{alias}* = {ident}.{escapeIdent(orig)}\n"
      # A *template*, and the difference is two seconds of compile time in
      # every program that imports anything: a proc's body is checked when
      # the module is, and 1,588 of them each instantiate the compiler's own
      # enum-to-string machinery, while a template's body waits until a
      # program actually prints one. `enumName` rather than the built-in `$`
      # because that renders a value added after this metadata was cut as
      # the empty string.
      buf.add &"template `$`*(v: {ident}): string = enumName(v)\n"
      enumMembers.inc uniq.len + aliases.len
    buf.add "\n"
    enums.inc

  # Structs next, because a signature that takes one by value cannot be mapped
  # until Nim knows its exact layout. Nim emits these as plain C structs, so
  # the C compiler applies the same x64 calling convention that Windows' own
  # C++ was built with — small ones in registers, larger ones by hidden
  # pointer — without any of it being spelled out here.
  #
  # `foreign.nim` describes types this winmd only *references*. A different
  # winmd may define them for real, and emitting both spellings is a
  # redefinition. The file on disk always wins. Both sources go in one queue,
  # because the dependency edges run both ways, and the queue emits whatever
  # is fully resolvable and goes round again until a pass adds nothing.
  type PendingStruct = object
    foreign: bool
    full: string
    fields: seq[(string, string)]   ## foreign only
    row: TypeRow                    ## metadata only

  var queue: seq[PendingStruct]
  for (name, fields) in foreignStructs:
    if shortName(name) in runDefines: continue
    queue.add PendingStruct(foreign: true, full: name, fields: fields)
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue     # a class, not a value type
    # `Windows.Foundation.HResult` is a struct wrapping an Int32 that `com`
    # already spells as `HRESULT`; emitting it too would put two names for one
    # thing in two modules, and Nim would call every use of it ambiguous.
    if t.fullName in aliasOf: continue
    let (ff, fs) = md.fieldRange(t.index)
    if fs <= ff: continue
    queue.add PendingStruct(foreign: false, full: t.fullName, row: t)

  # Which structs need a twin is a fixpoint: a struct holding a twinned struct
  # is twinned too. Nothing in this metadata nests one, but the rule is cheap.
  var changed = true
  while changed:
    changed = false
    for p in queue:
      if p.foreign or p.full in twinned: continue
      let (ff, fs) = md.fieldRange(p.row.index)
      for fi in ff ..< fs:
        if owning(md.fieldType(fi)):
          twinned.incl p.full
          changed = true
          break

  var planned: HashSet[string]
  for p in queue: planned.incl shortName(p.full)
  var emittedStructs: HashSet[string]
  var twins: seq[PendingStruct]   ## written again below, as the API sees them

  while queue.len > 0:
    var progressed = false
    var stillPending: seq[PendingStruct]
    for p in queue:
      var fields: seq[string]
      var ok = true
      if p.foreign:
        for (f, ft) in p.fields:
          if ft in planned and ft notin emittedStructs:
            ok = false
            break
          fields.add &"  {f}*: {ft}"
      else:
        let (ff, fs) = md.fieldRange(p.row.index)
        for fi in ff ..< fs:
          let ft = md.fieldType(fi)
          let fname = sanitize(md.str(md.cell(tField, fi, "Name")))
          let n =
            if ft.kind == skEnum and ft.name in enumFullNames:
              renamed.getOrDefault(ft.name, shortName(ft.name))
            elif ft.kind == skEnum: "int32"
            else: fieldType(ft)
          if n.len == 0 or n == "void":
            ok = false
            break
          fields.add &"  {escapeIdent(lowerFirst(fname))}*: {n}"
      if not ok:
        stillPending.add p
        continue
      let twin = p.full in twinned
      let name = shortName(p.full) & (if twin: "Abi" else: "")
      let note =
        if p.foreign: "struct, layout from the Windows SDK headers"
        elif twin: "struct, as it crosses the ABI"
        else: "struct"
      buf.add &"## {p.full}  ({note})\n"
      buf.add &"type {name}* {{.pure.}} = object\n"
      for f in fields: buf.add f & "\n"
      if not twin:
        # A WinRT struct is plain data, so its bytes are its identity. Without
        # this a map keyed by one — `IMapView<PowerThermalChannelId, ...>` —
        # has no Nim `Table` to become.
        buf.add &"proc hash*(x: {name}): Hash =\n"
        buf.add  "  hashData(x.unsafeAddr, sizeof(x))\n"
      buf.add "\n"
      if twin: twins.add p
      runtimeNames.add (shortName(p.full), p.full)
      structNames.incl p.full
      emittedStructs.incl shortName(p.full)
      structs.inc
      progressed = true
    # A struct that still will not resolve depends on something unmapped; its
    # methods stay unmapped too, which is the intended outcome.
    if not progressed: break
    queue = stillPending

  # The struct a person sees, over its twin: `string` and `Option[T]` fields,
  # `Abi` naming the twin so the generic vtables take it, and the two
  # conversions. Those are generic so that `asReference` and `value`, which
  # live above this module, bind where a conversion is instantiated.
  for p in twins:
    let name = shortName(p.full)
    let (ff, fs) = md.fieldRange(p.row.index)
    var fields: seq[(string, string, SigType)]
    for fi in ff ..< fs:
      let ft = md.fieldType(fi)
      let fname = escapeIdent(lowerFirst(sanitize(md.str(md.cell(tField, fi, "Name")))))
      let api = if ft.kind == skString: "string"
                elif isReference(ft): "Option[" & nimType(ft.args[0]) & "]"
                elif ft.kind == skEnum: renamed.getOrDefault(ft.name, shortName(ft.name))
                else: nimType(ft)
      fields.add (fname, api, ft)
    buf.add &"## {p.full}  (struct)\n"
    buf.add &"type {name}* = object\n"
    for (f, t, _) in fields: buf.add &"  {f}*: {t}\n"
    buf.add &"template Abi*(T: typedesc[{name}]): typedesc = {name}Abi\n"
    buf.add &"proc toAbi*[T: {name}](x: T): {name}Abi =\n"
    buf.add  "  ## `x` as it crosses the ABI, owning what its handles hold.\n"
    buf.add  "  mixin asReference\n"
    var conv: seq[string]
    for (f, _, ft) in fields:
      conv.add (if ft.kind == skString: &"{f}: toWinRtString(x.{f})"
                elif isReference(ft): &"{f}: asReference(x.{f})"
                else: &"{f}: x.{f}")
    buf.add fill(&"  {name}Abi(", conv, ")") & "\n"
    buf.add &"proc fromAbi*[T: {name}Abi](x: T): {name} =\n"
    buf.add  "  ## The struct a person sees, read out of its ABI form.\n"
    buf.add  "  mixin value\n"
    conv.setLen(0)
    for (f, _, ft) in fields:
      conv.add (if ft.kind == skString: &"{f}: $x.{f}"
                elif isReference(ft): &"{f}: x.{f}.value"
                else: &"{f}: x.{f}")
    buf.add fill(&"  {name}(", conv, ")") & "\n"
    buf.add &"proc hash*(x: {name}): Hash =\n"
    buf.add  "  var h: Hash = 0\n"
    for (f, _, _) in fields: buf.add &"  h = h !& hash(x.{f})\n"
    buf.add  "  !$h\n\n"

  buf.add "# The metadata name behind each Nim name, which `runtimeName(T)` reads\n"
  buf.add "# and `typeSignature(T)` hashes: what `IVector<BatteryStatus>` is made of.\n"
  for (nim, full) in runtimeNames:
    buf.add &"const RuntimeName_{nim}* = \"{full}\"\n"

  writeFile(outPath, buf)
  (enums, enumMembers, structs, 0, 0, 0, 0)

# -------------------------------------------------------------- interfaces

proc emitVtable(md: WinMd, buf: var string, t: TypeRow, ident, iid: string,
                delegate: bool, params: seq[string]; stats: var Emission) =
  ## One interface or delegate as its IID and its vtable object, generic over
  ## `params` if there are any.
  buf.add &"## {t.fullName}" & (if delegate: "  (delegate)" else: "") & "\n"
  buf.add &"const IID_{ident}* = {guidLiteral(iid)}\n"
  let parent = if delegate: "IUnknownVtbl" else: "IInspectableVtbl"
  let generic = if params.len > 0: "[" & params.join(", ") & "]" else: ""
  buf.add &"type {ident}Vtbl*{generic} = object of {parent}\n"
  typeVars = params
  let (first, stop) = md.methodRange(t.index)
  var seen = initCountTable[string]()
  for mi in first ..< stop:
    let rawName = md.str(md.cell(tMethodDef, mi, "Name"))
    if delegate and rawName == ".ctor":
      continue
    let m = sanitize(rawName)
    # Keyed on what Nim sees, not on what the metadata spells, so two
    # overloads are caught and `get_Text` beside `GetText` — distinct to
    # Nim, which is case-sensitive in the first character — is not. The
    # winner is whichever comes first in the metadata, and `wrappers.nim`
    # keys the same way, or it would name a field that is not there.
    seen.inc nimIdent(m)
    let suffix = if seen[nimIdent(m)] > 1: $seen[nimIdent(m)] else: ""
    let field = escapeIdent(m & suffix)
    stats.slots.inc
    let fn = abiProc(md.methodSignature(mi), &"  {field}*: proc(")
    if fn.len > 0:
      buf.add fn & "\n"
      stats.typed.inc
    else:
      # The slot has to be occupied for the ones after it to line up.
      buf.add &"  {field}*: pointer   ## signature not mapped\n"
      stats.untyped.inc
  typeVars = @[]
  stats.interfaces.inc

proc settleNames(md: WinMd, iids: Table[int, string]) =
  ## Which declared interfaces share a short name, settled before any module
  ## is written: the second takes its namespace's last segment as a prefix,
  ## the first keeps the plain name. The API generator applies the same rule
  ## in the same order, so both layers agree on every name.
  var taken: HashSet[string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if '`' in t.name: continue
    if (t.flags and tdInterface) == 0 and not md.isDelegate(t.index): continue
    if t.index notin iids: continue
    var ident = sanitize(t.name)
    if nimIdent(ident) in taken:
      ident = sanitize(t.namespace.split('.')[^1]) & ident
      if nimIdent(ident) in taken: continue
      renamed[t.fullName] = ident
    taken.incl nimIdent(ident)

proc emitGenerics(md: WinMd, iids: Table[int, string], winmdPath, outPath,
                  pkg: string): Emission =
  ## `generic.nim`: the parameterised interfaces and delegates, each a
  ## generic vtable with its IID and signature computed from its arguments.
  var buf = newStringOfCap(64 shl 10)
  header(buf, winmdPath, "The parameterised interfaces and delegates.", [
    "`IVector<T>` has one vtable layout and thousands of instantiations, so",
    "each is one generic object here, its fields typed through `Abi(T)`: a",
    "pointer for an object, an HSTRING for a string, the value itself",
    "otherwise. An instantiation's IID is not declared anywhere:",
    "`iid(IVectorVtbl[T])` hashes its signature at compile time."])
  buf.add &"import {pkg}/[com, objects, signatures]\n"
  buf.add "import ./types\nexport com, objects, signatures, types\n"
  buf.add &"include {pkg}/abidef\n\n"
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if '`' notin t.name: continue
    let delegate = md.isDelegate(t.index)
    if (t.flags and tdInterface) == 0 and not delegate: continue
    if t.index notin iids: continue
    let ident = sanitize(t.name.split('`')[0])
    let params = md.genericParams(t.index)
    if params.len == 0: continue
    emitVtable(md, buf, t, ident, iids[t.index], delegate, params, result)
    # The signature of an instantiation, from the open generic's own GUID
    # and the arguments' signatures; `iid(IVectorVtbl[T])` hashes it.
    let generic = "[" & params.join(", ") & "]"
    let args = params.mapIt("typeSignature(" & it & ")").join(", ")
    buf.add &"proc typeSignature*{generic}(_: typedesc[{ident}Vtbl{generic}]): string =\n"
    buf.add &"  pinterfaceSignature(IID_{ident}, {args})\n\n"
  writeFile(outPath, buf)

proc emitGroup(md: WinMd, iids: Table[int, string], winmdPath, prefix, outPath,
               pkg: string): Emission =
  ## One module of vtables: every declared, non-generic interface and delegate
  ## under `prefix`, matched on whole segments.
  proc owned(t: TypeRow): bool =
    t.namespace == prefix or t.namespace.startsWith(prefix & ".")
  var buf = newStringOfCap(2 shl 20)
  header(buf, winmdPath, &"Namespace: {prefix}", [
    "Each interface is its vtable: an object whose fields are the methods in",
    "declaration order, after IInspectable's six (IUnknown's three for a",
    "delegate). Every method returns HRESULT and its declared return type",
    "becomes a trailing out-parameter. `IID_X`, beside it, is its IID."])
  buf.add &"import {pkg}/com\nimport ./types\nexport com, types\n"
  buf.add &"include {pkg}/abidef\n\n"
  for t in md.types:
    if not owned(t): continue
    if '`' in t.name: continue
    let delegate = md.isDelegate(t.index)
    if (t.flags and tdInterface) == 0 and not delegate: continue
    if t.index notin iids: continue
    let ident = renamed.getOrDefault(t.fullName, sanitize(t.name))
    emitVtable(md, buf, t, ident, iids[t.index], delegate, @[], result)
    buf.add "\n"
  writeFile(outPath, buf)

when isMainModule:
  if paramCount() < 3 or paramStr(2) != "--split":
    quit "usage: generate <winmd> --split <out-dir> [package-path]"

  let winmdPath = paramStr(1)
  let outDir = paramStr(3)
  # Where the generated modules find the hand-written plumbing: `..` inside
  # this package, `winrt` for a package that depends on it.
  let pkg = if paramCount() >= 4: paramStr(4) else: ".."
  let md = load(winmdPath)
  let iids = md.guids()
  createDir(outDir)

  for t in md.types:
    if t.namespace.startsWith("Windows."): runDefines.incl shortName(t.fullName)

  # Values first: a vtable can name any of them. Then the generic vtables;
  # then a module of declared vtables per namespace group, their names
  # settled first so that a clash is resolved the same way everywhere.
  var total = emitValues(md, winmdPath, outDir / "types.nim", pkg)
  echo &"""  {"types":<16} {total.enums:>5} enums {total.structs:>4} structs ({twinned.len} with an ABI twin)"""
  settleNames(md, iids)
  let g = emitGenerics(md, iids, winmdPath, outDir / "generic.nim", pkg)
  echo &"""  {"generic":<16} {g.interfaces:>5} interfaces {g.slots:>6} methods"""
  total.interfaces += g.interfaces
  total.slots += g.slots
  total.typed += g.typed
  total.untyped += g.untyped

  var groups: seq[string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    let grp = topGroup(t.namespace)
    if grp notin groups: groups.add grp
  groups.sort()
  for grp in groups:
    let e = emitGroup(md, iids, winmdPath, grp, outDir / (moduleName(grp) & ".nim"), pkg)
    total.interfaces += e.interfaces
    total.slots += e.slots
    total.typed += e.typed
    total.untyped += e.untyped
    let pct = if e.slots > 0: e.typed * 100 div e.slots else: 0
    echo &"  {moduleName(grp):<16} {e.interfaces:>5} interfaces " &
         &"{e.slots:>6} methods ({pct}% typed)"

  let pct = if total.slots > 0: total.typed * 100 div total.slots else: 0
  echo ""
  echo &"  {groups.len + 2} modules  {total.enums} enums  {total.structs} structs"
  echo &"  {total.interfaces} interfaces  {total.slots} methods  {pct}% typed  " &
       &"{total.untyped} unmapped"
