## What, specifically, is still unmapped — and why.
##
## `nim c -r tools/unmapped.nim <winmd> <namespace-prefix>`
##
## "2% of signatures" is not an actionable number. This groups every method the
## ABI generator left untyped by the *shape* that stopped it, so the remaining
## work can be judged one shape at a time rather than as a percentage.
##
## It also counts, separately, the methods that are typed only because a
## generic instantiation crosses the ABI as a bare pointer. Those compile and
## call correctly - `IVector<T>` is an interface pointer like any other - but
## the type says nothing, and they are where a typed collection layer would
## pay off.

import std/[os, strformat, strutils, tables, sets, algorithm, sequtils]
import ./winmd
import ./foreign

const tdInterface = 0x20'u32

func shortName(full: string): string =
  let dot = full.rfind('.')
  if dot >= 0: full[dot + 1 .. ^1] else: full

when isMainModule:
  let md = load(paramStr(1))
  let prefix = paramStr(2)
  let iids = md.guids()

  # Mirror what generate.nim can lay out, so "unmapped" means the same thing.
  var structs: HashSet[string]
  var enums: HashSet[string]
  for (name, _) in foreignStructs: structs.incl name
  for (name, _) in foreignAliases: structs.incl name
  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    if md.isEnum(t.index):
      enums.incl t.fullName
      continue
    if (t.flags and tdInterface) != 0: continue
    if md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue
    let (ff, fs) = md.fieldRange(t.index)
    if fs > ff: structs.incl t.fullName

  proc reasonFor(t: SigType): string =
    ## Why this one type cannot be spelled in Nim yet. "" means it can.
    case t.kind
    of skStruct:
      if t.name in foreignEnums or t.name in structs: ""
      elif t.name.startsWith("Windows."):
        "struct defined in another winmd: " & t.name
      else:
        "struct with an unmappable field: " & t.name
    of skArray:
      "array of " & (if t.name.len > 0: shortName(t.name) else: "a primitive")
    of skUnsupported:
      # A named instantiation is an interface pointer on the wire, and
      # `generate.nim` spells it `pointer`, so it does not stop a signature.
      # Anything else here - a type variable, a function pointer - has no
      # shape at all.
      if t.name.len > 0 and t.args.len > 0: ""
      else: "pointer or type variable"
    of skEnum:
      if t.name in enums: "" else: "enum from another winmd: " & t.name
    else: ""

  func opaqueGeneric(t: SigType): string =
    ## Typed, but only as `pointer`.
    if t.kind == skUnsupported and t.name.len > 0 and t.args.len > 0:
      shortName(t.name)
    else: ""

  var byReason = initCountTable[string]()
  var byGeneric = initCountTable[string]()
  var examples = initTable[string, seq[string]]()
  var total, blocked, opaque = 0

  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    let delegate = md.isDelegate(t.index)
    if (t.flags and tdInterface) == 0 and not delegate: continue
    if t.index notin iids: continue
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      let raw = md.str(md.cell(tMethodDef, mi, "Name"))
      if delegate and raw == ".ctor": continue
      total.inc
      let sig = md.methodSignature(mi)

      var reasons, generics: seq[string]
      # `byRef` is not a blocker: the generator spells it `ptr T`. Only the
      # underlying shape can stop a signature.
      for p in sig.params & @[sig.returns]:
        let r = reasonFor(p)
        if r.len > 0: reasons.add r
        let g = opaqueGeneric(p)
        if g.len > 0: generics.add g

      if reasons.len == 0 and generics.len > 0:
        opaque.inc
        for g in generics.deduplicate: byGeneric.inc g

      if reasons.len > 0:
        blocked.inc
        for r in reasons.deduplicate:
          byReason.inc r
          if examples.getOrDefault(r, @[]).len < 3:
            examples.mgetOrPut(r, @[]).add shortName(t.fullName) & "." & raw

  echo &"methods            {total}"
  echo &"untyped            {blocked}  ({blocked * 100 div max(total, 1)}%)"
  echo &"typed as pointer   {opaque}  (a generic instantiation)"
  echo ""
  byReason.sort()
  var shown = 0
  for reason, count in byReason:
    shown += count
    echo &"{count:>5}  {reason}"
    for e in examples.getOrDefault(reason, @[]):
      echo &"         e.g. {e}"
  echo ""
  echo &"       {shown} reasons across {blocked} untyped methods"
  echo ""
  echo "typed as an opaque pointer, by generic:"
  byGeneric.sort()
  for name, count in byGeneric:
    echo &"{count:>5}  {name}"
