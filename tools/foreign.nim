## Layouts for types that `Microsoft.UI.Xaml.winmd` references but does not
## define.
##
## `Thickness` and `CornerRadius` belong to the XAML namespace, so their fields
## are read straight out of the metadata. `Point`, `Rect`, `Color`, `VirtualKey`
## and the rest live in `Windows.Foundation.winmd`, `Windows.winmd` and the
## `Microsoft.UI.*` winmds, which this project does not ship — yet a signature
## is useless without them.
##
## So they are written out here, once, with their source named. These are ABI
## contracts fixed since Windows 8 and published in the SDK headers; the risk of
## transcribing them is small and bounded, unlike a GUID or a slot index,
## because a wrong field type here fails loudly and immediately — the tests
## round-trip every struct that a control actually uses.
##
## Anything absent from these tables stays unmapped rather than guessed at.

type
  ForeignField* = tuple[name, nimType: string]
  ForeignStruct* = tuple[name: string, fields: seq[ForeignField]]

const foreignStructs*: seq[ForeignStruct] = @[
  # A seq rather than a Table because order is load-bearing: `ManipulationDelta`
  # contains a `Point`, and Nim needs the field's type declared first.

  # windows.foundation.h — `struct Point { FLOAT X; FLOAT Y; }`
  ("Windows.Foundation.Point", @[("x", "float32"), ("y", "float32")]),
  ("Windows.Foundation.Size", @[("width", "float32"), ("height", "float32")]),
  ("Windows.Foundation.Rect", @[("x", "float32"), ("y", "float32"),
                                ("width", "float32"), ("height", "float32")]),

  # Both are a single 64-bit count of 100-nanosecond intervals; DateTime's is
  # measured from the 1601 epoch, TimeSpan's is a duration.
  ("Windows.Foundation.TimeSpan", @[("duration", "int64")]),
  ("Windows.Foundation.DateTime", @[("universalTime", "int64")]),

  # The value every `add_*` hands back and `remove_*` takes. More methods use
  # this than any other struct here.
  ("Windows.Foundation.EventRegistrationToken", @[("value", "int64")]),

  # windows.ui.h — four bytes, alpha first.
  ("Windows.UI.Color", @[("a", "uint8"), ("r", "uint8"),
                         ("g", "uint8"), ("b", "uint8")]),

  # windows.ui.text.h — a struct rather than an enum, unlike FontStyle and
  # FontStretch beside it.
  ("Windows.UI.Text.FontWeight", @[("weight", "uint16")]),

  # windows.foundation.numerics.h
  ("Windows.Foundation.Numerics.Vector2", @[("x", "float32"), ("y", "float32")]),
  ("Windows.Foundation.Numerics.Vector3", @[("x", "float32"), ("y", "float32"),
                                            ("z", "float32")]),
  ("Windows.Foundation.Numerics.Vector4", @[("x", "float32"), ("y", "float32"),
                                            ("z", "float32"), ("w", "float32")]),
  ("Windows.Foundation.Numerics.Quaternion", @[
    ("x", "float32"), ("y", "float32"), ("z", "float32"), ("w", "float32")]),
  ("Windows.Foundation.Numerics.Matrix4x4", @[
    ("m11", "float32"), ("m12", "float32"), ("m13", "float32"), ("m14", "float32"),
    ("m21", "float32"), ("m22", "float32"), ("m23", "float32"), ("m24", "float32"),
    ("m31", "float32"), ("m32", "float32"), ("m33", "float32"), ("m34", "float32"),
    ("m41", "float32"), ("m42", "float32"), ("m43", "float32"), ("m44", "float32")]),

  # The identifier for a top-level window, as the Microsoft.UI namespace
  # defines it.
  ("Microsoft.UI.WindowId", @[("value", "uint64")]),

  # microsoft.ui.input.h — both hold a Point, hence the ordering above.
  ("Microsoft.UI.Input.ManipulationDelta", @[
    ("translation", "Point"), ("scale", "float32"),
    ("rotation", "float32"), ("expansion", "float32")]),
  ("Microsoft.UI.Input.ManipulationVelocities", @[
    ("linear", "Point"), ("angular", "float32"), ("expansion", "float32")]),

  # windows.ui.core.h. The four flags are each one byte on the wire: a WinRT
  # `Boolean` is an 8-bit value, not the 4-byte Win32 `BOOL`.
  ("Windows.UI.Core.CorePhysicalKeyStatus", @[
    ("repeatCount", "uint32"), ("scanCode", "uint32"),
    ("isExtendedKey", "bool"), ("isMenuKeyDown", "bool"),
    ("wasKeyDown", "bool"), ("isKeyReleased", "bool")]),

  # windows.ui.xaml.interop.h — the type identity a ControlTemplate or a Frame
  # navigation target is expressed in. `kind` is a TypeKind: 0 primitive,
  # 1 metadata, 2 custom.
  ("Windows.UI.Xaml.Interop.TypeName", @[("name", "HSTRING"), ("kind", "int32")]),
]

const foreignAliases*: seq[tuple[name, nimType: string]] = @[
  # Types this library already spells, under the name the metadata uses for
  # them. `System.Guid` is the WinRT name for what `core` calls `GUID`, and
  # redeclaring it would give two incompatible 16-byte structs.
  ("System.Guid", "GUID"),
  # A struct wrapping an Int32, which at the ABI is simply an HRESULT. Emitting
  # it as its own type would also collide: Nim compares identifiers
  # case-insensitively after the first character, so `HResult` and `HRESULT` are
  # the same name.
  ("Windows.Foundation.HResult", "HRESULT"),
]

const foreignEnums* = [
  # Enums, not structs. They arrive as TypeRefs this winmd cannot resolve, and
  # the signature reader cannot tell an unresolvable enum from an unresolvable
  # struct, so it reports the safer of the two. Every WinRT enum is 32 bits on
  # the wire whatever its declared backing type, so naming them here is all
  # that is needed.
  "Windows.UI.Text.FontStyle",
  "Windows.UI.Text.FontStretch",
  "Windows.UI.Text.UnderlineType",
  "Windows.UI.Text.CaretType",
  "Windows.UI.Text.TextDecorations",
  "Windows.Foundation.AsyncStatus",
  "Windows.System.VirtualKey",
  "Windows.System.VirtualKeyModifiers",
  "Windows.Globalization.DayOfWeek",
  "Windows.ApplicationModel.DataTransfer.DataPackageOperation",
  "Windows.ApplicationModel.DataTransfer.DragDrop.DragDropModifiers",
  "Microsoft.UI.Input.PointerDeviceType",
  "Microsoft.UI.Input.InputPointerSourceDeviceKinds",
  "Microsoft.UI.Input.HoldingState",
  "Microsoft.UI.Composition.SystemBackdrops.MicaKind",
  "Microsoft.UI.Composition.CompositionColorSpace",
]

const foreignGenerics* = [
  # The GUIDs of the parameterised interfaces themselves, which live in
  # `Windows.Foundation.winmd`. These are *not* the IID of any instantiation —
  # they are the seed that `piid.nim` hashes together with the type arguments
  # to produce one. Published in the Windows SDK headers and unchanged since
  # Windows 8.
  ("Windows.Foundation.Collections.IVector`1", "{913337E9-11A1-4345-A3A2-4E7F956E222D}"),
  ("Windows.Foundation.Collections.IVectorView`1", "{BBE1FA4C-B0E3-4583-BAEF-1F1B2E483E56}"),
  ("Windows.Foundation.Collections.IIterable`1", "{FAA585EA-6214-4217-AFDA-7F46DE5869B3}"),
  ("Windows.Foundation.Collections.IIterator`1", "{6A79E863-4300-459A-9966-CBB660963EE1}"),
  ("Windows.Foundation.Collections.IKeyValuePair`2", "{02B51929-C1C4-4A7E-8940-0312B5C18500}"),
  ("Windows.Foundation.Collections.IMap`2", "{3C2925FE-8519-45C1-AA79-197B6718C1C1}"),
  ("Windows.Foundation.Collections.IMapView`2", "{E480CE40-A338-4ADA-ADCF-272272E48CB9}"),
  ("Windows.Foundation.Collections.IObservableVector`1", "{5917EB53-50B4-4A0D-B309-65862B3F1DBC}"),
  ("Windows.Foundation.Collections.IObservableMap`2", "{65DF2BF5-BF39-41B5-AEBC-5A9D865E472B}"),
  ("Windows.Foundation.Collections.VectorChangedEventHandler`1", "{0C051752-9FBF-4C70-AA0C-0E4C82D9A761}"),
  ("Windows.Foundation.Collections.MapChangedEventHandler`2", "{179517F3-94EE-41F8-BDDC-768A895544F3}"),
  ("Windows.Foundation.IReference`1", "{61C17706-2D65-11E0-9AE8-D48564015472}"),
  ("Windows.Foundation.IAsyncOperation`1", "{9FC2B0BB-E446-44E2-AA61-9CAB8F636AF2}"),
  ("Windows.Foundation.IAsyncOperationWithProgress`2", "{B5D036D7-E297-498F-BA60-0289E76E23DD}"),
  ("Windows.Foundation.AsyncOperationCompletedHandler`1", "{FCDCF02C-E5D8-4478-915A-4D90B74B83A5}"),
  ("Windows.Foundation.TypedEventHandler`2", "{9DE1C534-6AE1-11E0-84E1-18A905BCC53F}"),
  ("Windows.Foundation.EventHandler`1", "{9DE1C535-6AE1-11E0-84E1-18A905BCC53F}"),
]

const foreignFlagEnums* = [
  # Which foreign enums are unsigned. A signature says `enum(Name;i4)` or
  # `enum(Name;u4)`, and flags enums are the unsigned ones — get this wrong and
  # the computed IID is well-formed and matches nothing.
  "Windows.UI.Text.TextDecorations",
  "Windows.System.VirtualKeyModifiers",
  "Windows.ApplicationModel.DataTransfer.DataPackageOperation",
  "Windows.ApplicationModel.DataTransfer.DragDrop.DragDropModifiers",
  "Microsoft.UI.Input.InputPointerSourceDeviceKinds",
]
