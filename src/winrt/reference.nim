## Handing a value to WinRT as an `IReference<T>`.
##
## `core` boxes through `Windows.Foundation.PropertyValue`, which is the
## runtime's own factory and the right answer wherever it applies. It only
## applies to the types it has a `CreateX` for: the numbers, `string`, `GUID`,
## `DateTime`, `TimeSpan`, `Point`, `Size` and `Rect`. There is no `CreateEnum`
## and no way to box a struct it has never heard of.
##
## So `IReference<Color>` — every nullable brush colour in XAML — cannot be
## made by the runtime, and a projection that wants to pass one has to
## implement the interface itself. Every other language projection does the
## same thing; this is C++/WinRT's `impl::reference<T>` in Nim.
##
## The object is deliberately small: one vtable pointer, a refcount, the IID it
## answers for and the value. `get_Value` is slot 6 on every instantiation, as
## it is for reading one.
##
## It answers `QueryInterface` for `IUnknown`, `IInspectable`, its own
## instantiation and `IAgileObject`, and for nothing else. In particular it is
## not an `IPropertyValue`: a value the runtime cannot box has no property-value
## representation to report, so claiming otherwise would be a lie a caller
## could act on.

import ./core
include ./abidef

type
  ReferenceVtbl[T] {.pure.} = object
    base: InspectableVtbl
    getValue: proc(self: pointer, value: ptr T): HRESULT {.abi.}

  ValueRef[T] {.pure.} = object
    ## On the COM heap: WinRT may hold it past the call that took it, release
    ## it from any thread, and its lifetime is COM's rather than Nim's.
    vtbl: ptr ReferenceVtbl[T]   ## must stay first
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

proc refQuery[T](self: pointer, riid: ptr GUID,
                 ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let r = cast[ptr ValueRef[T]](self)
  if riid[] == IID_IUnknown or riid[] == IID_IInspectable or
     riid[] == IID_IAgileObject or riid[] == r.iid:
    ppv[] = self
    discard refAddRef[T](self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc refIids[T](self: pointer, count: ptr uint32,
                iids: ptr ptr GUID): HRESULT {.abi.} =
  if not count.isNil: count[] = 0
  if not iids.isNil: iids[] = nil
  S_OK

proc refClassName[T](self: pointer, name: ptr HSTRING): HRESULT {.abi.} =
  # There is no runtime class behind this — it is a Nim object standing in for
  # one — and an empty HSTRING is how WinRT spells "nothing to say".
  if not name.isNil: name[] = HSTRING(nil)
  S_OK

proc refTrust[T](self: pointer, level: ptr int32): HRESULT {.abi.} =
  if not level.isNil: level[] = 0     # BaseTrust
  S_OK

proc refGetValue[T](self: pointer, value: ptr T): HRESULT {.abi.} =
  if value.isNil: return E_POINTER
  value[] = cast[ptr ValueRef[T]](self).value
  S_OK

proc newReference*[T](value: T, iid: GUID): pointer =
  ## `value` as an `IReference<T>`, with a refcount of 1.
  ##
  ## Hand it to the method that wanted one and release it afterwards; the
  ## object frees itself once the callee has let go.
  ##
  ## `iid` is the instantiation's, which the generated code computes — there is
  ## no GUID for `IReference<Color>` anywhere in the metadata to read.
  # One table per instantiation, which is what `{.global.}` in a generic proc
  # means. The alternative, a table per object, would put a writable copy of
  # six function pointers next to every boxed value.
  var vtbl {.global.} = ReferenceVtbl[T](
    base: InspectableVtbl(
      queryInterface: refQuery[T], addRef: refAddRef[T],
      release: refRelease[T], getIids: refIids[T],
      getRuntimeClassName: refClassName[T], getTrustLevel: refTrust[T]),
    getValue: refGetValue[T])
  let r = cast[ptr ValueRef[T]](comAlloc(sizeof(ValueRef[T])))
  r.vtbl = vtbl.addr
  r.refs = 1
  r.iid = iid
  r.value = value
  cast[pointer](r)
