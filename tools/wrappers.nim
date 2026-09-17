## Emit an idiomatic Nim API on top of the generated ABI layer.
##
## ```
## nim c -r tools/wrappers.nim <winmd> <namespace-prefix> <out.nim>
## ```
##
## `generate.nim` emits what the ABI *is* — IIDs, slot numbers, raw signatures.
## This emits what a person wants to write: `window.title = "Hi"` rather than a
## QueryInterface, a slot index and a manually released HSTRING.
##
## ## Shape
##
## Every runtime class becomes a Nim object in a real inheritance chain, so a
## derived value passes where a base is expected and an inherited method
## resolves without being emitted again. A method is generated once, on the
## class whose own interfaces declare it. Emitting the full inherited surface
## per class instead would mean 94,521 procs rather than about 4,900, for
## exactly the same API.
##
## The first attempt used `distinct pointer` plus a `converter` to each
## ancestor, which does not scale: Nim weighs every converter in scope at every
## type mismatch, and 1,715 of them took one module from 3.6 seconds to over
## seven minutes to compile.
##
## ## Why every call re-queries
##
## Each wrapper QueryInterfaces the receiver before dispatching, and every
## class-typed argument before passing it. That is not free, but it makes the
## worst bug in this codebase unrepresentable: slots are numbered per
## interface, so reaching one through the wrong interface is not an error, it
## is a silent wrong function or a crash. WinUI calls happen at the speed of a
## person clicking, so correctness wins.

import std/[os, algorithm, strformat, strutils, tables, sets]
import ./winmd
import ./foreign
import ./piid
import ./nimgen

const tdInterface = 0x20'u32

const GenericIidMarker = "##<computed-iids>##\n"
  ## Where the computed IIDs are spliced in. They have to precede every proc
  ## that names one, but are only discovered while those procs are emitted.

const builtinTypeNames = [
  "pointer", "string", "int", "int8", "int16", "int32", "int64", "uint",
  "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64",
  "bool", "char", "byte", "cstring", "seq", "set", "array", "openarray",
  "range", "auto", "any", "typedesc", "void", "natural", "positive"]

func safeMemberName(pascal: string): string =
  ## Lower-case the first letter, unless doing so would shadow a builtin type.
  ##
  ## `PointerRoutedEventArgs.Pointer` is a real property, and `proc pointer*`
  ## makes the word `pointer` ambiguous in every module that imports this one,
  ## including this library's own. Keeping the metadata's capital does not help
  ## either — `Pointer` is also the name of the WinUI class, so the proc would
  ## redefine the type. Hence a suffix: `pointerValue`.
  if pascal.len == 0: return pascal
  let lowered = toLowerAscii(pascal[0]) & pascal[1 .. ^1]
  if lowered.toLowerAscii in builtinTypeNames: lowered & "Value" else: lowered

type
  Ctx = object
    classes: HashSet[string]             ## full names of classes we emit
    enums: HashSet[string]               ## enums the ABI module emits
    ifaceIid: HashSet[string]            ## interfaces that have an IID
    structs: HashSet[string]             ## structs xaml_abi laid out
    aliases: Table[string, string]       ## metadata name -> existing Nim type
    defaultIface: Table[string, string]  ## class -> its default interface

func skipReason(c: Ctx, t: SigType): string =
  ## Why this type has no wrapper spelling. "" means it has one.
  if t.byRef: return "a second out-parameter"
  case t.kind
  of skUnsupported:
    if t.name.len > 0 and t.args.len > 0: "generic: " & shortName(t.name)
    else: "a type variable or function pointer"
  of skArray: "an array"
  of skEnum:
    if t.name in c.enums: "" else: "an enum from another winmd"
  of skInterface:
    if t.name in c.classes or t.name in c.ifaceIid: ""
    else: "an interface from another winmd"
  of skStruct:
    if t.name in foreignEnums or t.name in c.aliases or t.name in c.structs: ""
    else: "a struct with no layout"
  else: ""

func nimTypeOf(c: Ctx, t: SigType): string =
  ## The Nim spelling for a wrapper parameter or result, or "" if unsupported.
  ##
  ## A generic instantiation is deliberately *not* mapped here, even though the
  ## ABI layer spells it `pointer`. At this level a bare pointer would be worse
  ## than nothing: it reads as a typed API while giving none of the safety, and
  ## the honest mapping is a typed collection or an optional, which is work this
  ## does not do yet.
  if t.byRef: return ""   # out-parameters beyond the return value are unmapped
  case t.kind
  of skBool: "bool"
  of skChar: "uint16"
  of skI1: "int8"
  of skU1: "uint8"
  of skI2: "int16"
  of skU2: "uint16"
  of skI4: "int32"
  of skU4: "uint32"
  of skI8: "int64"
  of skU8: "uint64"
  of skF4: "float32"
  of skF8: "float64"
  of skString: "string"
  of skObject: "pointer"
  of skEnum:
    if t.name in c.enums: shortName(t.name) else: ""
  of skInterface:
    # The resolved name is a runtime class for most parameters and a bare
    # interface for the rest. A class becomes its wrapper type; an interface
    # stays a pointer, because there is no wrapper to give it.
    if t.name in c.classes: shortName(t.name)
    elif t.name in c.ifaceIid: "pointer"
    else: ""
  of skStruct:
    # Structs cross by value and `xaml_abi` has already laid out the ones it
    # could, so a wrapper can name them directly — this is what makes `Margin`,
    # `Padding` and `Color` reachable at all.
    if t.name in foreignEnums: "int32"
    elif t.name in c.aliases: c.aliases[t.name]
    elif t.name in c.structs: shortName(t.name)
    else: ""
  else: ""

when isMainModule:
  if paramCount() < 3:
    quit "usage: wrappers <winmd> <namespace-prefix> <out.nim>"

  let
    winmdPath = paramStr(1)
    prefix = paramStr(2)
    outPath = paramStr(3)
    corePath = if paramCount() >= 4: paramStr(4) else: "../core"
    delegatePath = corePath.rsplit('/', 1)[0] & "/delegate"

  let md = load(winmdPath)
  let iids = md.guids()
  let impls = md.interfaceImpls()
  let attrs = md.attributeNames()

  var byName = initTable[string, int]()
  for t in md.types: byName[t.fullName] = t.index

  var c = Ctx()
  for t in md.types:
    if t.index in iids and (t.flags and tdInterface) != 0:
      c.ifaceIid.incl t.fullName
    if t.namespace.startsWith(prefix) and md.isEnum(t.index):
      c.enums.incl t.fullName
  # Mirror what `generate.nim` emitted: the foreign table, plus in-namespace
  # value types. A struct it could not lay out is absent from `xaml_abi`, so a
  # wrapper naming it would not compile.
  for (name, _) in foreignStructs:
    c.structs.incl name
  for (name, nim) in foreignAliases:
    c.aliases[name] = nim
  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    if md.baseName(t.index) != "": continue
    let (ff, fs) = md.fieldRange(t.index)
    if fs > ff: c.structs.incl t.fullName

  # Delegates, so an event can declare the closure it actually wants. A WinRT
  # delegate's shape lives in its own `Invoke`, not in the `add_*` that takes
  # it, so this has to be looked up separately.
  var delegates = initTable[string, seq[SigType]]()
  for t in md.types:
    if not md.isDelegate(t.index): continue
    if t.index notin iids: continue
    let (first, stop) = md.methodRange(t.index)
    for mi in first ..< stop:
      if md.str(md.cell(tMethodDef, mi, "Name")) != "Invoke": continue
      delegates[t.fullName] = md.methodSignature(mi).params
      break

  # Everything needed to compute a parameterised interface's IID. A generic
  # like `TypedEventHandler<Sender, Args>` has no GUID anywhere — WinRT derives
  # one by hashing a signature string — so without this, 235 events cannot be
  # generated at all.
  var sigCtx = SigContext(md: md, guidOf: iids)
  for t in md.types:
    sigCtx.indexOf[t.fullName] = t.index

  # Runtime classes: not interfaces, enums, delegates or plain structs.
  var classOrder: seq[TypeRow]
  for t in md.types:
    if not t.namespace.startsWith(prefix): continue
    if (t.flags and tdInterface) != 0: continue
    if md.isEnum(t.index) or md.isDelegate(t.index): continue
    let own = impls.getOrDefault(t.index, @[])
    if md.baseName(t.index) == "" and own.len == 0: continue
    # WinRT lists a class's default interface first.
    var default = ""
    for coded in own:
      let n = md.typeDefOrRefName(coded)
      if n in c.ifaceIid:
        default = n
        break
    if default.len == 0 and md.baseName(t.index) == "": continue
    c.classes.incl t.fullName
    if default.len > 0:
      c.defaultIface[t.fullName] = default
      sigCtx.defaultIface[t.fullName] = default
    classOrder.add t

  proc ancestorsOf(full: string): seq[string] =
    var cur = md.baseName(byName[full])
    var guard = 0
    while cur.len > 0 and cur in c.classes and guard < 16:
      result.add cur
      cur = md.baseName(byName[cur])
      guard.inc

  var buf = newStringOfCap(8 shl 20)
  buf.add "## Generated by tools/wrappers.nim - do not edit.\n##\n"
  buf.add &"## Source:    {winmdPath.extractFilename}\n"
  buf.add &"## Namespace: {prefix}\n##\n"
  buf.add "## Each class is a Nim object in a real inheritance chain, so an\n"
  buf.add "## inherited method resolves without being emitted again for every\n"
  buf.add "## subclass, and a derived value passes where a base is expected.\n\n"
  buf.add &"import {corePath}\n"
  buf.add "import ./xaml_abi\n"
  buf.add &"import {delegatePath}\n"
  buf.add &"export {corePath.split('/')[^1]}, xaml_abi\n\n"
  buf.add "template withIface(obj: pointer, iid: GUID, what: string,\n"
  buf.add "                   name, body: untyped) =\n"
  buf.add "  ## Dispatch through the interface that declares the method, not\n"
  buf.add "  ## through whichever one the caller happens to hold. Slots are\n"
  buf.add "  ## numbered per interface, so the difference is a wrong function\n"
  buf.add "  ## or a crash, never an error code.\n"
  buf.add "  let name = queryInterface(obj, iid)\n"
  buf.add "  if name.isNil:\n"
  buf.add "    raise newException(WinRtError, \"winui3: object is not a \" & what)\n"
  buf.add "  try:\n"
  buf.add "    body\n"
  buf.add "  finally:\n"
  buf.add "    release(name)\n\n"
  # Activation lives here rather than in `xaml.nim`, which imports this module.
  # It is not called `create`, because `system.create` already exists and the
  # overload-resolution failure that produces names neither of them.
  buf.add """proc takeString*(h: HSTRING): string =
  ## Convert an `[out] HSTRING` to a Nim string and delete it.
  ##
  ## A WinRT method that returns a string hands over ownership: the HSTRING is
  ## the caller's to delete. Reading a string property without this leaks one
  ## per call, which a soak test measures as a flat couple of hundred bytes an
  ## iteration — invisible in a demo and fatal in a program that runs for days.
  result = $h
  discard windowsDeleteString(h)

"""
  buf.add """proc activateAs*(classId: string, iid: GUID): pointer =
  ## Activate a runtime class and narrow it to one of its interfaces.
  ##
  ## The activation reference is dropped once the typed one is held: they name
  ## the same object, and keeping both would leak it.
  let obj = activateInstance(classId)
  result = queryInterface(obj, iid)
  release(obj)
  if result.isNil:
    raise newException(WinRtError, "winui3: " & classId &
      " does not implement the expected interface")

proc composeAs*(classId: string, factoryIid, iid: GUID,
                slot: int): pointer =
  ## Construct a composable runtime class.
  ##
  ## Most of the visual tree is designed to be derived from, and answers
  ## `RoActivateInstance` with `E_NOTIMPL`. Such a class is built through its
  ## factory's `CreateInstance(outer, inner, value)` instead. Passing a nil
  ## `outer` says we are not deriving from it, and the `inner` handed back
  ## carries its own reference that is not ours to keep.
  type FnCompose = proc(self: pointer, outer: pointer, inner: ptr pointer,
                        value: ptr pointer): HRESULT {.abi.}
  let factory = activationFactory(classId, factoryIid)
  var inner, instance: pointer
  try:
    vcall(factory, slot, FnCompose)(factory, nil, inner.addr, instance.addr)
      .check(classId & ".CreateInstance")
  finally:
    release(factory)
  if not inner.isNil and inner != instance:
    release(inner)
  result = queryInterface(instance, iid)
  release(instance)
  if result.isNil:
    raise newException(WinRtError, "winui3: " & classId &
      " does not implement the expected interface")

"""

  # The class hierarchy is Nim's own object inheritance, not `distinct pointer`
  # plus converters.
  #
  # Converters were the obvious first try and are unusable at this scale: Nim
  # considers every converter in scope at every type mismatch, and 1,715 of them
  # took compilation of this one module from 3.6 seconds to over seven minutes.
  # Object subtyping costs nothing at compile time, passes a derived value where
  # a base is expected, and resolves inherited methods — and with `pure` and
  # `inheritable` there is no runtime type field, so each of these is exactly one
  # pointer wide.
  #
  # Bases must be declared before the types that extend them, so this emits by
  # depth.
  # Computed IIDs land here, above every proc that names one. They are only
  # discovered while those procs are emitted, so the block is spliced in at the
  # end.
  buf.add GenericIidMarker
  buf.add "type\n"
  var roots: seq[string]
  var byDepth: seq[(int, TypeRow)]
  for t in classOrder:
    byDepth.add (ancestorsOf(t.fullName).len, t)
  byDepth.sort(proc (a, b: (int, TypeRow)): int = cmp(a[0], b[0]))
  for (_, t) in byDepth:
    let n = shortName(t.fullName)
    let base = md.baseName(t.index)
    if base.len > 0 and base in c.classes:
      buf.add &"  {n}* = object of {shortName(base)}\n"
    else:
      buf.add &"  {n}* {{.inheritable, pure.}} = object\n"
      buf.add "    p*: pointer\n"
      roots.add n
  buf.add "\n"

  # Reference counting, done by the compiler.
  #
  # WinRT is COM: a getter hands back a reference that is the caller's to
  # release. There are 633 such getters here, so leaving that to the caller
  # means a GUI leaks a reference every time it reads a property — unbounded
  # growth in exactly the long-running tray-style app this is meant for.
  #
  # Nim's `=destroy` and `=copy` on the *root* of each hierarchy are inherited
  # by every derived type, so one pair per root covers all 894 classes and the
  # objects stay one pointer wide.
  for r in roots:
    buf.add &"proc `=destroy`*(x: var {r}) =\n"
    buf.add "  if x.p != nil: releaseIfLive(x.p)\n"
    buf.add &"proc `=copy`*(dst: var {r}, src: {r}) =\n"
    buf.add "  if dst.p == src.p: return\n"
    buf.add "  `=destroy`(dst)\n"
    buf.add "  wasMoved(dst)\n"
    buf.add "  dst.p = src.p\n"
    buf.add "  if dst.p != nil: addRefIfLive(dst.p)\n"
    buf.add &"proc `=sink`*(dst: var {r}, src: {r}) =\n"
    buf.add "  # A move transfers the reference, so neither count changes.\n"
    buf.add "  `=destroy`(dst)\n"
    buf.add "  wasMoved(dst)\n"
    buf.add "  dst.p = src.p\n"
  buf.add "\n"

  buf.add """proc owned*[T](p: pointer): T =
  ## Adopt a pointer that is already ours — anything a getter, a factory or a
  ## QueryInterface returned, all of which hand over a reference.
  ##
  ## The counterpart of `borrowed`. Between them they cover every way a raw
  ## pointer becomes an object, and saying which one applies is the whole of
  ## the lifetime contract: adopt something you were only lent and the wrapper
  ## releases a reference it never took.
  T(p: p)

proc borrowed*[T](p: pointer): T =
  ## Wrap a pointer we were *lent*, such as an event's sender or arguments.
  ##
  ## The wrapper releases on destruction, so adopting a borrowed pointer
  ## without this would over-release it and free an object still in use. A
  ## pointer that is already ours — anything a getter or a factory returned —
  ## is wrapped directly instead.
  if not p.isNil: addRef(p)
  T(p: p)

"""

  for t in classOrder:
    let n = shortName(t.fullName)
    buf.add &"func isNil*(x: {n}): bool {{.inline.}} = x.p.isNil\n"
  buf.add "\n"

  # Computed IIDs, emitted as constants at the end and referred to by name.
  # Keyed by the IID itself so two spellings of the same instantiation share
  # one constant.
  var genericIids: Table[string, string]
  var genericIidOrder: seq[(string, string)]
  var usedIidNames: HashSet[string]

  proc genericIidConst(iid: string, t: SigType): string =
    ## The name of a constant holding `iid`, minting one if needed.
    if iid in genericIids: return genericIids[iid]
    var base = "IID_" & shortName(t.name)
    for a in t.args:
      base.add "_"
      base.add (if a.name.len > 0: shortName(a.name)
                elif a.kind == skObject: "Object"
                else: sanitize(($a.kind)[2 .. ^1]))
    # Two instantiations can reduce to the same short spelling — different
    # namespaces, same type name — so the name is disambiguated rather than
    # silently reused for the wrong GUID.
    var name = base
    var n = 2
    while name in usedIidNames:
      name = base & $n
      n.inc
    usedIidNames.incl name
    genericIids[iid] = name
    genericIidOrder.add (name, iid)
    name

  var procs, skipped, ctors, events = 0
  var skipReasons = initCountTable[string]()

  proc noteSkip(sig: MethodSig) =
    ## Record the first thing about a signature that has no wrapper spelling.
    for p in sig.params:
      let r = c.skipReason(p)
      if r.len > 0:
        skipReasons.inc r
        return
    let r = c.skipReason(sig.returns)
    skipReasons.inc (if r.len > 0: r else: "already emitted, or a duplicate name")

  for t in classOrder:
    let cls = shortName(t.fullName)
    var emitted = initHashSet[string]()

    let a = attrs.getOrDefault(t.index, @[])
    if t.fullName in c.defaultIface:
      let iface = shortName(c.defaultIface[t.fullName])
      if "ActivatableAttribute" in a:
        buf.add &"proc new{cls}*(): {cls} =\n"
        buf.add &"  ## Activate a `{t.fullName}`.\n"
        buf.add &"  owned[{cls}](activateAs(\"{t.fullName}\", IID_{iface}))\n\n"
        ctors.inc
      elif "ComposableAttribute" in a:
        # A composable class refuses RoActivateInstance and is built through
        # `I<Name>Factory.CreateInstance`. The slot is read rather than assumed
        # to be 6, since a factory may declare other methods first.
        let factoryFull = t.namespace & ".I" & t.name & "Factory"
        if factoryFull in c.ifaceIid and factoryFull in byName:
          let (first, stop) = md.methodRange(byName[factoryFull])
          var slot = -1
          for mi in first ..< stop:
            if md.str(md.cell(tMethodDef, mi, "Name")) == "CreateInstance":
              slot = 6 + (mi - first)
              break
          if slot >= 0:
            let fac = shortName(factoryFull)
            buf.add &"proc new{cls}*(): {cls} =\n"
            buf.add &"  ## Compose a `{t.fullName}`.\n"
            buf.add &"  owned[{cls}](composeAs(\"{t.fullName}\", IID_{fac},\n"
            buf.add &"                     IID_{iface}, {slot}))\n\n"
            ctors.inc

    for coded in impls.getOrDefault(t.index, @[]):
      let ifaceFull = md.typeDefOrRefName(coded)
      if ifaceFull notin c.ifaceIid or ifaceFull notin byName: continue
      let iface = shortName(ifaceFull)
      let (first, stop) = md.methodRange(byName[ifaceFull])
      var seen = initCountTable[string]()
      for mi in first ..< stop:
        let raw = md.str(md.cell(tMethodDef, mi, "Name"))
        seen.inc sanitize(raw)
        let dup = seen[sanitize(raw)]
        let tag = &"{iface}_{sanitize(raw)}" & (if dup > 1: $dup else: "")

        # An event is a pair: `add_X(handler) -> token` and `remove_X(token)`.
        # The handler's shape comes from the delegate's own `Invoke`, so the
        # generated proc can take a properly typed Nim closure.
        if raw.startsWith("add_"):
          let sigE = md.methodSignature(mi)
          let evName = sanitize(raw[4 .. ^1])
          # The handler is either a delegate declared in this winmd, or a
          # `TypedEventHandler<S, A>` / `EventHandler<A>` — a parameterised
          # delegate whose IID has to be computed. Both end up as a two-argument
          # Invoke, which is the vtable `delegate.nim` implements.
          var handlerArgs: seq[SigType]
          var handlerIid = ""          # the expression naming its IID
          if sigE.params.len == 1:
            let h = sigE.params[0]
            if h.kind == skInterface and h.name in delegates:
              handlerArgs = delegates[h.name]
              handlerIid = "IID_" & shortName(h.name)
            elif h.kind == skUnsupported and h.args.len > 0:
              let computed = sigCtx.parameterizedIid(h)
              if computed.len > 0:
                # `TypedEventHandler<S, A>.Invoke(S, A)`, and
                # `EventHandler<A>.Invoke(Object, A)`.
                handlerArgs =
                  if h.args.len == 2: h.args
                  else: @[SigType(kind: skObject), h.args[0]]
                handlerIid = genericIidConst(computed, h)

          if handlerIid.len > 0:
            if handlerArgs.len == 2:
              let argsType =
                if handlerArgs[1].name in c.classes: shortName(handlerArgs[1].name)
                else: "pointer"
              let dlgName = handlerIid
              let key = "on" & evName & "/handler"
              if key notin emitted:
                emitted.incl key
                buf.add &"proc on{evName}*(self: {cls},\n"
                buf.add &"    handler: proc(sender: pointer, args: {argsType})): " &
                        "EventRegistrationToken {.discardable.} =\n"
                buf.add &"  ## {t.fullName}.{raw}\n"
                buf.add "  ##\n"
                buf.add "  ## The token is what `remove" & evName &
                        "` needs. The delegate is released here because the\n"
                buf.add "  ## event source took its own reference.\n"
                buf.add &"  withIface(self.p, IID_{iface}, \"{iface}\", it):\n"
                buf.add &"    let cb = newEventDelegate({dlgName},\n"
                if argsType == "pointer":
                  buf.add "      proc(s, a: pointer) = handler(s, a))\n"
                else:
                  buf.add "      proc(s, a: pointer) = handler(s, " &
                          &"borrowed[{argsType}](a)))\n"
                buf.add "    try:\n"
                buf.add &"      vcall(it, Slot_{tag}, Fn_{tag})(it, cb, result.addr)\n"
                buf.add &"        .check(\"{cls}.{raw}\")\n"
                buf.add "    finally:\n"
                buf.add "      release(cb)\n\n"
                events.inc
                continue
          skipped.inc
          continue

        if raw.startsWith("remove_"):
          let sigE = md.methodSignature(mi)
          let evName = sanitize(raw[7 .. ^1])
          if sigE.params.len == 1 and sigE.params[0].kind == skStruct and
             sigE.params[0].name in c.structs:
            let key = "remove" & evName & "/token"
            if key notin emitted:
              emitted.incl key
              buf.add &"proc remove{evName}*(self: {cls}, " &
                      "token: EventRegistrationToken) =\n"
              buf.add &"  ## {t.fullName}.{raw}\n"
              buf.add &"  withIface(self.p, IID_{iface}, \"{iface}\", it):\n"
              buf.add &"    vcall(it, Slot_{tag}, Fn_{tag})(it, token)" &
                      &".check(\"{cls}.{raw}\")\n\n"
              events.inc
              continue
          skipped.inc
          continue

        let sig = md.methodSignature(mi)
        let isGet = raw.startsWith("get_")
        let isPut = raw.startsWith("put_")

        # Map every part before emitting any of it.
        var argTypes: seq[string]
        var ok = true
        for p in sig.params:
          let n = c.nimTypeOf(p)
          if n.len == 0:
            ok = false
            break
          argTypes.add n
        if not ok:
          skipped.inc
          noteSkip(sig)
          continue
        let retType =
          if sig.returns.kind == skVoid: ""
          else: c.nimTypeOf(sig.returns)
        if sig.returns.kind != skVoid and retType.len == 0:
          skipped.inc
          noteSkip(sig)
          continue

        let bare =
          if isGet or isPut: safeMemberName(sanitize(raw[4 .. ^1]))
          else: safeMemberName(sanitize(raw))
        let name = if isPut: "`" & bare & "=`" else: escapeIdent(bare)
        let key = name & "/" & argTypes.join(",")
        if key in emitted:
          skipped.inc
          continue
        emitted.incl key

        var params = @[&"self: {cls}"]
        for i, at in argTypes:
          let pn = if isPut: "value" else: &"a{i + 1}"
          params.add &"{pn}: {at}"

        # A class argument needs a QueryInterface of its own, and a string
        # needs an HSTRING; both open a scope, so the body is built up as
        # lines with a running indent.
        var lines: seq[string]
        var callArgs = @["it"]
        var indent = "  "
        lines.add &"{indent}withIface(self.p, IID_{iface}, \"{iface}\", it):"
        indent.add "  "
        for i, p in sig.params:
          let pn = if isPut: "value" else: &"a{i + 1}"
          case p.kind
          of skString:
            lines.add &"{indent}withHString({pn}, h{i}):"
            indent.add "  "
            callArgs.add &"h{i}"
          of skInterface:
            if p.name in c.classes:
              let want = c.defaultIface.getOrDefault(p.name, "")
              if want.len == 0:
                ok = false
                break
              let wi = shortName(want)
              lines.add &"{indent}withIface({pn}.p, IID_{wi}, \"{wi}\", p{i}):"
              indent.add "  "
              callArgs.add &"p{i}"
            else:
              callArgs.add pn
          of skEnum:
            callArgs.add &"int32({pn})"
          else:
            callArgs.add pn
        if not ok:
          skipped.inc
          continue

        let what = &"{cls}.{raw}"
        if sig.returns.kind == skVoid:
          lines.add &"{indent}vcall(it, Slot_{tag}, Fn_{tag})(" &
                    callArgs.join(", ") & &").check(\"{what}\")"
        else:
          # The declared return is a trailing out-parameter at the ABI.
          case sig.returns.kind
          of skString: lines.add &"{indent}var tmp: HSTRING"
          of skInterface, skObject: lines.add &"{indent}var tmp: pointer"
          of skEnum: lines.add &"{indent}var tmp: int32"
          else: lines.add &"{indent}var tmp: {retType}"
          lines.add &"{indent}vcall(it, Slot_{tag}, Fn_{tag})(" &
                    callArgs.join(", ") & &", tmp.addr).check(\"{what}\")"
          case sig.returns.kind
          of skString: lines.add &"{indent}result = takeString(tmp)"
          of skEnum: lines.add &"{indent}result = {retType}(tmp)"
          of skInterface:
            if sig.returns.name in c.classes:
              lines.add &"{indent}result = owned[{retType}](tmp)"
            else:
              lines.add &"{indent}result = tmp"
          else: lines.add &"{indent}result = tmp"

        buf.add &"proc {name}*(" & params.join(", ") & ")" &
                (if retType.len > 0: ": " & retType else: "") & " =\n"
        buf.add &"  ## {t.fullName}.{raw}\n"
        for l in lines: buf.add l & "\n"
        buf.add "\n"
        procs.inc

  # The constants go above everything that names them. `buf` is built in one
  # pass, so they are spliced in at the marker rather than appended.
  var iidBlock = ""
  if genericIidOrder.len > 0:
    iidBlock.add "# IIDs of parameterised interfaces, computed from a signature\n"
    iidBlock.add "# string rather than read from metadata - see tools/piid.nim.\n"
    for (name, iid) in genericIidOrder:
      iidBlock.add "const " & name & "* = " & guidLiteral(iid) & "\n"
    iidBlock.add "\n"
  buf = buf.replace(GenericIidMarker, iidBlock)

  writeFile(outPath, buf)
  echo outPath
  echo &"  classes    {classOrder.len}"
  echo &"  procs      {procs}  (constructors {ctors})"
  echo &"  events     {events}"
  echo &"  skipped    {skipped}"
  skipReasons.sort()
  for reason, count in skipReasons:
    echo &"    {count:>5}  {reason}"
