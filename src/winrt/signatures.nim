## The IID of a parameterised interface, computed at compile time.
##
## `IVector<UIElement>` has no GUID in any metadata file. WinRT derives one:
## build a *signature string* describing the instantiation, then take a
## version-5 UUID of it under a fixed namespace. Every projection does exactly
## this, and it is the only way to QueryInterface for a generic at all.
##
## Each type has a spelling, given in the Windows Runtime type system:
##
##   Int32              i4          String    string
##   UInt32             u4          Guid      g16
##   Boolean            b1          Object    cinterface(IInspectable)
##   interface          {iid}       enum      enum(Name;i4 or u4)
##   struct             struct(Name;field;field;...)
##   runtime class      rc(Name;{default interface iid})
##   parameterised      pinterface({generic iid};arg;arg;...)
##
## `typeSignature(T)` spells a Nim type this way, and the ABI's generic vtables
## declare `iid(IVectorVtbl[T])` as the hash of theirs. Both run in the
## compiler, so an instantiation costs a constant and nothing at run time.
##
## Getting a signature wrong is silent: it yields a well-formed GUID no object
## implements, so `QueryInterface` answers `E_NOINTERFACE` and the call site
## looks like an unsupported feature rather than a wrong hash. The tests take
## several computed IIDs to live objects for that reason.

import std/strutils
import ./[com, objects]

# -------------------------------------------------------------------- SHA-1

# RFC 3174, in plain Nim so the compiler's VM can run it. A dependency-free
# sixty lines are the right trade against the deprecated `std/sha1`.

func rol(x: uint32, n: int): uint32 {.inline.} =
  (x shl n) or (x shr (32 - n))

func sha1(msg: openArray[uint8]): array[20, uint8] =
  var h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32,
           0x10325476'u32, 0xC3D2E1F0'u32]
  var data = @msg
  data.add 0x80'u8
  while data.len mod 64 != 56: data.add 0'u8
  let bits = uint64(msg.len) * 8
  for i in countdown(7, 0): data.add uint8((bits shr (8 * i)) and 0xFF)
  var w: array[80, uint32]
  for chunk in 0 ..< data.len div 64:
    let base = chunk * 64
    for i in 0 .. 15:
      w[i] = (uint32(data[base + 4 * i]) shl 24) or
             (uint32(data[base + 4 * i + 1]) shl 16) or
             (uint32(data[base + 4 * i + 2]) shl 8) or
             uint32(data[base + 4 * i + 3])
    for i in 16 .. 79:
      w[i] = rol(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    for i in 0 .. 79:
      var f, k: uint32
      if i < 20:
        f = (b and c) or ((not b) and d)
        k = 0x5A827999'u32
      elif i < 40:
        f = b xor c xor d
        k = 0x6ED9EBA1'u32
      elif i < 60:
        f = (b and c) or (b and d) or (c and d)
        k = 0x8F1BBCDC'u32
      else:
        f = b xor c xor d
        k = 0xCA62C1D6'u32
      let t = rol(a, 5) + f + e + k + w[i]
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = t
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
  for i in 0 .. 4:
    result[4 * i] = uint8(h[i] shr 24)
    result[4 * i + 1] = uint8(h[i] shr 16)
    result[4 * i + 2] = uint8(h[i] shr 8)
    result[4 * i + 3] = uint8(h[i])

# ---------------------------------------------------------------- UUID v5

func networkOrder(g: GUID): array[16, uint8] =
  ## The bytes RFC 4122 hashes a namespace as: the three integer fields
  ## big-endian, then the eight bytes as they are.
  result[0] = uint8(g.data1 shr 24)
  result[1] = uint8(g.data1 shr 16)
  result[2] = uint8(g.data1 shr 8)
  result[3] = uint8(g.data1)
  result[4] = uint8(g.data2 shr 8)
  result[5] = uint8(g.data2)
  result[6] = uint8(g.data3 shr 8)
  result[7] = uint8(g.data3)
  for i in 0 .. 7: result[8 + i] = g.data4[i]

func uuid5(namespace: GUID, name: string): GUID =
  ## RFC 4122 section 4.3: SHA-1 of the namespace bytes followed by the name,
  ## with the version and variant bits overwritten in place.
  var data = @(networkOrder(namespace))
  for ch in name: data.add uint8(ch)
  var b = sha1(data)
  b[6] = (b[6] and 0x0F'u8) or 0x50'u8
  b[8] = (b[8] and 0x3F'u8) or 0x80'u8
  result.data1 = (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or
                 (uint32(b[2]) shl 8) or uint32(b[3])
  result.data2 = (uint16(b[4]) shl 8) or uint16(b[5])
  result.data3 = (uint16(b[6]) shl 8) or uint16(b[7])
  for i in 0 .. 7: result.data4[i] = b[8 + i]

const pinterfaceNamespace = guid"11F47AD5-7B73-42C0-ABAE-878B1E16ADEE"
  ## The namespace every parameterised interface IID is generated under.

func signatureOf(g: GUID): string =
  ## An interface, as a signature spells one.
  "{" & toLowerAscii($g) & "}"

func pinterfaceSignature*(generic: GUID, args: varargs[string]): string =
  ## The signature of `generic` instantiated with arguments whose signatures
  ## are `args`, which is what a nested instantiation contributes to an outer
  ## one's.
  "pinterface(" & signatureOf(generic) & ";" & args.join(";") & ")"

func pinterfaceIid*(generic: GUID, args: varargs[string]): GUID =
  ## The IID of `generic` instantiated with arguments whose signatures are
  ## `args`: `pinterfaceIid(<IVector's own GUID>, typeSignature(T))`.
  uuid5(pinterfaceNamespace, pinterfaceSignature(generic, args))

# ------------------------------------------------------------- signatures

proc typeSignature*(T: typedesc): string =
  ## The type-system signature of `T`, for computing an IID that mentions it.
  ##
  ## An enum or struct is spelled with its metadata name, a class with its
  ## own and its default interface's IID, an interface or delegate by IID
  ## alone; the generated modules declare the constants those are read from.
  when T is bool: "b1"
  elif T is Char16: "c2"
  elif T is int8: "i1"
  elif T is uint8: "u1"
  elif T is int16: "i2"
  elif T is uint16: "u2"
  elif T is int32: "i4"
  elif T is uint32: "u4"
  elif T is int64: "i8"
  elif T is uint64: "u8"
  elif T is float32: "f4"
  elif T is float64: "f8"
  elif T is string: "string"
  elif T is GUID: "g16"
  elif T is WinRtInterface: signatureOf(iid(T))
  elif T is WinRtDelegate: "delegate(" & signatureOf(iid(T)) & ")"
  elif T is WinRtObject:
    when WinRtObject is T: "cinterface(IInspectable)"
    else: "rc(" & className(T) & ";" & signatureOf(defaultIid(T)) & ")"
  elif T is IInspectableVtbl: signatureOf(iid(T))
  elif T is IUnknownVtbl: "delegate(" & signatureOf(iid(T)) & ")"
  elif T is Option:
    # A nullable field of a struct is an `IReference<T>`.
    pinterfaceSignature(guid"61C17706-2D65-11E0-9AE8-D48564015472",
                        typeSignature(typeof(default(T).get)))
  elif T is enum: "enum(" & runtimeName(T) & ";i4)"
  elif T is distinct: "enum(" & runtimeName(T) & ";u4)"    # a flags enum
  elif T is object:
    var fields: seq[string]
    for _, value in fieldPairs(default(T)):
      fields.add typeSignature(typeof(value))
    "struct(" & runtimeName(T) & ";" & fields.join(";") & ")"
  else:
    {.error: "winrt: no type signature for " & $T.}
