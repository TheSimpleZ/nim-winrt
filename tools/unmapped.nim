## What, specifically, is still unmapped — and why.
##
## `nim c -r tools/unmapped.nim <winmd> <namespace-prefix>`
##
## "7% of signatures" is not an actionable number. This groups every method the
## ABI generator skipped by the *shape* that stopped it, so the remaining work
## can be judged one shape at a time rather than as a percentage.

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
      if t.name.len > 0: "generic: " & shortName(t.name)
      else: "pointer or type variable"
    of skEnum:
      if t.name in enums: "" else: "enum from another winmd: " & t.name
    else: ""

  var byReason = initCountTable[string]()
  var examples = initTable[string, seq[string]]()
  var total, blocked = 0

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

      var reasons: seq[string]
      # `byRef` is not a blocker: the generator spells it `ptr T`. Only the
      # underlying shape can stop a signature.
      for p in sig.params:
        let r = reasonFor(p)
        if r.len > 0: reasons.add r
      let rr = reasonFor(sig.returns)
      if rr.len > 0: reasons.add rr

      if reasons.len > 0:
        blocked.inc
        for r in reasons.deduplicate:
          byReason.inc r
          if examples.getOrDefault(r, @[]).len < 3:
            examples.mgetOrPut(r, @[]).add shortName(t.fullName) & "." & raw

  echo &"methods            {total}"
  echo &"blocked            {blocked}  ({blocked * 100 div max(total, 1)}%)"
  echo ""
  byReason.sort()
  var shown = 0
  for reason, count in byReason:
    shown += count
    echo &"{count:>5}  {reason}"
    for e in examples.getOrDefault(reason, @[]):
      echo &"         e.g. {e}"
  echo ""
  echo &"       {shown} reasons across {blocked} blocked methods"
