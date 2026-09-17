## The IID of a parameterised interface, computed.
##
## `IVector<UIElement>` has no GUID in any metadata file. WinRT derives one:
## build a *signature string* describing the instantiation, then take a version-5
## UUID of it under a fixed namespace. Every projection — C++/WinRT, C#/WinRT,
## windows-rs — does exactly this, and it is the only way to QueryInterface for
## a generic at all.
##
## ## The signature string
##
## Each type has a spelling, given in the Windows Runtime ABI documentation:
##
##   Int32              i4          String    string
##   UInt32             u4          Guid      g16
##   Boolean            b1          Object    cinterface(IInspectable)
##   interface          {iid}       delegate  delegate({iid})
##   enum               enum(Name;underlying)
##   struct             struct(Name;field;field;...)
##   runtime class      rc(Name;defaultInterfaceSignature)
##   parameterised      pinterface({generic-iid};arg;arg;...)
##
## A runtime class is spelled in terms of its *default* interface, which is why
## this needs the class-to-interface map rather than names alone.
##
## ## Getting it wrong is silent
##
## A mistyped signature yields a well-formed GUID that no object implements, so
## `QueryInterface` simply answers `E_NOINTERFACE` and the call site looks like
## an unsupported feature rather than a wrong hash. The only trustworthy check
## is at runtime, against a real object — `tests/tgenerics.nim` computes
## `IVector<UIElement>` and asks a live `Panel.Children` for it.

import std/[strutils, sha1, tables]
import ./winmd
import ./foreign

const
  ## {11f47ad5-7b73-42c0-abae-878b1e16adee} — the namespace every parameterised
  ## interface IID is generated under.
  pinterfaceNamespace = [
    0x11'u8, 0xf4, 0x7a, 0xd5, 0x7b, 0x73, 0x42, 0xc0,
    0xab, 0xae, 0x87, 0x8b, 0x1e, 0x16, 0xad, 0xee]

type
  SigContext* = object
    ## What the signature of a type argument can depend on.
    guidOf*: Table[int, string]          ## TypeDef row -> declared IID
    indexOf*: Table[string, int]         ## full name -> TypeDef row
    defaultIface*: Table[string, string] ## class -> its default interface
    md*: WinMd

const primitiveSig = {
  "float32": "f4", "float64": "f8", "int8": "i1", "uint8": "u1",
  "int16": "i2", "uint16": "u2", "int32": "i4", "uint32": "u4",
  "int64": "i8", "uint64": "u8", "bool": "b1", "HSTRING": "string",
  "GUID": "g16"}.toTable

let foreignStructSig = block:
  ## Signatures for the structs `foreign.nim` describes, derived from the same
  ## field lists the layouts come from — so the two cannot drift apart.
  var byShort = initTable[string, string]()   # short name -> full name
  for (name, _) in foreignStructs:
    byShort[name.rsplit('.', 1)[^1]] = name
  var sigs = initTable[string, string]()
  # In declaration order, so a struct's own fields are already known.
  for (name, fields) in foreignStructs:
    var parts: seq[string]
    var ok = true
    for (_, nimType) in fields:
      if nimType in primitiveSig:
        parts.add primitiveSig[nimType]
      elif nimType in byShort and byShort[nimType] in sigs:
        parts.add sigs[byShort[nimType]]
      else:
        ok = false
        break
    if ok and parts.len > 0:
      sigs[name] = "struct(" & name & ";" & parts.join(";") & ")"
  sigs

let foreignGenericIid = block:
  var t = initTable[string, string]()
  for (name, iid) in foreignGenerics: t[name] = iid
  t

func guidToSignature(iid: string): string =
  ## `{ABCD-...}` as the lower-case braced form the signature string uses.
  "{" & iid.strip(chars = {'{', '}'}).toLowerAscii & "}"

proc signatureOf*(c: SigContext, t: SigType): string =
  ## The signature string for one type, or "" if it cannot be described.
  case t.kind
  of skBool: "b1"
  of skChar: "c2"
  of skI1: "i1"
  of skU1: "u1"
  of skI2: "i2"
  of skU2: "u2"
  of skI4: "i4"
  of skU4: "u4"
  of skI8: "i8"
  of skU8: "u8"
  of skF4: "f4"
  of skF8: "f8"
  of skString: "string"
  of skObject: "cinterface(IInspectable)"
  of skEnum:
    # WinRT enums are either signed or unsigned 32-bit, and the signature says
    # which. Flags enums are the unsigned ones.
    if t.name in foreignEnums:
      "enum(" & t.name & ";" &
        (if t.name in foreignFlagEnums: "u4" else: "i4") & ")"
    else:
      let idx = c.indexOf.getOrDefault(t.name, 0)
      if idx == 0: ""
      else:
        # The first field of an enum TypeDef is the compiler-generated
        # `value__`, whose type is the backing type the signature needs.
        var underlying = "i4"
        let (ff, fs) = c.md.fieldRange(idx)
        for fi in ff ..< fs:
          let ft = c.md.fieldType(fi)
          if ft.kind == skU4:
            underlying = "u4"
            break
          if ft.kind == skI4:
            break
        "enum(" & t.name & ";" & underlying & ")"
  of skStruct:
    if t.name == "System.Guid": "g16"
    elif t.name == "Windows.Foundation.HResult":
      # Aliased to `HRESULT` for emission, but still a struct in a signature.
      "struct(Windows.Foundation.HResult;i4)"
    elif t.name in foreignEnums:
      # An unresolvable enum arrives here rather than as skEnum.
      "enum(" & t.name & ";" &
        (if t.name in foreignFlagEnums: "u4" else: "i4") & ")"
    elif t.name in foreignStructSig: foreignStructSig[t.name]
    else:
      let idx = c.indexOf.getOrDefault(t.name, 0)
      if idx == 0: ""
      else:
        var parts: seq[string]
        let (ff, fs) = c.md.fieldRange(idx)
        for fi in ff ..< fs:
          let f = c.signatureOf(c.md.fieldType(fi))
          if f.len == 0: return ""
          parts.add f
        if parts.len == 0: ""
        else: "struct(" & t.name & ";" & parts.join(";") & ")"
  of skInterface:
    let idx = c.indexOf.getOrDefault(t.name, 0)
    if idx == 0: return ""
    if idx in c.guidOf:
      # An interface names itself by its IID; a delegate wraps that.
      if c.md.isDelegate(idx): "delegate(" & guidToSignature(c.guidOf[idx]) & ")"
      else: guidToSignature(c.guidOf[idx])
    else:
      # A runtime class is described by its default interface.
      let default = c.defaultIface.getOrDefault(t.name, "")
      if default.len == 0: return ""
      let di = c.indexOf.getOrDefault(default, 0)
      if di == 0 or di notin c.guidOf: return ""
      "rc(" & t.name & ";" & guidToSignature(c.guidOf[di]) & ")"
  of skUnsupported:
    # A nested generic instantiation, which is legal: IVector<IReference<int>>.
    if t.name.len == 0 or t.args.len == 0: ""
    else:
      # The generic's own GUID: from this winmd if it is declared here, and
      # otherwise from the foreign table, since `IVector` and friends live in
      # `Windows.Foundation.winmd`.
      let idx = c.indexOf.getOrDefault(t.name, 0)
      var seed = ""
      if idx != 0 and idx in c.guidOf: seed = c.guidOf[idx]
      elif t.name in foreignGenericIid: seed = foreignGenericIid[t.name]
      if seed.len == 0: return ""
      var parts: seq[string]
      for a in t.args:
        let s = c.signatureOf(a)
        if s.len == 0: return ""
        parts.add s
      "pinterface(" & guidToSignature(seed) & ";" & parts.join(";") & ")"
  else: ""

proc instantiationSignature*(c: SigContext, t: SigType): string =
  ## The signature string for a whole `Generic<A, B>`, or "" if any part of it
  ## cannot be described.
  c.signatureOf(t)

func uuidV5(namespace: openArray[uint8], name: string): string =
  ## RFC 4122 section 4.3: SHA-1 of the namespace bytes followed by the name,
  ## with the version and variant bits overwritten in place.
  var data = newString(16 + name.len)
  for i in 0 .. 15: data[i] = char(namespace[i])
  for i in 0 ..< name.len: data[16 + i] = name[i]

  let digest = secureHash(data)
  var b: array[20, uint8]
  let hex = $digest
  for i in 0 .. 19:
    b[i] = uint8(parseHexInt(hex[i * 2 .. i * 2 + 1]))

  # Version 5, and the RFC 4122 variant.
  b[6] = (b[6] and 0x0F'u8) or 0x50'u8
  b[8] = (b[8] and 0x3F'u8) or 0x80'u8

  # The first three fields are big-endian in the digest and little-endian in a
  # GUID, but the *text* form is written big-endian either way, so the bytes go
  # out in the order they came.
  result = ""
  for i in 0 .. 15:
    result.add toHex(b[i], 2)
    if i in [3, 5, 7, 9]: result.add "-"
  result = "{" & result.toUpperAscii & "}"

proc parameterizedIid*(c: SigContext, t: SigType): string =
  ## The IID of a parameterised interface instantiation, braced and upper-case,
  ## or "" if its signature could not be built.
  let sig = c.instantiationSignature(t)
  if sig.len == 0: return ""
  uuidV5(pinterfaceNamespace, sig)
