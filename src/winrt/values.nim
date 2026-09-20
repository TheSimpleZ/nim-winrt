## Values as the API sees them and as the ABI carries them.
##
## Two things live here. `Api(T)` is the Nim type a value of metadata type
## `T` becomes when it is read: an `IVectorView<T>` is a `seq`, an
## `IReference<T>` an `Option`, an `IMapView<K, V>` a `Table`, everything
## else itself. And `IReference<T>` itself — WinRT's "a T, or nothing" — read
## with `takeReference`, made with `asReference`, held inside a struct as a
## `Reference[T]`.
##
## Handing a value *in* as a reference means wrapping it in an object.
## `Windows.Foundation.PropertyValue` is the runtime's own factory for that
## and the right answer wherever it applies: the numbers, `string`, `GUID`,
## `DateTime`, `TimeSpan`, `Point`, `Size` and `Rect`. There is no
## `CreateEnum` and no way to box a struct it has never heard of, so
## `IReference<Color>` — every nullable brush colour in XAML — is made by an
## object of this library's own, exactly as C++/WinRT's `impl::reference<T>`.

import ./[com, runtime, objects]
import ./abi/[types, generic, foundation]
include ./abidef

# ---------------------------------------------------------------- Api(T)

template Api*(Meta: typedesc): typedesc =
  ## The Nim type a value of metadata type `Meta` is read as. The metadata
  ## types are spelled with the ABI's generic vtables — `IVectorViewVtbl[X]`
  ## — because `seq[X]` alone would not say whether a vector or a vector view
  ## was meant, and their IIDs differ.
  when Meta is IVectorViewVtbl or Meta is IVectorVtbl or Meta is IIterableVtbl or
       Meta is IObservableVectorVtbl:
    when Meta.T is IKeyValuePairVtbl:
      Table[Api(Meta.T.K), Api(Meta.T.V)]      # an iterable of pairs is a map
    else:
      seq[Api(Meta.T)]
  elif Meta is IMapViewVtbl or Meta is IMapVtbl or Meta is IObservableMapVtbl:
    Table[Api(Meta.K), Api(Meta.V)]
  elif Meta is IReferenceVtbl:
    Option[Api(Meta.T)]
  elif Meta is IKeyValuePairVtbl:
    tuple[key: Api(Meta.K), value: Api(Meta.V)]
  elif Meta is IUnknownVtbl:
    WinRtObject          # any other interface pointer, known by no class
  else:
    Meta

# --------------------------------------------------------------- boxing

const PropertyValue = "Windows.Foundation.PropertyValue"

template boxable(T: typedesc): bool =
  ## Whether `PropertyValue` has a `CreateX` for `T`.
  T is uint8 or T is int16 or T is uint16 or T is int32 or T is uint32 or
    T is int64 or T is uint64 or T is float32 or T is float64 or T is Char16 or
    T is bool or T is string or T is GUID or T is DateTime or T is TimeSpan or
    T is Point or T is Size or T is Rect

proc box[T](value: T): pointer =
  ## `value` as the `IInspectable` PropertyValue makes of it, with a
  ## reference count of 1.
  let it = statics[IPropertyValueStaticsVtbl](PropertyValue)
  when T is uint8: it.vtbl.CreateUInt8(it.raw, value, result.addr).check("PropertyValue.CreateUInt8")
  elif T is int16: it.vtbl.CreateInt16(it.raw, value, result.addr).check("PropertyValue.CreateInt16")
  elif T is uint16: it.vtbl.CreateUInt16(it.raw, value, result.addr).check("PropertyValue.CreateUInt16")
  elif T is int32: it.vtbl.CreateInt32(it.raw, value, result.addr).check("PropertyValue.CreateInt32")
  elif T is uint32: it.vtbl.CreateUInt32(it.raw, value, result.addr).check("PropertyValue.CreateUInt32")
  elif T is int64: it.vtbl.CreateInt64(it.raw, value, result.addr).check("PropertyValue.CreateInt64")
  elif T is uint64: it.vtbl.CreateUInt64(it.raw, value, result.addr).check("PropertyValue.CreateUInt64")
  elif T is float32: it.vtbl.CreateSingle(it.raw, value, result.addr).check("PropertyValue.CreateSingle")
  elif T is float64: it.vtbl.CreateDouble(it.raw, value, result.addr).check("PropertyValue.CreateDouble")
  elif T is Char16: it.vtbl.CreateChar16(it.raw, value, result.addr).check("PropertyValue.CreateChar16")
  elif T is bool: it.vtbl.CreateBoolean(it.raw, value, result.addr).check("PropertyValue.CreateBoolean")
  elif T is string:
    let h = toWinRtString(value)
    it.vtbl.CreateString(it.raw, h.handle, result.addr).check("PropertyValue.CreateString")
  elif T is GUID: it.vtbl.CreateGuid(it.raw, value, result.addr).check("PropertyValue.CreateGuid")
  elif T is DateTime: it.vtbl.CreateDateTime(it.raw, value, result.addr).check("PropertyValue.CreateDateTime")
  elif T is TimeSpan: it.vtbl.CreateTimeSpan(it.raw, value, result.addr).check("PropertyValue.CreateTimeSpan")
  elif T is Point: it.vtbl.CreatePoint(it.raw, value, result.addr).check("PropertyValue.CreatePoint")
  elif T is Size: it.vtbl.CreateSize(it.raw, value, result.addr).check("PropertyValue.CreateSize")
  elif T is Rect: it.vtbl.CreateRect(it.raw, value, result.addr).check("PropertyValue.CreateRect")

# ------------------------------------------------ a reference of our own

# For a value PropertyValue cannot box: one vtable pointer, a refcount, the
# IID it answers for and the value. It answers `QueryInterface` for
# `IUnknown`, `IInspectable`, its own instantiation and `IAgileObject`, and
# for nothing else — in particular it is not an `IPropertyValue`: a value the
# runtime cannot box has no property-value representation to report, so
# claiming otherwise would be a lie a caller could act on.

type ValueRef[T] {.pure.} = object
  ## On the COM heap: WinRT may hold it past the call that took it, release
  ## it from any thread, and its lifetime is COM's rather than Nim's.
  vtbl: ptr IReferenceVtbl[T]   ## must stay first
  refs: int32
  iid: GUID
  value: T

proc refAddRef[T](self: pointer): uint32 {.abi.} =
  let r = cast[ptr ValueRef[T]](self)
  r.refs.inc
  uint32(r.refs)

proc refRelease[T](self: pointer): uint32 {.abi.} =
  let r = cast[ptr ValueRef[T]](self)
  r.refs.dec
  if r.refs <= 0:
    comFree(r)
    return 0
  uint32(r.refs)

proc refQuery[T](self: pointer, riid: ptr GUID, ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let r = cast[ptr ValueRef[T]](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == r.iid:
    ppv[] = self
    discard refAddRef[T](self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc refIids[T](self: pointer, count: ptr uint32, iids: ptr ptr GUID): HRESULT {.abi.} =
  let one = cast[ptr GUID](comAlloc(sizeof(GUID)))
  one[] = cast[ptr ValueRef[T]](self).iid
  count[] = 1
  iids[] = one
  S_OK

proc refClassName[T](self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  name[] = HSTRING(nil)     # no runtime class behind this; the empty string
  S_OK

proc refTrust[T](self: pointer, level: ptr int32): HRESULT {.abi.} =
  level[] = 0               # BaseTrust
  S_OK

proc refGetValue[T](self: pointer, value: ptr T): HRESULT {.abi.} =
  if value.isNil: return E_POINTER
  value[] = cast[ptr ValueRef[T]](self).value
  S_OK

proc ownReference[T](value: T): pointer =
  ## `value` as an `IReference<T>` implemented here, with a refcount of 1.
  # One table per instantiation, which is what `{.global.}` in a generic proc
  # means. The alternative, a table per object, would put a writable copy of
  # seven function pointers next to every boxed value.
  var vtbl {.global.} = IReferenceVtbl[T](
    queryInterface: refQuery[T], addRef: refAddRef[T], release: refRelease[T],
    getIids: refIids[T], getRuntimeClassName: refClassName[T],
    getTrustLevel: refTrust[T], get_Value: refGetValue[T])
  let r = cast[ptr ValueRef[T]](comAlloc(sizeof(ValueRef[T])))
  r.vtbl = vtbl.addr
  r.refs = 1
  r.iid = iid(IReferenceVtbl[T])
  r.value = value
  cast[pointer](r)

# ------------------------------------------------------------ references

proc asReference*[T](value: T): Reference[T] =
  ## `value` as an `IReference<T>`: boxed by the runtime where it can box a
  ## `T`, and by an object of this library's own otherwise.
  when boxable(T):
    let inspectable = box(value)
    result.raw = queryInterface(inspectable, iid(IReferenceVtbl[T]))
    discard release(inspectable)
  else:
    result.raw = ownReference(value)

proc asReference*[T](value: Option[T]): Reference[T] =
  ## `none` is a null pointer, which is exactly how WinRT spells an absent
  ## `IReference<T>`.
  if value.isSome: asReference(value.get) else: Reference[T]()

proc readReference*[T](box: pointer): Option[T] =
  ## The value inside an `IReference<T>`, or `none` for a null one. The box
  ## stays the caller's to release.
  if box.isNil: return none(T)
  let it = queryInterface[IReferenceVtbl[T]](box)
  var v: Abi(T)
  (it.vtbl.get_Value)(it.raw, v.addr).check("IReference.get_Value")
  when T is string: some(takeString(v))
  else: some(v)

proc takeReference*[T](box: pointer): Option[T] =
  ## `readReference`, for a box that is ours: read, then released.
  result = readReference[T](box)
  release(box)

proc value*[T](r: Reference[T]): Option[T] =
  ## What a reference held in a struct holds: the value, or `none`.
  readReference[T](r.raw)
