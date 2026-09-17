import std/[os, strutils, tables]
import ../tools/winmd
when isMainModule:
  let md = load(paramStr(1))
  let st = md.staticInterfaces()
  echo "classes with a StaticAttribute: ", st.len
  var shown = 0
  for t in md.types:
    if t.index in st and shown < 6:
      echo "  ", t.fullName, " -> ", st[t.index].join(", ")
      shown.inc
