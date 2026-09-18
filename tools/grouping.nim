## Which namespace group a type belongs to, and what order the groups can be
## written in.
##
## Both generators need this and must agree on it: the ABI layer writes a
## module per group, and the API layer writes one over each. They ask for
## different graphs, though. At the ABI layer an interface parameter is a bare
## pointer, so only enums and structs create a dependency; at the API layer a
## class parameter is that class's wrapper type, so interfaces create one too.
## `withInterfaces` picks which question is being asked.

import std/[algorithm, sequtils, sets, strformat, strutils, tables]
import ./winmd
import ./nimgen

const tdInterface = 0x20'u32

const rootGroup* = "Windows.Foundation"
  ## Written first, and the home of anything hoisted out of another group.

const hoisted* = [
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

proc groupPlan*(md: WinMd; hoist: seq[string];
                withInterfaces = false): tuple[order: seq[string],
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
    if not withInterfaces and
       ((t.flags and tdInterface) != 0 or md.isDelegate(t.index)): continue
    if md.isEnum(t.index) or md.baseName(t.index) == "":
      # A hoisted type is written by the root module, so every edge that would
      # have pointed at its real group points there instead. Left unadjusted it
      # invents dependencies on `Windows.UI` that the output does not have.
      ownerOf[t.fullName] =
        if t.fullName in hoist: rootGroup else: topGroup(t.namespace)

  var weight: Table[string, CountTable[string]]
  var groups: seq[string]
  proc note(g: string, t: SigType) =
    if t.kind notin {skEnum, skStruct} and
       not (withInterfaces and t.kind == skInterface): return
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
