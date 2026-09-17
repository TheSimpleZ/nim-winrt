## How big is the wrapper surface, really? Measure before choosing a shape.
import std/[os, strutils, tables, sets]
import ./winmd

const tdInterface = 0x20'u32

when isMainModule:
  let md = load(paramStr(1))
  let prefix = paramStr(2)
  let impls = md.interfaceImpls()
  let attrs = md.attributeNames()
  var byName = initTable[string, int]()
  for t in md.types: byName[t.fullName] = t.index

  var classes, activatable, composable, staticOnly = 0
  var ownMethods, chainMethods, maxDepth, totalDepth = 0

  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index): continue
    if md.isDelegate(t.index): continue
    if md.baseName(t.index) == "" and impls.getOrDefault(t.index, @[]).len == 0:
      continue        # structs and attributes
    classes.inc
    let a = attrs.getOrDefault(t.index, @[])
    if "ActivatableAttribute" in a: activatable.inc
    if "ComposableAttribute" in a: composable.inc
    if "StaticAttribute" in a and "ActivatableAttribute" notin a and
       "ComposableAttribute" notin a: staticOnly.inc

    # own interfaces
    for coded in impls.getOrDefault(t.index, @[]):
      let n = md.typeDefOrRefName(coded)
      if n in byName:
        let (f, s) = md.methodRange(byName[n])
        ownMethods += s - f

    # walk the base chain
    var depth = 0
    var cur = md.baseName(t.index)
    var seen = initHashSet[string]()
    while cur.len > 0 and cur in byName and cur notin seen:
      seen.incl cur
      depth.inc
      for coded in impls.getOrDefault(byName[cur], @[]):
        let n = md.typeDefOrRefName(coded)
        if n in byName:
          let (f, s) = md.methodRange(byName[n])
          chainMethods += s - f
      cur = md.baseName(byName[cur])
    totalDepth += depth
    if depth > maxDepth: maxDepth = depth

  echo "classes            ", classes
  echo "  activatable      ", activatable
  echo "  composable       ", composable
  echo "  static only      ", staticOnly
  echo "methods on own interfaces        ", ownMethods
  echo "methods inherited via base chain ", chainMethods
  echo "  (per-class expansion total)    ", ownMethods + chainMethods
  echo "max base depth     ", maxDepth
  echo "avg base depth     ", (if classes > 0: totalDepth / classes else: 0.0)
