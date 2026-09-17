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
    of skEnum: "int32"         # WinRT enums are int32 on the wire
    of skStruct:
      # A struct crosses by value, so Nim must know its exact layout. Nim emits
      # these as plain C structs, which means the C compiler applies the same
      # x64 ABI that WinUI's own C++ was built with.
      if t.name in foreignEnums: "int32"
      elif t.name in aliasOf: aliasOf[t.name]
      elif t.name in structNames: shortName(t.name)
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

proc abiProc(sig: MethodSig): string =
  ## The full `proc(...)` type for a method, or "" if any part is unmapped.
  var parts = @["self: pointer"]
  for i, p in sig.params:
    let n = nimType(p)
    if n.len == 0 or n == "void": return ""
    parts.add &"{paramName(i, p)}: {n}"
  # The declared return becomes a trailing out-parameter; only `void` has none.
  if sig.returns.kind != skVoid:
    let r = nimType(sig.returns)
    if r.len == 0: return ""
    parts.add &"value: ptr {r}"
  "proc(" & parts.join(", ") & "): HRESULT {.stdcall.}"

type Emission = tuple
  enums, enumMembers, structs, interfaces, slots, typed, untyped: int

proc emitModule(md: WinMd; iids: Table[int, string]; winmdPath, prefix,
                outPath, corePath: string; imports: seq[string];
                hoist: seq[string] = @[]; provider = ""): Emission =
  ## Write one module: every type under `prefix` that no earlier call has
  ## already written.
  ##
  ## `prefix` carries no trailing dot and is matched on whole segments, so
  ## `Windows.Data` takes `Windows.Data` and `Windows.Data.Json` and leaves a
  ## hypothetical `Windows.DataTransfer` alone.
  proc inScope(ns: string): bool =
    ns == prefix or ns.startsWith(prefix & ".")

  proc owned(t: TypeRow): bool =
    ## `hoist` names types that belong to another group but are written here
    ## anyway; see `hoisted`.
    inScope(t.namespace) or t.fullName in hoist

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
  buf.add &"import {corePath}\n"
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
  # `distinct int32` rather than a Nim `enum`: WinRT enums are sparse, are
  # sometimes flags, and sometimes carry two names for one value, none of which
  # a Nim enum permits.
  for t in md.types:
    if not owned(t): continue
    if (t.flags and tdInterface) != 0: continue
    if not md.isEnum(t.index): continue
    let members = md.enumMembers(t.index)
    if members.len == 0: continue
    let ident = sanitize(t.name)
    if ident in emittedEnums: continue
    emittedEnums.incl ident
    enumFullNames.incl t.fullName

    buf.add "## " & t.fullName & "  (enum)\n"
    buf.add "type " & ident & "* = distinct int32\n"
    buf.add "proc `==`*(a, b: " & ident & "): bool {.borrow.}\n"
    buf.add "proc `$`*(v: " & ident & "): string =\n"
    buf.add "  case int32(v)\n"
    var seenValues = initHashSet[int32]()
    for (name, value) in members:
      # Aliases share a value; a `case` may only list it once.
      if asInt32(value) in seenValues: continue
      seenValues.incl asInt32(value)
      buf.add "  of " & $asInt32(value) & "'i32: \"" & name & "\"\n"
    buf.add "  else: \"" & ident & "(\" & $int32(v) & \")\"\n"
    for (name, value) in members:
      buf.add "const " & ident & "_" & sanitize(name) & "* = " & ident &
              "(" & $asInt32(value) & "'i32)\n"
      enumMembers.inc
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
    if not owned(t): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue     # a class, not a value type
    # `Windows.Foundation.HResult` is a struct wrapping an Int32 that `core`
    # already spells as `HRESULT`; emitting it too would put two names for one
    # thing in two modules, and Nim would call every use of it ambiguous.
    if t.fullName in aliasOf: continue
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
            if ft.kind == skEnum and ft.name in enumFullNames: shortName(ft.name)
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


const rootGroup = "Windows.Foundation"
  ## Written first, and the home of anything hoisted out of another group.

const hoisted = [
  ## Types every projection needs that happen to live in a large module.
  ##
  ## `Windows.UI.Color` is the case this exists for: three bytes and an alpha
  ## that anything visual passes around, sitting in a module that is a third of
  ## the package. Pulling it forward costs five lines here and saves everyone
  ## else importing 52,000. The others are the same argument.
  "Windows.UI.Color",
  "Windows.UI.Text.FontWeight",
  "Windows.UI.Core.CorePhysicalKeyStatus",
  "Windows.UI.Xaml.Interop.TypeName",
]

proc topGroup(ns: string): string =
  ## `Windows.Devices.Enumeration.Pnp` -> `Windows.Devices`.
  ##
  ## The split is by the second segment, not by full namespace. 347 namespaces
  ## would be 347 files for no gain — a namespace is a naming convention, not a
  ## unit anyone imports — while 18 groups line up with how the documentation
  ## is organised and how an app actually reaches for things.
  let parts = ns.split('.')
  if parts.len >= 2: parts[0] & "." & parts[1] else: ns

proc moduleName(group: string): string =
  ## `Windows.ApplicationModel` -> `applicationmodel`.
  group.split('.')[^1].toLowerAscii


proc groupPlan(md: WinMd; hoist: seq[string]): tuple[order: seq[string],
                                 deps: Table[string, HashSet[string]]] =
  ## Decide what order the modules go in, and what each one imports.
  ##
  ## A module can only name a type some *earlier* module defined, so the order
  ## is a topological sort of "group A's signatures mention group B's enums and
  ## structs". Interfaces are exempt: at this layer one is a bare `pointer`, so
  ## they never constrain anything.
  ##
  ## The graph is very nearly a DAG — almost every edge points at
  ## `Windows.Foundation` — but `Windows.Graphics` and `Windows.UI` do name
  ## each other's types. A cycle has to be cut somewhere, so the lighter
  ## direction loses: the edge carrying fewer signatures is dropped, those
  ## signatures go out unmapped, and the count is reported rather than
  ## swallowed. Recomputing this from the metadata each run means a future SDK
  ## that adds an edge is handled, not silently mistyped.
  var ownerOf: Table[string, string]
  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    if (t.flags and tdInterface) != 0 or md.isDelegate(t.index): continue
    if md.isEnum(t.index) or md.baseName(t.index) == "":
      # A hoisted type is written by the root module, so every edge that would
      # have pointed at its real group points there instead. Left unadjusted it
      # invents dependencies on `Windows.UI` that the output does not have.
      ownerOf[t.fullName] =
        if t.fullName in hoist: rootGroup else: topGroup(t.namespace)

  var weight: Table[string, CountTable[string]]
  var groups: seq[string]
  proc note(g: string, t: SigType) =
    if t.kind notin {skEnum, skStruct}: return
    let o = ownerOf.getOrDefault(t.name, "")
    if o.len > 0 and o != g:
      if g notin weight: weight[g] = initCountTable[string]()
      weight[g].inc o

  for t in md.types:
    if not t.namespace.startsWith("Windows."): continue
    let g = topGroup(t.namespace)
    if g notin groups: groups.add g
    let (ff, fs) = md.fieldRange(t.index)
    for fi in ff ..< fs: note(g, md.fieldType(fi))
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      let sig = md.methodSignature(mi)
      for p in sig.params: note(g, p)
      note(g, sig.returns)

  groups.sort()
  # The root goes first whatever else happens: it is where hoisted types land,
  # and everything that imports anything imports it.
  groups.keepItIf(it != rootGroup)
  groups.insert(rootGroup, 0)
  # Kahn's algorithm, emitting the group with no outstanding dependencies. On a
  # tie the alphabetically first goes, so the layout is reproducible.
  var remaining = groups
  var cut, cuts = 0
  while remaining.len > 0:
    var pick = -1
    for i, g in remaining:
      if i > 0 and remaining[0] == rootGroup: break
      var blocked = false
      for dep in weight.getOrDefault(g, initCountTable[string]()).keys:
        if dep in remaining and dep != g: blocked = true
      if not blocked:
        pick = i
        break
    if pick < 0:
      # Everything left is in a cycle, so some group has to go before one it
      # depends on. The one to move is whichever owes the *least* overall —
      # sum its outstanding edges, take the smallest total, and drop all of
      # them at once. Cutting the single cheapest edge instead is the obvious
      # thing and the wrong one: it unblocks nobody, so the next pass finds
      # another cycle and cuts again. On this metadata that is the difference
      # between losing one edge and losing four.
      var best = (g: "", n: high(int))
      for g in remaining:
        var owed = 0
        for dep, n in weight.getOrDefault(g, initCountTable[string]()):
          if dep in remaining and dep != g: owed += n
        if owed > 0 and owed < best.n: best = (g, owed)
      doAssert best.g.len > 0, "cyclic group graph with no edge to cut"
      cuts.inc
      for dep in toSeq(weight[best.g].keys):
        if dep in remaining and dep != best.g: weight[best.g].del dep
      cut += best.n
      continue
    let g = remaining[pick]
    result.order.add g
    remaining.delete pick
  if cuts > 0:
    echo &"  {cuts} groups placed ahead of something they reference; " &
         &"{cut} signatures go out untyped"
  for g in result.order:
    var s: HashSet[string]
    for dep in weight.getOrDefault(g, initCountTable[string]()).keys:
      if dep != g: s.incl dep
    result.deps[g] = s


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
                       coreImport, @[], @[], provider)
    let pct = if e.slots > 0: e.typed * 100 div e.slots else: 0
    echo paramStr(3)
    echo &"  enums      {e.enums}  ({e.enumMembers} members)"
    echo &"  structs    {e.structs}"
    echo &"  interfaces {e.interfaces}"
    echo &"  slots      {e.slots}"
    echo &"  typed      {e.typed}  ({pct}%)"
    echo &"  unmapped   {e.untyped}"
    quit 0

  # One module per namespace group, in an order `groupPlan` works out from the
  # metadata, each importing exactly the groups its signatures reach into.
  let outDir = paramStr(3)
  createDir(outDir)

  for t in md.types:
    if t.namespace.startsWith("Windows."): runDefines.incl shortName(t.fullName)

  let plan = groupPlan(md, @hoisted)
  var total: Emission
  for g in plan.order:
    var imports: seq[string]
    for dep in plan.deps[g]: imports.add moduleName(dep)
    imports.sort()
    let e = emitModule(md, iids, winmdPath, g,
                       outDir / (moduleName(g) & ".nim"), coreImport, imports,
                       if g == rootGroup: @hoisted else: newSeq[string]())
    total.enums += e.enums
    total.enumMembers += e.enumMembers
    total.structs += e.structs
    total.interfaces += e.interfaces
    total.slots += e.slots
    total.typed += e.typed
    total.untyped += e.untyped
    let pct = if e.slots > 0: e.typed * 100 div e.slots else: 0
    echo &"  {moduleName(g):<16} {e.enums:>5} enums {e.structs:>4} structs " &
         &"{e.interfaces:>5} interfaces {e.slots:>6} slots ({pct}% typed)"

  let pct = if total.slots > 0: total.typed * 100 div total.slots else: 0
  echo ""
  echo &"  {plan.order.len} modules  {total.enums} enums  {total.structs} structs"
  echo &"  {total.interfaces} interfaces  {total.slots} slots  {pct}% typed  " &
       &"{total.untyped} unmapped"
