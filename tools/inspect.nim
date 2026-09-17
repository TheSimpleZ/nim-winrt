## Ad-hoc metadata questions: `nim c -r tools/inspect.nim <winmd> <type name>`.
import std/[os, strutils, tables]
import ./winmd

when isMainModule:
  let md = load(paramStr(1))
  let want = paramStr(2)
  let impls = md.interfaceImpls()
  let attrs = md.attributeNames()
  for t in md.types:
    if t.name != want and t.fullName != want: continue
    echo t.fullName
    echo "  flags     0x", toHex(t.flags, 8)
    echo "  extends   ", md.baseName(t.index)
    echo "  attrs     ", attrs.getOrDefault(t.index, @[]).join(", ")
    echo "  interfaces:"
    for coded in impls.getOrDefault(t.index, @[]):
      echo "    ", md.typeDefOrRefName(coded)
