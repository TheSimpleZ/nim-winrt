## Emit Nim bindings from Windows Metadata.
##
## ```
## nimble bindings                       # the whole package, one module per group
## nim c -r tools/generate.nim <winmd> <namespace-prefix> <out.nim>
## ```
##
## For every interface and delegate under the prefix this writes:
##
## * its IID,
## * a vtable slot constant per method,
## * a typed `proc` for the ABI signature, where the signature could be
##   decoded with confidence.
##
## Taking these from metadata removes the whole class of bug where a GUID digit
## or a slot number is transcribed wrong — the kind that does not fail loudly
## but calls the wrong function.
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
## Signatures containing shapes that are not yet mapped — structs passed by
## value, generic instantiations, arrays — are skipped rather than guessed at.
## A method with no generated proc still gets its slot constant and can be
## called with a hand-written signature. Emitting a *wrong* ABI type would be
## worse than emitting none.

import std/[os, strformat, strutils, tables, sets, algorithm, sequtils]
import ./winmd
import ./foreign
import ./nimgen

const
  tdInterface = 0x20'u32

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

# Cumulative across every module this run emits. A type is written once, by
# the first module that owns it; every module written afterwards sees it here,
# skips it, and refers to it through an import. That is what keeps
# `Windows.Media.MediaTimeRange` and `Windows.Foundation.TimeSpan` in separate
# files without either duplicating the other.
var structNames: HashSet[string]
  ## Full names of structs that got a Nim layout. A struct without one leaves
  ## every signature that mentions it unmapped.
var runDefines: HashSet[string]   ## short names this run will define from metadata
var emitted: HashSet[string]      ## `nimIdent` of every IID constant written
var emittedEnums: HashSet[string] ## Nim names of the enums written
var enumFullNames: HashSet[string]
var valueSpelling: Table[string, string]
  ## Full name -> the Nim name it was written under, where those differ.
  ##
  ## Two enums in the whole of `Windows.winmd` share a short name with another
  ## one: `AnimationDirection` is a composition easing and a XAML slide, and
  ## `PackageStatus` is an app model state and a deployment one. Writing every
  ## value type into a single module makes that a collision rather than two
  ## modules' private business, so the second is written under its namespace's
  ## last segment — `PrimitivesAnimationDirection` — and every signature that
  ## names it is redirected here.
  ## Metadata names of those same enums, for resolving a struct field's type.

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
    of skString: "HSTRING"
    of skObject, skInterface: "pointer"
    of skEnum:
      # int32 on the wire, but say which enum: `ptr BatteryStatus` rather than
      # `ptr int32` is the difference between reading a result and decoding
      # one. Falls back to the raw width for an enum from another winmd, which
      # has no type here to name.
      if t.name in enumFullNames:
        valueSpelling.getOrDefault(t.name, shortName(t.name))
      else: "int32"
    of skStruct:
      # A struct crosses by value, so Nim must know its exact layout. Nim emits
      # these as plain C structs, which means the C compiler applies the same
      # x64 ABI that WinUI's own C++ was built with.
      if t.name in foreignEnums: "int32"
      elif t.name in aliasOf: aliasOf[t.name]
      elif t.name in structNames:
        valueSpelling.getOrDefault(t.name, shortName(t.name))
      else: ""
    of skUnsupported:
      # A generic instantiation is still an interface pointer on the wire —
      # `IVector<T>` and `TypedEventHandler<S, A>` cross the ABI exactly as
      # `IButton` does. What is special about them is only the *IID*, which is
      # computed rather than declared, and an IID is not part of a signature.
      # Everything else that lands here — a type variable, a function pointer —
      # genuinely has no shape, and is told apart by having no name or no
      # arguments.
      if t.name.len > 0 and t.args.len > 0: "pointer" else: ""
    of skArray: ""
  if base.len == 0: return ""
  if t.byRef: "ptr " & base else: base

proc paramName(i: int, t: SigType): string =
  ## Name a parameter after the interface it expects.
  ##
  ## Every interface is a bare `pointer` at the ABI, so the type system cannot
  ## stop you passing `IButton` where `UIElement` is wanted. A WinRT callee is
  ## entitled to use the pointer as exactly the declared interface, so the wrong
  ## one walks the wrong vtable and takes the process down rather than returning
  ## an error. Putting the expected name in the signature is what makes that
  ## visible at the call site.
  if t.kind in {skObject, skInterface} and t.name.len > 0:
    &"a{i + 1}{shortName(t.name)}"
  else:
    &"a{i + 1}"

proc abiProc(sig: MethodSig; outParams: Table[int, bool] = initTable[int, bool]()): string =
  ## The full `proc(...)` type for a method, or "" if any part is unmapped.
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
    # A returned array is allocated by the callee: a count and a pointer, both
    # written through.
    if sig.returns.args.len == 0: return ""
    let e = nimType(sig.returns.args[0])
    if e.len == 0 or e == "void": return ""
    parts.add "valueSize: ptr uint32"
    parts.add &"value: ptr ptr {e}"
  elif sig.returns.kind != skVoid:
    let r = nimType(sig.returns)
    if r.len == 0: return ""
    parts.add &"value: ptr {r}"
  "proc(" & parts.join(", ") & "): HRESULT {.abi.}"

type Emission = tuple
  enums, enumMembers, structs, interfaces, slots, typed, untyped: int

type Part = enum
  ## Which half of the ABI a call writes.
  ##
  ## Split in two because the two halves have different dependency shapes.
  ## Enums and structs are value types: a struct may contain another, but
  ## nothing can contain itself, so the whole set is a DAG and fits in one
  ## module written in dependency order. Interfaces are the opposite — they
  ## name each other freely and in cycles — but at this layer an interface is
  ## a bare `pointer`, so a module of interfaces depends on nothing but the
  ## values module. Writing every value type once, first, is therefore what
  ## lets every signature in every group resolve.
  pEverything    ## one self-contained module (the single-prefix mode)
  pValues        ## enums and structs, for every namespace at once
  pInterfaces    ## IIDs, slots and signatures for one group

proc emitModule(md: WinMd; iids: Table[int, string]; winmdPath, prefix,
                outPath, corePath: string; imports: seq[string];
                provider = ""; part = pEverything): Emission =
  ## Write one module: every type under `prefix` that no earlier call has
  ## already written.
  ##
  ## `prefix` carries no trailing dot and is matched on whole segments, so
  ## `Windows.Data` takes `Windows.Data` and `Windows.Data.Json` and leaves a
  ## hypothetical `Windows.DataTransfer` alone.
  proc inScope(ns: string): bool =
    ns == prefix or ns.startsWith(prefix & ".")

  proc owned(t: TypeRow): bool =
    inScope(t.namespace)

  var buf = newStringOfCap(4 shl 20)
  buf.add "## Generated by tools/generate.nim - do not edit.\n##\n"
  buf.add &"## Source:    {winmdPath.extractFilename}\n"
  buf.add &"## Namespace: {prefix}\n##\n"
  buf.add "## Slot numbers are vtable indices. WinRT interfaces begin with\n"
  buf.add "## IInspectable's six slots, so the first declared method is slot 6;\n"
  buf.add "## delegates derive from IUnknown and begin at slot 3.\n##\n"
  buf.add "## Every method returns HRESULT and its declared return type becomes\n"
  buf.add "## a trailing out-parameter.\n\n"
  # `export` as well as `import`: a signature in this module may name a type
  # another one defines, and someone who imports this module to use that
  # signature needs the type to come with it.
  # `hashes` because a generated struct carries a `hash` of its own, so that
  # a map keyed by one can become a Nim `Table`.
  buf.add "import std/hashes\nexport hashes\n"
  buf.add &"import {corePath}\n"
  # The calling contract, written once and included rather than imported:
  # a user pragma does not cross a module boundary in Nim.
  buf.add &"include {corePath.rsplit('/', 1)[0]}/abidef\n"
  buf.add &"export {corePath.split('/')[^1]}\n"
  if provider.len > 0:
    buf.add &"import {provider}\n"
    buf.add &"export {provider.split('/')[^1]}\n"
  for m in imports:
    buf.add &"import ./{m}\n"
    buf.add &"export {m}\n"
  buf.add "\n"

  var
    interfaces, slots, typed, untyped, skippedNoIid = 0
    enums, enumMembers = 0

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
  #   ordinals and these run to 2^31. Those stay `distinct int32` and get the
  #   bitwise operators instead, so they can at least be combined.
  # * Nim requires enum values to be unique and ascending. Eight enums in the
  #   whole of `Windows.winmd` give one value two names, so those are emitted
  #   once and the other name becomes a `const` alias.
  let attrs = md.attributeNames()
  for t in md.types:
    if part == pInterfaces: break
    if not owned(t): continue
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
      valueSpelling[t.fullName] = ident
    emittedEnums.incl ident
    enumFullNames.incl t.fullName

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
      # Windows can hand back a value added after this metadata was cut, and
      # the built-in `$` renders that as the empty string.
      buf.add &"proc `$`*(v: {ident}): string =\n"
      buf.add  "  case ord(v)\n"
      for (v, name) in uniq:
        buf.add &"  of {v}: \"{name}\"\n"
      buf.add &"  else: \"{ident}(\" & $ord(v) & \")\"\n"
      enumMembers.inc uniq.len + aliases.len
    buf.add "\n"
    enums.inc

  # Structs next, because a signature that takes one by value cannot be mapped
  # until Nim knows its exact layout. 2,553 methods take or return one, so the
  # difference between having these and not is most of the unmapped surface.
  #
  # Nim emits these as plain C structs, so the C compiler applies the same x64
  # calling convention that WinUI's own C++ was built with — small ones in
  # registers, larger ones by hidden pointer — without any of it being spelled
  # out here.
  var structs = 0
  # `foreign.nim` describes types this winmd only *references*. A different
  # winmd may define them for real — `Windows.Foundation.Point` is absent from
  # `Microsoft.UI.Xaml.winmd` but present in `Windows.winmd` — and emitting both
  # spellings is a redefinition. The file on disk always wins.
  #
  # Both sources go in one queue, because the dependency edges run both ways: a
  # foreign `ManipulationDelta` holds a `Point` the metadata may define, and an
  # in-namespace `Duration` holds a `TimeSpan` the metadata does not. Emitting
  # either group wholesale puts some struct ahead of a type it contains. So the
  # queue emits whatever is fully resolvable and goes round again until a pass
  # adds nothing.
  type PendingStruct = object
    foreign: bool
    full: string
    fields: seq[(string, string)]   ## foreign only
    row: TypeRow                    ## metadata only

  # `runDefines` spans the whole run, not this one module: `Microsoft.UI.WindowId`
  # and `Windows.UI.WindowId` are different types with different full names that
  # both emit as `WindowId`, and they land in different modules. Scoped per
  # module neither one can see the other and an app importing both gets a
  # redefinition. They describe the same bytes, so deferring to the metadata's
  # is right as well as necessary.
  #
  # The comparison is on the short name because that is what reaches the file.
  var queue: seq[PendingStruct]
  for (name, fields) in foreignStructs:
    if part == pInterfaces: break
    if shortName(name) in runDefines: continue
    if name in structNames: continue   # an earlier module already wrote it
    # With a provider, the `Windows.*` half of the foreign table is not ours to
    # declare: winrt already projects those from `Windows.winmd`, and a second
    # declaration here would be a different Nim type with the same layout, so
    # an app importing both packages could not pass a `Point` between them.
    if provider.len > 0 and name.startsWith("Windows."):
      structNames.incl name   # declared over there, but real, so signatures map
      continue
    queue.add PendingStruct(foreign: true, full: name, fields: fields)
  for t in md.types:
    if part == pInterfaces: break
    if not owned(t): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue     # a class, not a value type
    # `Windows.Foundation.HResult` is a struct wrapping an Int32 that `core`
    # already spells as `HRESULT`; emitting it too would put two names for one
    # thing in two modules, and Nim would call every use of it ambiguous.
    if t.fullName in aliasOf: continue
    if t.fullName in structNames: continue
    let (ff, fs) = md.fieldRange(t.index)
    if fs <= ff: continue
    queue.add PendingStruct(foreign: false, full: t.fullName, row: t)

  # Short names of everything the queue intends to define, so a foreign field
  # type can tell "a struct that is still coming" from "a primitive".
  var planned: HashSet[string]
  for p in queue: planned.incl shortName(p.full)
  var emittedStructs: HashSet[string]

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
              valueSpelling.getOrDefault(ft.name, shortName(ft.name))
            elif ft.kind == skEnum: "int32"
            else: nimType(ft)
          if n.len == 0 or n == "void":
            ok = false
            break
          fields.add &"  {escapeIdent(lowerFirst(fname))}*: {n}"
      if not ok:
        stillPending.add p
        continue
      let note =
        if p.foreign: "struct, layout from the Windows SDK headers" else: "struct"
      buf.add &"## {p.full}  ({note})\n"
      buf.add &"type {shortName(p.full)}* {{.pure.}} = object\n"
      for f in fields: buf.add f & "\n"
      # A WinRT struct is plain data, so its bytes are its identity. Without
      # this a map keyed by one — `IMapView<PowerThermalChannelId, ...>` — has
      # no Nim `Table` to become.
      buf.add &"proc hash*(x: {shortName(p.full)}): Hash =\n"
      buf.add  "  hashData(x.unsafeAddr, sizeof(x))\n"
      buf.add "\n"
      structNames.incl p.full
      emittedStructs.incl shortName(p.full)
      structs.inc
      progressed = true
    # A struct that still will not resolve depends on something unmapped; its
    # methods stay unmapped too, which is the intended outcome.
    if not progressed: break
    queue = stillPending

  for t in md.types:
    if part == pValues: break
    if not owned(t): continue
    let delegate = md.isDelegate(t.index)
    if (t.flags and tdInterface) == 0 and not delegate: continue
    if t.index notin iids:
      skippedNoIid.inc
      continue

    let ident = sanitize(t.name)
    if nimIdent("IID_" & ident) in emitted: continue
    emitted.incl nimIdent("IID_" & ident)

    let base = if delegate: 3 else: 6
    buf.add &"## {t.fullName}" & (if delegate: "  (delegate)" else: "") & "\n"
    buf.add &"const IID_{ident}* = " & guidLiteral(iids[t.index]) & "\n"

    let (first, stop) = md.methodRange(t.index)
    var seen = initCountTable[string]()
    var slot = base
    for mi in first ..< stop:
      let rawName = md.str(md.cell(tMethodDef, mi, "Name"))
      if delegate and rawName == ".ctor":
        continue
      let m = sanitize(rawName)
      # Keyed on what Nim sees, not on what the metadata spells, so a genuine
      # overload and a get_/Get pair are both caught. The winner is whichever
      # comes first in the metadata, which is stable across regenerations.
      let key = nimIdent(&"Slot_{ident}_{m}")
      seen.inc key
      let suffix = if seen[key] > 1: $seen[key] else: ""
      let tag = &"{ident}_{m}{suffix}"

      buf.add &"const Slot_{tag}* = {slot}\n"
      slots.inc

      let fn = abiProc(md.methodSignature(mi))
      if fn.len > 0:
        buf.add &"type Fn_{tag}* = {fn}\n"
        typed.inc
      else:
        buf.add &"# Fn_{tag}: signature not mapped\n"
        untyped.inc
      slot.inc

    buf.add "\n"
    interfaces.inc

  if skippedNoIid > 0:
    echo &"  {outPath.extractFilename}: skipped {skippedNoIid} (no GuidAttribute)"
  writeFile(outPath, buf)
  (enums, enumMembers, structs, interfaces, slots, typed, untyped)


when isMainModule:
  if paramCount() < 3:
    quit "usage: generate <winmd> <prefix> <out.nim> [core-import] [provider]\n" &
         "       generate <winmd> --split <out-dir> [core-import]"

  let winmdPath = paramStr(1)
  # Where the generated modules find `HSTRING`, `GUID` and the rest. Inside the
  # winrt package that is a sibling module; for a package that depends on winrt
  # it is `winrt/core`.
  let coreImport = if paramCount() >= 4: paramStr(4) else: "./core"
  # A module that already projects the `Windows.*` types this winmd merely
  # references, so they are imported rather than declared a second time.
  let provider = if paramCount() >= 5: paramStr(5) else: ""
  let md = load(winmdPath)
  let iids = md.guids()

  if paramStr(2) != "--split":
    for t in md.types:
      if t.namespace == paramStr(2) or t.namespace.startsWith(paramStr(2) & "."):
        runDefines.incl shortName(t.fullName)
    let e = emitModule(md, iids, winmdPath, paramStr(2), paramStr(3),
                       coreImport, @[], provider)
    let pct = if e.slots > 0: e.typed * 100 div e.slots else: 0
    echo paramStr(3)
    echo &"  enums      {e.enums}  ({e.enumMembers} members)"
    echo &"  structs    {e.structs}"
    echo &"  interfaces {e.interfaces}"
    echo &"  slots      {e.slots}"
    echo &"  typed      {e.typed}  ({pct}%)"
    echo &"  unmapped   {e.untyped}"
    quit 0

  # `types.nim` first with every enum and struct in the metadata, then one
  # module of interfaces per namespace group over it.
  #
  # The alternative — a self-contained module per group, each importing the
  # groups it reaches into — is what this used to do, and it cannot work:
  # `Windows.Graphics` and `Windows.UI` name each other's structs, Nim has no
  # mutually recursive modules, and the cycle had to be cut by leaving 563
  # signatures untyped. Hoisting the handful of worst offenders into the root
  # module was the same patch applied by hand. Writing the value types once
  # removes the question instead of answering it.
  let outDir = paramStr(3)
  createDir(outDir)

  for t in md.types:
    if t.namespace.startsWith("Windows."): runDefines.incl shortName(t.fullName)

  var total = emitModule(md, iids, winmdPath, "Windows",
                         outDir / "types.nim", coreImport, @[], provider,
                         part = pValues)
  echo &"""  {"types":<16} {total.enums:>5} enums {total.structs:>4} structs"""

  var groups: seq[string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    let g = topGroup(t.namespace)
    if g notin groups: groups.add g
  groups.sort()

  for g in groups:
    let e = emitModule(md, iids, winmdPath, g,
                       outDir / (moduleName(g) & ".nim"), coreImport,
                       @["types"], provider, part = pInterfaces)
    total.interfaces += e.interfaces
    total.slots += e.slots
    total.typed += e.typed
    total.untyped += e.untyped
    let pct = if e.slots > 0: e.typed * 100 div e.slots else: 0
    echo &"  {moduleName(g):<16} {e.interfaces:>5} interfaces " &
         &"{e.slots:>6} slots ({pct}% typed)"

  let pct = if total.slots > 0: total.typed * 100 div total.slots else: 0
  echo ""
  echo &"  {groups.len + 1} modules  {total.enums} enums  {total.structs} structs"
  echo &"  {total.interfaces} interfaces  {total.slots} slots  {pct}% typed  " &
       &"{total.untyped} unmapped"
