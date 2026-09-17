## Show the signature string and computed IID for every generic instantiation
## the metadata actually uses.
##
## `nim c -r tools/piidcheck.nim <winmd> <namespace-prefix>`
##
## The output is what `tests/tgenerics.nim` then checks against a live object:
## a computed IID is either exactly right or matches nothing at all, and only a
## real `QueryInterface` can tell those apart.

import std/[os, strformat, strutils, tables, sets, algorithm]
import ./winmd
import ./piid

const tdInterface = 0x20'u32

when isMainModule:
  let md = load(paramStr(1))
  let prefix = paramStr(2)
  let iids = md.guids()
  let impls = md.interfaceImpls()

  var c = SigContext(md: md)
  c.guidOf = iids
  for t in md.types:
    c.indexOf[t.fullName] = t.index
  for t in md.types:
    if (t.flags and tdInterface) != 0: continue
    for coded in impls.getOrDefault(t.index, @[]):
      let n = md.typeDefOrRefName(coded)
      if n in c.indexOf and c.indexOf[n] in iids:
        c.defaultIface[t.fullName] = n
        break

  # Every distinct instantiation, with how often it turns up.
  var seen = initCountTable[string]()
  var sample = initTable[string, SigType]()

  proc note(t: SigType) =
    if t.kind == skUnsupported and t.name.len > 0 and t.args.len > 0:
      var key = t.name & "<"
      for i, a in t.args:
        if i > 0: key.add ", "
        key.add (if a.name.len > 0: a.name else: $a.kind)
      key.add ">"
      seen.inc key
      if key notin sample: sample[key] = t

  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      let sig = md.methodSignature(mi)
      for p in sig.params: note p
      note sig.returns

  seen.sort()
  var resolved, unresolved = 0
  for key, count in seen:
    let t = sample[key]
    let s = c.instantiationSignature(t)
    if s.len == 0:
      unresolved.inc
      echo &"{count:>4}  {key}"
      echo  "        signature could not be built"
    else:
      resolved.inc
      echo &"{count:>4}  {key}"
      echo &"        {s}"
      echo &"        {c.parameterizedIid(t)}"
  echo ""
  echo &"{resolved} instantiations resolved, {unresolved} not"
