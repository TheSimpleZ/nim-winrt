## Which structs the most methods depend on, and what it would take to lay one
## out in Nim.
##
## `nim c -r tools/structs.nim <winmd> <namespace-prefix>`
##
## A struct crosses the ABI by value, so a signature naming one cannot be
## generated until Nim knows its exact layout. This counts how many methods
## each struct gates and prints the fields it would need, which is what decides
## whether a type is worth adding to `foreign.nim`. It does not know which
## structs the generator already handles - the point is to rank candidates,
## and `unmapped.nim` reports what is actually still missing.
import std/[os, strformat, strutils, tables, algorithm]
import ./winmd

when isMainModule:
  let md = load(paramStr(1))
  let prefix = paramStr(2)

  var gated = initCountTable[string]()
  var methodsGated = 0
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
        methodsGated.inc
        for n in names: gated.inc n

  echo &"methods taking or returning a struct: {methodsGated}"
  echo ""
  gated.sort()
  var shown = 0
  for name, count in gated:
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
