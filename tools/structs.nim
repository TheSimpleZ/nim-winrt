## Which structs block the most methods, and can they be laid out?
##
## `nim c -r tools/structs.nim <winmd> <namespace-prefix>`
import std/[os, strformat, strutils, tables, algorithm]
import ./winmd

when isMainModule:
  let md = load(paramStr(1))
  let prefix = paramStr(2)

  var blocked = initCountTable[string]()
  var methodsBlocked = 0
  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      let sig = md.methodSignature(mi)
      var names: seq[string]
      for p in sig.params:
        if p.kind == skStruct: names.add p.name
      if sig.returns.kind == skStruct: names.add sig.returns.name
      if names.len > 0:
        methodsBlocked.inc
        for n in names: blocked.inc n

  echo &"methods blocked by a struct: {methodsBlocked}"
  echo ""
  blocked.sort()
  var shown = 0
  for name, count in blocked:
    if shown >= 20: break
    shown.inc
    # Can it be laid out from primitives alone?
    var layout = "unknown type"
    let idx = md.typeIndexByName().getOrDefault(name, 0)
    if idx > 0:
      var fields: seq[string]
      var simple = true
      let (ff, fs) = md.fieldRange(idx)
      for fi in ff ..< fs:
        let ft = md.fieldType(fi)
        let n = md.str(md.cell(tField, fi, "Name"))
        case ft.kind
        of skBool: fields.add n & ": bool"
        of skI1: fields.add n & ": int8"
        of skU1: fields.add n & ": uint8"
        of skI2: fields.add n & ": int16"
        of skU2: fields.add n & ": uint16"
        of skI4: fields.add n & ": int32"
        of skU4: fields.add n & ": uint32"
        of skI8: fields.add n & ": int64"
        of skU8: fields.add n & ": uint64"
        of skF4: fields.add n & ": float32"
        of skF8: fields.add n & ": float64"
        of skEnum: fields.add n & ": " & ft.name & " (enum)"
        of skStruct: fields.add n & ": " & ft.name & " (struct)"
        else:
          simple = false
          fields.add n & ": ?" & $ft.kind
      layout = (if simple: "" else: "NOT SIMPLE ") & fields.join(", ")
    echo &"{count:>5}  {name}"
    echo &"       {layout}"
