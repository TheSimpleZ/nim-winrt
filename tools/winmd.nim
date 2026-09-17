## An ECMA-335 reader for Windows Metadata (`.winmd`).
##
## This is what the bindings are generated from. Hand-writing them does not
## scale — `Windows.winmd` carries over 8,000 interfaces with an IID — so the
## surface is emitted from metadata instead, the same way `windows-bindgen`,
## C++/WinRT and C#/WinRT all work.
##
## A `.winmd` is a PE file with no code: the CLI data directory points at an
## ECMA-335 metadata root, which holds a handful of heaps and a set of tables.
## Reading it is entirely mechanical, with one genuine trap:
##
## **Row widths are global.** A column that indexes another table is 2 bytes if
## that table has fewer than 65536 rows and 4 otherwise, and a *coded* index
## widens based on the largest table in its set. So every table's row count has
## to be known before any row can be located — and a single wrong width shifts
## every subsequent row silently, producing plausible garbage rather than an
## error.
##
## This lives in `tools/` rather than `src/` on purpose: nothing at runtime
## reads metadata. The generators consume it to emit `src/winrt/`, and an
## application that imports `winrt` never needs an ECMA-335 parser — so
## shipping one to every consumer would be dead weight in their install.

import std/[strutils, tables, algorithm]

type
  ColKind = enum
    ckFixed    ## literal byte width
    ckString   ## index into #Strings
    ckGuid     ## index into #GUID
    ckBlob     ## index into #Blob
    ckTable    ## simple index into one table
    ckCoded    ## tagged index across several tables

  Col = object
    name: string
    case kind: ColKind
    of ckFixed: width: int
    of ckTable: table: int
    of ckCoded: coded: string
    else: discard

  WinMd* = ref object
    data: string
    stringsOff, guidOff, blobOff: int
    strW, guidW, blobW: int
    rows*: Table[int, int]          ## table id -> row count
    widths: Table[int, int]         ## table id -> bytes per row
    starts: Table[int, int]         ## table id -> file offset
    byName: Table[string, int]      ## full type name -> TypeDef row
    byNameBuilt: bool
    consts: Table[int, (int, string)]  ## Field row -> (ELEMENT_TYPE, raw bytes)
    constsBuilt: bool

  TypeRow* = object
    index*: int
    namespace*, name*: string
    flags*: uint32

const
  ## The tables this reader actually names. `schema` below describes all of
  ## them, including the ones nothing here reads — their widths decide where
  ## the tables after them begin — but only these are referred to by name.
  tTypeRef* = 0x01
  tTypeDef* = 0x02
  tField* = 0x04
  tMethodDef* = 0x06
  tInterfaceImpl* = 0x09
  tMemberRef* = 0x0A
  tConstant* = 0x0B
  tCustomAttribute* = 0x0C

func f(name: string, width: int): Col = Col(name: name, kind: ckFixed, width: width)
func s(name: string): Col = Col(name: name, kind: ckString)
func g(name: string): Col = Col(name: name, kind: ckGuid)
func b(name: string): Col = Col(name: name, kind: ckBlob)
func t(name: string, table: int): Col = Col(name: name, kind: ckTable, table: table)
func c(name, coded: string): Col = Col(name: name, kind: ckCoded, coded: coded)

## Coded index definitions: (tag bits, tables the tag selects).
## `0xFF` marks a reserved tag with no table.
let coded = {
  "TypeDefOrRef": (2, @[0x02, 0x01, 0x1B]),
  "HasConstant": (2, @[0x04, 0x08, 0x17]),
  "HasCustomAttribute": (5, @[0x06, 0x04, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x00,
                              0x0E, 0x17, 0x14, 0x11, 0x1A, 0x1B, 0x20, 0x23,
                              0x26, 0x27, 0x28, 0x2A, 0x2C, 0x2B]),
  "HasFieldMarshal": (1, @[0x04, 0x08]),
  "HasDeclSecurity": (2, @[0x02, 0x06, 0x20]),
  "MemberRefParent": (3, @[0x02, 0x01, 0x1A, 0x06, 0x1B]),
  "HasSemantics": (1, @[0x14, 0x17]),
  "MethodDefOrRef": (1, @[0x06, 0x0A]),
  "MemberForwarded": (1, @[0x04, 0x06]),
  "Implementation": (2, @[0x26, 0x23, 0x27]),
  "CustomAttributeType": (3, @[0xFF, 0xFF, 0x06, 0x0A, 0xFF]),
  "ResolutionScope": (2, @[0x00, 0x1A, 0x23, 0x01]),
  "TypeOrMethodDef": (1, @[0x02, 0x06]),
}.toTable

## Every table must be described, even ones never read: their widths decide
## where the tables after them begin. Keyed by the raw id, because most of
## these are never named anywhere else.
let schema = {
  0x00: @[f("Generation", 2), s("Name"), g("Mvid"), g("EncId"), g("EncBaseId")],
  0x01: @[c("ResolutionScope", "ResolutionScope"), s("Name"), s("Namespace")],
  0x02: @[f("Flags", 4), s("Name"), s("Namespace"), c("Extends", "TypeDefOrRef"),
          t("FieldList", 0x04), t("MethodList", 0x06)],
  0x03: @[t("Field", 0x04)],
  0x04: @[f("Flags", 2), s("Name"), b("Signature")],
  0x05: @[t("Method", 0x06)],
  0x06: @[f("RVA", 4), f("ImplFlags", 2), f("Flags", 2), s("Name"),
          b("Signature"), t("ParamList", 0x08)],
  0x07: @[t("Param", 0x08)],
  0x08: @[f("Flags", 2), f("Sequence", 2), s("Name")],
  0x09: @[t("Class", 0x02), c("Interface", "TypeDefOrRef")],
  0x0A: @[c("Class", "MemberRefParent"), s("Name"), b("Signature")],
  0x0B: @[f("Type", 1), f("Padding", 1), c("Parent", "HasConstant"), b("Value")],
  0x0C: @[c("Parent", "HasCustomAttribute"), c("Type", "CustomAttributeType"),
          b("Value")],
  0x0D: @[c("Parent", "HasFieldMarshal"), b("NativeType")],
  0x0E: @[f("Action", 2), c("Parent", "HasDeclSecurity"), b("PermissionSet")],
  0x0F: @[f("PackingSize", 2), f("ClassSize", 4), t("Parent", 0x02)],
  0x10: @[f("Offset", 4), t("Field", 0x04)],
  0x11: @[b("Signature")],
  0x12: @[t("Parent", 0x02), t("EventList", 0x14)],
  0x13: @[t("Event", 0x14)],
  0x14: @[f("EventFlags", 2), s("Name"), c("EventType", "TypeDefOrRef")],
  0x15: @[t("Parent", 0x02), t("PropertyList", 0x17)],
  0x16: @[t("Property", 0x17)],
  0x17: @[f("Flags", 2), s("Name"), b("Type")],
  0x18: @[f("Semantics", 2), t("Method", 0x06), c("Association", "HasSemantics")],
  0x19: @[t("Class", 0x02), c("MethodBody", "MethodDefOrRef"),
          c("MethodDeclaration", "MethodDefOrRef")],
  0x1A: @[s("Name")],
  0x1B: @[b("Signature")],
  0x1C: @[f("MappingFlags", 2), c("MemberForwarded", "MemberForwarded"),
          s("ImportName"), t("ImportScope", 0x1A)],
  0x1D: @[f("RVA", 4), t("Field", 0x04)],
  0x20: @[f("HashAlgId", 4), f("Major", 2), f("Minor", 2), f("Build", 2),
          f("Rev", 2), f("Flags", 4), b("PublicKey"), s("Name"), s("Culture")],
  0x21: @[f("Processor", 4)],
  0x22: @[f("OSPlatformID", 4), f("OSMajor", 4), f("OSMinor", 4)],
  0x23: @[f("Major", 2), f("Minor", 2), f("Build", 2), f("Rev", 2), f("Flags", 4),
          b("PublicKeyOrToken"), s("Name"), s("Culture"), b("HashValue")],
  0x24: @[f("Processor", 4), t("AssemblyRef", 0x23)],
  0x25: @[f("OSPlatformID", 4), f("OSMajor", 4), f("OSMinor", 4),
          t("AssemblyRef", 0x23)],
  0x26: @[f("Flags", 4), s("Name"), b("HashValue")],
  0x27: @[f("Flags", 4), f("TypeDefId", 4), s("TypeName"), s("TypeNamespace"),
          c("Implementation", "Implementation")],
  0x28: @[f("Offset", 4), f("Flags", 4), s("Name"),
          c("Implementation", "Implementation")],
  0x29: @[t("NestedClass", 0x02), t("EnclosingClass", 0x02)],
  0x2A: @[f("Number", 2), f("Flags", 2), c("Owner", "TypeOrMethodDef"), s("Name")],
  0x2B: @[c("Method", "MethodDefOrRef"), b("Instantiation")],
  0x2C: @[t("Owner", 0x2A), c("Constraint", "TypeDefOrRef")],
}.toTable

# ----------------------------------------------------------------- reading

proc u8(m: WinMd, at: int): int = int(byte(m.data[at]))

proc uint16At(m: WinMd, at: int): int =
  m.u8(at) or (m.u8(at + 1) shl 8)

proc uint32At(m: WinMd, at: int): uint32 =
  uint32(m.u8(at)) or (uint32(m.u8(at + 1)) shl 8) or
    (uint32(m.u8(at + 2)) shl 16) or (uint32(m.u8(at + 3)) shl 24)

proc uint64At(m: WinMd, at: int): uint64 =
  uint64(m.uint32At(at)) or (uint64(m.uint32At(at + 4)) shl 32)

proc intAt(m: WinMd, at, width: int): int =
  for i in countdown(width - 1, 0):
    result = (result shl 8) or m.u8(at + i)

proc colWidth(m: WinMd, col: Col): int =
  ## How many bytes one column occupies, which depends on how big the tables
  ## and heaps in *this* file are. Every offset in the file is a running sum of
  ## these, so the rule has to be applied identically everywhere — hence one
  ## definition rather than one per caller.
  case col.kind
  of ckFixed: col.width
  of ckString: m.strW
  of ckGuid: m.guidW
  of ckBlob: m.blobW
  of ckTable: (if m.rows.getOrDefault(col.table, 0) >= 65536: 4 else: 2)
  of ckCoded:
    let (bits, tabs) = coded[col.coded]
    var biggest = 0
    for tt in tabs:
      if tt != 0xFF: biggest = max(biggest, m.rows.getOrDefault(tt, 0))
    if biggest >= (1 shl (16 - bits)): 4 else: 2

proc findMetadata(m: WinMd): int =
  ## Walk the PE headers to the CLI metadata root.
  let peOff = int(m.uint32At(0x3C))
  doAssert m.data[peOff .. peOff + 1] == "PE", "not a PE file"
  let coff = peOff + 4
  let nSections = m.uint16At(coff + 2)
  let optSize = m.uint16At(coff + 16)
  let opt = coff + 20
  let pe32plus = m.uint16At(opt) == 0x20B
  # Data directory entry 14 is the CLI header.
  let dd = opt + (if pe32plus: 112 else: 96)
  let cliRva = m.uint32At(dd + 14 * 8)

  var sections: seq[(uint32, uint32, uint32, uint32)]
  let secBase = opt + optSize
  for i in 0 ..< nSections:
    let bse = secBase + i * 40
    sections.add((m.uint32At(bse + 12), m.uint32At(bse + 8),
                  m.uint32At(bse + 20), m.uint32At(bse + 16)))

  proc toOff(rva: uint32): int =
    for (vaddr, vsize, rawptr, rawsize) in sections:
      if rva >= vaddr and rva < vaddr + max(vsize, rawsize):
        return int(rawptr + (rva - vaddr))
    raise newException(ValueError, "unmapped RVA " & $rva)

  let cli = toOff(cliRva)
  toOff(m.uint32At(cli + 8))

proc load*(path: string): WinMd =
  ## Read a `.winmd` and index its tables.
  result = WinMd(data: readFile(path))
  let m = result
  let meta = m.findMetadata()
  doAssert m.data[meta .. meta + 3] == "BSJB", "bad metadata signature"

  let verLen = int(m.uint32At(meta + 12))
  var p = meta + 16 + verLen + 2      # skip version string and flags
  let nStreams = m.uint16At(p)
  p += 2

  var tableStream = 0
  for _ in 0 ..< nStreams:
    let off = int(m.uint32At(p))
    p += 8
    var e = p
    while m.data[e] != '\0': e.inc
    let name = m.data[p ..< e]
    p = e + 1
    p = (p + 3) and not 3             # names pad to a 4-byte boundary
    case name
    of "#Strings": m.stringsOff = meta + off
    of "#GUID": m.guidOff = meta + off
    of "#Blob": m.blobOff = meta + off
    of "#~": tableStream = meta + off
    else: discard
  doAssert tableStream != 0, "no #~ stream"

  let heapSizes = m.u8(tableStream + 6)
  m.strW = if (heapSizes and 1) != 0: 4 else: 2
  m.guidW = if (heapSizes and 2) != 0: 4 else: 2
  m.blobW = if (heapSizes and 4) != 0: 4 else: 2

  let valid = m.uint64At(tableStream + 8)
  p = tableStream + 24
  for tid in 0 ..< 64:
    if (valid shr tid and 1) != 0:
      m.rows[tid] = int(m.uint32At(p))
      p += 4

  # Widths must all be known before any start can be computed.
  for tid in m.rows.keys:
    doAssert tid in schema, "unknown table 0x" & toHex(tid, 2)
    var w = 0
    for col in schema[tid]: w += m.colWidth(col)
    m.widths[tid] = w

  var sortedIds: seq[int]
  for tid in m.rows.keys: sortedIds.add tid
  sortedIds.sort()
  for tid in sortedIds:
    m.starts[tid] = p
    p += m.widths[tid] * m.rows[tid]

proc colOffset(m: WinMd, tid, index: int, name: string): (int, int) =
  ## File offset and width of one column of a 1-based row.
  var at = m.starts[tid] + (index - 1) * m.widths[tid]
  for col in schema[tid]:
    let w = m.colWidth(col)
    if col.name == name:
      return (at, w)
    at += w
  raise newException(KeyError, "no column " & name & " in table " & $tid)

proc cell*(m: WinMd, tid, index: int, name: string): int =
  let (at, w) = m.colOffset(tid, index, name)
  m.intAt(at, w)

proc str*(m: WinMd, idx: int): string =
  if idx == 0: return ""
  var e = m.stringsOff + idx
  while m.data[e] != '\0': e.inc
  m.data[m.stringsOff + idx ..< e]

proc blob*(m: WinMd, idx: int): string =
  var p = m.blobOff + idx
  let b0 = m.u8(p)
  var n: int
  if (b0 and 0x80) == 0:
    n = b0 and 0x7F; p += 1
  elif (b0 and 0xC0) == 0x80:
    n = ((b0 and 0x3F) shl 8) or m.u8(p + 1); p += 2
  else:
    n = ((b0 and 0x1F) shl 24) or (m.u8(p + 1) shl 16) or
        (m.u8(p + 2) shl 8) or m.u8(p + 3); p += 4
  m.data[p ..< p + n]

proc decodeCoded(kind: string, value: int): (int, int) =
  ## Split a coded index into (table id, row index).
  let (bits, tabs) = coded[kind]
  let tag = value and ((1 shl bits) - 1)
  ((if tag < tabs.len: tabs[tag] else: 0xFF), value shr bits)

# ------------------------------------------------------------- convenience

proc typeRow*(m: WinMd, index: int): TypeRow =
  TypeRow(index: index,
          namespace: m.str(m.cell(tTypeDef, index, "Namespace")),
          name: m.str(m.cell(tTypeDef, index, "Name")),
          flags: uint32(m.cell(tTypeDef, index, "Flags")))

func fullName*(t: TypeRow): string =
  if t.namespace.len > 0: t.namespace & "." & t.name else: t.name

iterator types*(m: WinMd): TypeRow =
  for i in 1 .. m.rows.getOrDefault(tTypeDef, 0):
    yield m.typeRow(i)

proc typeDefOrRefName*(m: WinMd, codedValue: int): string =
  ## Resolve an `Extends` column to a full type name.
  ##
  ## Interfaces extend nothing, and metadata spells that as a zero coded value.
  ## Rows are 1-based, so a naive decode of zero reads row 0 and walks off the
  ## front of the table.
  if codedValue == 0:
    return ""
  let (tab, idx) = decodeCoded("TypeDefOrRef", codedValue)
  if idx < 1 or idx > m.rows.getOrDefault(tab, 0):
    return ""
  case tab
  of tTypeDef:
    m.typeRow(idx).fullName
  of tTypeRef:
    let ns = m.str(m.cell(tTypeRef, idx, "Namespace"))
    let nm = m.str(m.cell(tTypeRef, idx, "Name"))
    if ns.len > 0: ns & "." & nm else: nm
  else:
    ""

proc isDelegate*(m: WinMd, typeIndex: int): bool =
  ## Delegates are TypeDefs extending `System.MulticastDelegate`. They matter
  ## separately because their vtable derives from `IUnknown`, not
  ## `IInspectable` — three inherited slots rather than six.
  m.typeDefOrRefName(m.cell(tTypeDef, typeIndex, "Extends")) ==
    "System.MulticastDelegate"

proc methodNames*(m: WinMd, typeIndex: int): seq[string] =
  ## Method names in declaration order, which is vtable order.
  ##
  ## A type's methods run from its own `MethodList` up to the next type's, so
  ## the last type runs to the end of the table.
  let first = m.cell(tTypeDef, typeIndex, "MethodList")
  let last = m.rows[tTypeDef]
  let stop =
    if typeIndex < last: m.cell(tTypeDef, typeIndex + 1, "MethodList")
    else: m.rows.getOrDefault(tMethodDef, 0) + 1
  for mi in first ..< stop:
    result.add m.str(m.cell(tMethodDef, mi, "Name"))

# ------------------------------------------------------------- signatures

type
  SigKind* = enum
    skVoid, skBool, skChar, skI1, skU1, skI2, skU2, skI4, skU4, skI8, skU8,
    skF4, skF8, skString, skObject, skInterface, skEnum, skStruct, skArray,
    skUnsupported

  SigType* = object
    kind*: SigKind
    byRef*: bool
    name*: string        ## resolved type name, for classes/structs/enums
    args*: seq[SigType]  ## type arguments, for a generic instantiation

  MethodSig* = object
    hasThis*: bool
    returns*: SigType
    params*: seq[SigType]

const
  # ELEMENT_TYPE_* from ECMA-335 II.23.1.16
  etVoid = 0x01
  etBoolean = 0x02
  etChar = 0x03
  etI1 = 0x04
  etU1 = 0x05
  etI2 = 0x06
  etU2 = 0x07
  etI4 = 0x08
  etU4 = 0x09
  etI8 = 0x0A
  etU8 = 0x0B
  etR4 = 0x0C
  etR8 = 0x0D
  etString = 0x0E
  etPtr = 0x0F
  etByRef = 0x10
  etValueType = 0x11
  etClass = 0x12
  etVar = 0x13
  etArray = 0x14
  etGenericInst = 0x15
  etTypedByRef = 0x16
  etI = 0x18
  etU = 0x19
  etFnPtr = 0x1B
  etObject = 0x1C
  etSzArray = 0x1D
  etMVar = 0x1E
  etCModReqd = 0x1F
  etCModOpt = 0x20

proc compressed(s: string, p: var int): int =
  ## ECMA-335 II.23.2 compressed unsigned integer: 1, 2 or 4 bytes, the
  ## leading bits saying which.
  let b0 = int(byte(s[p]))
  if (b0 and 0x80) == 0:
    p += 1
    b0
  elif (b0 and 0xC0) == 0x80:
    let v = ((b0 and 0x3F) shl 8) or int(byte(s[p + 1]))
    p += 2
    v
  else:
    let v = ((b0 and 0x1F) shl 24) or (int(byte(s[p + 1])) shl 16) or
            (int(byte(s[p + 2])) shl 8) or int(byte(s[p + 3]))
    p += 4
    v

proc typeDefOrRefToken(s: string, p: var int): int =
  ## Inside a signature a TypeDefOrRef is a *compressed* token: two tag bits
  ## selecting TypeDef/TypeRef/TypeSpec, then the row index.
  compressed(s, p)

proc isEnum*(m: WinMd, typeIndex: int): bool =
  m.typeDefOrRefName(m.cell(tTypeDef, typeIndex, "Extends")) == "System.Enum"

proc typeIndexByName*(m: WinMd): Table[string, int] =
  ## Full type name -> TypeDef row, built once.
  if not m.byNameBuilt:
    for i in 1 .. m.rows.getOrDefault(tTypeDef, 0):
      m.byName[m.typeRow(i).fullName] = i
    m.byNameBuilt = true
  m.byName

proc resolveSigToken(m: WinMd, token: int): (string, bool) =
  ## (type name, isEnum) for a compressed signature token.
  ##
  ## A type defined in this very assembly is still usually referenced through
  ## the TypeRef table, so a TypeRef is resolved back to its definition by
  ## name before asking whether it is an enum. Skipping that step leaves every
  ## enum parameter looking like an unmappable struct.
  let tag = token and 0x3
  let idx = token shr 2
  case tag
  of 0:  # TypeDef
    if idx >= 1 and idx <= m.rows.getOrDefault(tTypeDef, 0):
      (m.typeRow(idx).fullName, m.isEnum(idx))
    else: ("", false)
  of 1:  # TypeRef
    if idx >= 1 and idx <= m.rows.getOrDefault(tTypeRef, 0):
      let ns = m.str(m.cell(tTypeRef, idx, "Namespace"))
      let nm = m.str(m.cell(tTypeRef, idx, "Name"))
      let full = if ns.len > 0: ns & "." & nm else: nm
      let defs = m.typeIndexByName()
      if full in defs: (full, m.isEnum(defs[full])) else: (full, false)
    else: ("", false)
  else:  # TypeSpec — generic instantiations, not resolved here
    ("", false)

proc parseType(m: WinMd, s: string, p: var int): SigType =
  ## One `Type` in a signature. Unsupported shapes are reported rather than
  ## guessed at: emitting a wrong ABI type is worse than emitting none.
  if p >= s.len:
    return SigType(kind: skUnsupported)
  var e = int(byte(s[p]))
  p += 1

  # Custom modifiers are decoration; skip them and take the type behind.
  while e == etCModReqd or e == etCModOpt:
    discard typeDefOrRefToken(s, p)
    if p >= s.len: return SigType(kind: skUnsupported)
    e = int(byte(s[p]))
    p += 1

  if e == etByRef:
    result = m.parseType(s, p)
    result.byRef = true
    return

  case e
  of etVoid: SigType(kind: skVoid)
  of etBoolean: SigType(kind: skBool)
  of etChar: SigType(kind: skChar)
  of etI1: SigType(kind: skI1)
  of etU1: SigType(kind: skU1)
  of etI2: SigType(kind: skI2)
  of etU2: SigType(kind: skU2)
  of etI4: SigType(kind: skI4)
  of etU4: SigType(kind: skU4)
  of etI8: SigType(kind: skI8)
  of etU8: SigType(kind: skU8)
  of etR4: SigType(kind: skF4)
  of etR8: SigType(kind: skF8)
  of etString: SigType(kind: skString)
  of etObject: SigType(kind: skObject)
  of etClass:
    let (name, _) = m.resolveSigToken(typeDefOrRefToken(s, p))
    SigType(kind: skInterface, name: name)
  of etValueType:
    let (name, enumish) = m.resolveSigToken(typeDefOrRefToken(s, p))
    # A WinRT enum is an int32 on the wire; a struct is passed by value and
    # needs a real layout, which is not generated yet.
    if enumish: SigType(kind: skEnum, name: name)
    else: SigType(kind: skStruct, name: name)
  of etSzArray:
    # The element type, kept so a caller can tell `Single[]` from `IInspectable[]`.
    let elem = m.parseType(s, p)
    SigType(kind: skArray, name: elem.name)
  of etGenericInst:
    # GENERICINST <CLASS|VALUETYPE> <TypeDefOrRef> <argCount> <args...>
    #
    # Still unsupported — a parameterised interface's IID is computed from its
    # arguments rather than declared, so there is nothing to emit. But the name
    # is recorded, because "unsupported" is not a useful answer when deciding
    # whether `IVector<T>` is worth the work and `IAsyncAction<T>` is not.
    if p < s.len:
      p += 1                                  # CLASS or VALUETYPE
      let (name, _) = m.resolveSigToken(typeDefOrRefToken(s, p))
      let argc = compressed(s, p)
      var args: seq[SigType]
      for _ in 0 ..< argc:
        args.add m.parseType(s, p)
      SigType(kind: skUnsupported, name: name, args: args)
    else:
      SigType(kind: skUnsupported)
  of etVar, etMVar, etArray, etPtr, etFnPtr, etTypedByRef, etI, etU:
    SigType(kind: skUnsupported)
  else:
    SigType(kind: skUnsupported)

proc methodSignature*(m: WinMd, methodIndex: int): MethodSig =
  ## Decode a `MethodDefSig` blob into return and parameter types.
  let s = m.blob(m.cell(tMethodDef, methodIndex, "Signature"))
  if s.len == 0:
    return MethodSig(returns: SigType(kind: skUnsupported))
  var p = 0
  let conv = int(byte(s[p]))
  p += 1
  result.hasThis = (conv and 0x20) != 0
  # Generic methods carry a parameter count here that this does not handle.
  if (conv and 0x10) != 0:
    return MethodSig(returns: SigType(kind: skUnsupported))
  let nParams = compressed(s, p)
  result.returns = m.parseType(s, p)
  for _ in 0 ..< nParams:
    result.params.add m.parseType(s, p)

proc methodRange*(m: WinMd, typeIndex: int): (int, int) =
  ## The half-open MethodDef row range belonging to a type.
  let first = m.cell(tTypeDef, typeIndex, "MethodList")
  let last = m.rows[tTypeDef]
  let stop =
    if typeIndex < last: m.cell(tTypeDef, typeIndex + 1, "MethodList")
    else: m.rows.getOrDefault(tMethodDef, 0) + 1
  (first, stop)

proc guids*(m: WinMd): Table[int, string] =
  ## TypeDef row -> IID, from `Windows.Foundation.Metadata.GuidAttribute`.
  ##
  ## The attribute's value blob is a 2-byte prolog then the constructor's
  ## fixed arguments: uint32, uint16, uint16, then eight bytes.
  for i in 1 .. m.rows.getOrDefault(tCustomAttribute, 0):
    let (pTab, pIdx) = decodeCoded("HasCustomAttribute",
                                   m.cell(tCustomAttribute, i, "Parent"))
    if pTab != tTypeDef: continue
    let (tTab, tIdx) = decodeCoded("CustomAttributeType",
                                   m.cell(tCustomAttribute, i, "Type"))
    if tTab != tMemberRef: continue
    let (cTab, cIdx) = decodeCoded("MemberRefParent",
                                   m.cell(tMemberRef, tIdx, "Class"))
    if cTab != tTypeRef: continue
    if m.str(m.cell(tTypeRef, cIdx, "Name")) != "GuidAttribute": continue

    let v = m.blob(m.cell(tCustomAttribute, i, "Value"))
    if v.len < 18: continue
    var d1: uint32
    for k in countdown(5, 2): d1 = (d1 shl 8) or uint32(byte(v[k]))
    let d2 = (int(byte(v[7])) shl 8) or int(byte(v[6]))
    let d3 = (int(byte(v[9])) shl 8) or int(byte(v[8]))
    var tail = ""
    for k in 10 .. 17: tail.add toHex(int(byte(v[k])), 2)
    result[pIdx] = "{" & toHex(int(d1), 8) & "-" & toHex(d2, 4) & "-" &
      toHex(d3, 4) & "-" & tail[0 ..< 4] & "-" & tail[4 .. ^1] & "}"

proc fieldRange*(m: WinMd, typeIndex: int): (int, int) =
  ## The half-open Field row range belonging to a type.
  ##
  ## Same shape as `methodRange`: a TypeDef stores only where its fields
  ## *start*, and the end is wherever the next type's begin.
  let first = m.cell(tTypeDef, typeIndex, "FieldList")
  let last = m.rows[tTypeDef]
  let stop =
    if typeIndex < last: m.cell(tTypeDef, typeIndex + 1, "FieldList")
    else: m.rows.getOrDefault(tField, 0) + 1
  (first, stop)

proc constantsByField(m: WinMd): Table[int, (int, string)] =
  ## Field row -> (ELEMENT_TYPE, raw little-endian value bytes).
  ##
  ## Built once for the whole file rather than scanned per enum: the Constant
  ## table is keyed by its parent, so finding one field's value otherwise means
  ## a linear pass over every constant in the file, per enum.
  if not m.constsBuilt:
    for i in 1 .. m.rows.getOrDefault(tConstant, 0):
      let (pTab, pIdx) = decodeCoded("HasConstant", m.cell(tConstant, i, "Parent"))
      if pTab != tField: continue
      m.consts[pIdx] = (m.cell(tConstant, i, "Type"),
                        m.blob(m.cell(tConstant, i, "Value")))
    m.constsBuilt = true
  m.consts

func decodeInt(elementType: int, raw: string): int64 =
  ## Enums are backed by int32 or uint32 in WinRT; the blob is little-endian.
  var v: uint64
  for i in countdown(raw.high, 0):
    v = (v shl 8) or uint64(byte(raw[i]))
  case elementType
  of 0x08: int64(cast[int32](uint32(v)))   # ELEMENT_TYPE_I4
  of 0x09: int64(cast[uint32](v))          # ELEMENT_TYPE_U4
  else: int64(v)

proc enumMembers*(m: WinMd, typeIndex: int): seq[(string, int64)] =
  ## The named values of an enum, in declaration order.
  ##
  ## An enum's first field is the compiler-generated `value__` instance field
  ## that gives its backing type. It carries no Constant row, so filtering on
  ## "has a constant" drops it without special-casing the name.
  let consts = m.constantsByField()
  let (first, stop) = m.fieldRange(typeIndex)
  for fi in first ..< stop:
    if fi notin consts: continue
    let (et, raw) = consts[fi]
    result.add (m.str(m.cell(tField, fi, "Name")), decodeInt(et, raw))

proc interfaceImpls*(m: WinMd): Table[int, seq[int]] =
  ## TypeDef row -> the coded `TypeDefOrRef` values of the interfaces it
  ## implements, in declaration order.
  ##
  ## Order matters: WinRT puts a runtime class's *default* interface first, and
  ## that is the one an activation hands back.
  for i in 1 .. m.rows.getOrDefault(tInterfaceImpl, 0):
    let cls = m.cell(tInterfaceImpl, i, "Class")
    result.mgetOrPut(cls, @[]).add m.cell(tInterfaceImpl, i, "Interface")

proc attributeNames*(m: WinMd): Table[int, seq[string]] =
  ## TypeDef row -> the names of the custom attributes on it.
  ##
  ## Used to tell an activatable class from a composable one: WinRT records
  ## that as `ActivatableAttribute` / `ComposableAttribute` / `StaticAttribute`
  ## rather than anywhere in the type's shape.
  for i in 1 .. m.rows.getOrDefault(tCustomAttribute, 0):
    let (pTab, pIdx) = decodeCoded("HasCustomAttribute",
                                   m.cell(tCustomAttribute, i, "Parent"))
    if pTab != tTypeDef: continue
    let (tTab, tIdx) = decodeCoded("CustomAttributeType",
                                   m.cell(tCustomAttribute, i, "Type"))
    if tTab != tMemberRef: continue
    let (cTab, cIdx) = decodeCoded("MemberRefParent",
                                   m.cell(tMemberRef, tIdx, "Class"))
    if cTab != tTypeRef: continue
    result.mgetOrPut(pIdx, @[]).add m.str(m.cell(tTypeRef, cIdx, "Name"))

proc baseName*(m: WinMd, typeIndex: int): string =
  ## The full name of a type's base class, or "" for `System.Object` and
  ## interfaces.
  let ext = m.cell(tTypeDef, typeIndex, "Extends")
  if ext == 0: return ""
  result = m.typeDefOrRefName(ext)
  if result in ["System.Object", "System.ValueType", "System.Enum",
                "System.MulticastDelegate"]:
    result = ""

proc fieldType*(m: WinMd, fieldIndex: int): SigType =
  ## The type of one field, from its signature blob.
  ##
  ## A FieldSig is `FIELD` (0x06) followed by the type, so the calling
  ## convention byte is skipped before parsing.
  let sig = m.blob(m.cell(tField, fieldIndex, "Signature"))
  if sig.len < 2: return SigType(kind: skUnsupported)
  var p = 1
  m.parseType(sig, p)
