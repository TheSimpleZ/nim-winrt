## Inspect a `.winmd`. Used to verify the reader against known-good values
## before anything is generated from it.
##
## ```
## nim c -r tools/dump.nim <path.winmd> [TypeName ...]
## ```

import std/[os, strformat, tables]
import ./winmd

when isMainModule:
  if paramCount() < 1:
    quit "usage: dump <path.winmd> [TypeName ...]"

  let md = load(paramStr(1))
  let g = md.guids()

  echo &"tables      {md.rows.len}"
  echo &"typedefs    {md.rows.getOrDefault(tTypeDef, 0)}"
  echo &"methods     {md.rows.getOrDefault(tMethodDef, 0)}"
  echo &"with a GUID {g.len}"
  echo ""

  var wanted: seq[string]
  for i in 2 .. paramCount(): wanted.add paramStr(i)

  if wanted.len == 0:
    # No arguments: show the namespaces and how much lives in each, which is
    # the first thing worth knowing about an unfamiliar winmd.
    var counts = initCountTable[string]()
    for t in md.types:
      if t.namespace.len > 0: counts.inc t.namespace
    counts.sort()
    var shown = 0
    for ns, n in counts:
      echo &"  {n:5}  {ns}"
      shown.inc
      if shown >= 25: break
    quit(0)

  for t in md.types:
    if t.fullName in wanted:
      let delegate = md.isDelegate(t.index)
      echo t.fullName & (if delegate: "  (delegate)" else: "")
      echo &"  IID {g.getOrDefault(t.index, \"<none>\")}"
      # WinRT interfaces begin with IInspectable's six slots; a delegate
      # derives from IUnknown, so it begins after three — and its `.ctor` is
      # metadata, not a vtable entry.
      var slot = if delegate: 3 else: 6
      for name in md.methodNames(t.index):
        if delegate and name == ".ctor": continue
        echo &"  [{slot}] {name}"
        slot.inc
      echo ""
