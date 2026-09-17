# winrt

[![CI](https://github.com/TheSimpleZ/winrt-nim/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSimpleZ/winrt-nim/actions/workflows/ci.yml)

The Windows Runtime, projected into Nim. 8,178 interfaces and 33,719 methods of
it, generated from the SDK's own metadata and checked in, so using them is just
importing a module.

## Why you would want this

Almost everything Windows has gained since Windows 8 is reachable *only*
through WinRT. There is no Win32 call for these:

| you want | it lives in |
| --- | --- |
| Bluetooth and Bluetooth LE | `winrt/devices` |
| gamepads, racing wheels, flight sticks | `winrt/gaming` |
| toast notifications, the tray, badges | `winrt/ui` |
| geolocation | `winrt/devices` |
| the camera, media playback, speech | `winrt/media` |
| app packaging, background tasks, app data | `winrt/applicationmodel` |
| MIDI, USB, HID, serial, smart cards | `winrt/devices` |
| Wi-Fi, mobile broadband, sockets | `winrt/networking` |
| the power and battery state | `winrt/system` |
| sensors: accelerometer, light, pedometer | `winrt/devices` |

WinRT is COM plus a metadata file describing every interface in it. Every
language reaches it the same way — C++/WinRT, C#/WinRT and windows-rs all
generate bindings from that metadata — and this is the Nim side of it. The
generator lives in `tools/`, but you never have to run it: the output is in the
repository, so installing this package does not need the Windows SDK.

## Requirements

Windows, Nim 2.0 or newer, and nothing else. No SDK, no vendored DLLs, no
build step — the runtime lives in `combase.dll`, which is part of Windows.

## Install

```
nimble install https://github.com/TheSimpleZ/winrt-nim
```

or in your `.nimble` file:

```nim
requires "https://github.com/TheSimpleZ/winrt-nim >= 0.1.0"
```

## A first program

Take a URL apart with the runtime's own parser. `Windows.Foundation.Uri` is
present on every Windows, so this needs no permissions and no deployment:

```nim
import winrt
import winrt/foundation

proc main() =
  discard initApartment()

  # A class with no default constructor is built through its activation
  # factory. The IID picks which of the factory's interfaces you get back.
  let factory = activationFactory("Windows.Foundation.Uri",
                                  IID_IUriRuntimeClassFactory)
  defer: release(factory)

  var uri: pointer
  withHString("https://nim-lang.org/docs/manual.html", s):
    let createUri = factory.vcall(Slot_IUriRuntimeClassFactory_CreateUri,
                                  Fn_IUriRuntimeClassFactory_CreateUri)
    createUri(factory, s, uri.addr).check("Uri.CreateUri")
  defer: release(uri)

  var host: HSTRING
  let getHost = uri.vcall(Slot_IUriRuntimeClass_get_Host,
                          Fn_IUriRuntimeClass_get_Host)
  getHost(uri, host.addr).check("Uri.get_Host")
  echo $host                      # nim-lang.org
  discard windowsDeleteString(host)

main()
```

`examples/uri.nim` is this program with the rest of the URL's parts.
`nimble examples` builds and runs every example in that directory:

| example | shows |
| --- | --- |
| `examples/uri.nim` | activation through a factory, strings |
| `examples/battery.nim` | a static class, enums |
| `examples/calendar.nim` | `activateInstance`, `queryInterface` |
| `examples/events.nim` | subscribing with a delegate |

## Import what you use

The bindings are one module per namespace group. A module costs what it
contains, not what the package holds:

| module | namespace | interfaces |
| --- | --- | ---: |
| `winrt/foundation` | `Windows.Foundation.*` | 72 |
| `winrt/ai` | `Windows.AI.*` | 139 |
| `winrt/applicationmodel` | `Windows.ApplicationModel.*` | 1,010 |
| `winrt/data` | `Windows.Data.*` | 62 |
| `winrt/devices` | `Windows.Devices.*` | 1,006 |
| `winrt/gaming` | `Windows.Gaming.*` | 71 |
| `winrt/globalization` | `Windows.Globalization.*` | 63 |
| `winrt/graphics` | `Windows.Graphics.*` | 287 |
| `winrt/management` | `Windows.Management.*` | 125 |
| `winrt/media` | `Windows.Media.*` | 841 |
| `winrt/networking` | `Windows.Networking.*` | 362 |
| `winrt/perception` | `Windows.Perception.*` | 52 |
| `winrt/security` | `Windows.Security.*` | 254 |
| `winrt/services` | `Windows.Services.*` | 127 |
| `winrt/storage` | `Windows.Storage.*` | 195 |
| `winrt/system` | `Windows.System.*` | 280 |
| `winrt/ui` | `Windows.UI.*` | 3,067 |
| `winrt/web` | `Windows.Web.*` | 165 |

Importing `winrt` alone gives the runtime itself — strings, GUIDs, apartment
setup, activation, delegates — and none of the bindings. A binding module
re-exports it, so importing `winrt/gaming` is enough on its own.

Nothing you do not call reaches the binary: these modules are declarations, so
a program that imports all eighteen comes out byte for byte the same size as
one that imports `winrt` alone. The cost is compile time, and it is
concentrated in one module — measured against `import winrt` on a 2026 laptop,
`winrt/gaming` adds 0.03s, `winrt/devices` 0.3s, `winrt/ui` 1.9s, and all
eighteen together 2.0s, because `ui` already pulls in most of the rest.

## How to call a method

Every WinRT call is the same four steps.

**1. Get an interface pointer.** Either from an activation factory, for a class
with static methods or a non-default constructor:

```nim
let factory = activationFactory("Windows.Gaming.Input.Gamepad", IID_IGamepadStatics)
```

or by creating an instance and narrowing it:

```nim
let obj = activateInstance("Windows.Globalization.Calendar")
let cal = obj.queryInterface(IID_ICalendar)
```

Both hand you a reference that is yours to `release`.

**2. Find the method.** Each interface contributes three generated names:

* `IID_<Interface>` — the interface's GUID,
* `Slot_<Interface>_<Method>` — its index in the vtable,
* `Fn_<Interface>_<Method>` — its ABI signature.

**3. Call it.** `vcall` reads the slot out of the table and casts it:

```nim
var year: int32
let getYear = cal.vcall(Slot_ICalendar_get_Year, Fn_ICalendar_get_Year)
getYear(cal, year.addr).check("Calendar.get_Year")
```

**4. Release what you were given.** WinRT is COM: a getter that returns an
object hands you a reference, and a string is yours to delete.

### The one thing that will bite you

**Slots are numbered per interface.** Slot 6 of `ICalendar` is `Clone`; slot 6
of `ITimeZoneOnCalendar` is `GetTimeZone`. Using a slot against a pointer for a
different interface is not an error — it calls whatever sits at that index in
the other table. So pass the pointer `queryInterface` gave you for the
interface the method belongs to, not whichever pointer is at hand.

### Signatures

Every WinRT method returns `HRESULT`, and its *declared* return type becomes a
trailing out-parameter. `get_Host() -> HSTRING` is:

```nim
proc(self: pointer, value: ptr HSTRING): HRESULT {.stdcall.}
```

`check` raises a `WinRtError` on failure with the HRESULT attached; `succeeded`
and `failed` are there if you would rather branch.

### Strings

`HSTRING` is a handle the runtime owns, not a Nim string.

```nim
withHString("text", h):        # created, and deleted however the block exits
  useIt(h)

echo $someHString              # HSTRING -> string
discard windowsDeleteString(h) # a string a method returned is yours to delete
```

### Enums and structs

Most enums are ordinary Nim enums, `{.pure.}` and pinned to four bytes, so a
signature says `ptr BatteryStatus` and you write `BatteryStatus.Charging`. An
enum marked `[Flags]` in the metadata cannot be one — it holds combinations —
so those stay `distinct int32` and carry `or`, `and`, `not` and `in`:

```nim
let held = GamepadButtons_A or GamepadButtons_Menu
if GamepadButtons_A in held: echo held      # Menu or A
```

Either way `$` falls back to `BatteryStatus(99)` for a value newer than this
metadata, which the built-in one renders as an empty string.
They cross the ABI as `int32`, so a generated signature says `ptr int32` and
you convert on this side.

Structs that cross by value have real Nim layouts: `Point`, `Rect`, `Color`,
`TimeSpan`, `EventRegistrationToken` and 119 more. Interfaces do not — at this
layer every interface is a bare `pointer`, which is what it is on the wire.

### Events

An event is `add_X(handler) -> token` and `remove_X(token)`, where the handler
is a COM object the runtime calls back into. `newEventDelegate` builds one
around a Nim closure:

```nim
let handler = newEventDelegate(iid, proc(sender, args: pointer) = echo "fired")
add(source, handler, token.addr).check("add_X")
release(handler)   # the event source took its own reference
```

The IID is the awkward part: most events take `EventHandler<T>` or
`TypedEventHandler<S, A>`, which have no GUID in any metadata file — the
runtime derives one by hashing a signature string. This package does not
generate those constants yet, but `tools/piidcheck.nim` prints the signature
and the IID for every instantiation the SDK uses, and `examples/events.nim`
shows a subscription end to end.

## What is and is not covered

Every interface in `Windows.winmd` that carries a GUID is here — 8,178 of them,
33,719 vtable slots, 1,724 enums and 124 structs. 98% of those slots have a
generated signature.

Signatures are skipped rather than guessed at, so the 2% that have none are
methods whose shape this generator cannot spell yet. `Slot_*` is still emitted
for them, so you can call one with a hand-written signature. Almost all of them
take or return an **array** (`ILampArray.SetColorsForIndices`,
`ITextProvider.GetSelection`); a handful involve a type variable.

Two more things to know about the ceiling:

* **Generics are opaque.** `IVector<T>`, `IAsyncOperation<T>`,
  `IReference<T>` and `TypedEventHandler<S, A>` are interface pointers like any
  other on the wire, so about 5,200 methods are typed — as `pointer`. Calling
  through one works; the type just tells you nothing, and you need the computed
  IID to `queryInterface` for it.
* **Async is manual.** A method returning `IAsyncOperation<T>` gives you the
  operation object; there is no `await` here yet, so you set a completion
  handler or poll `get_Status` yourself.

This is deliberately the ABI rather than a friendly API — it is what a friendly
API gets built on, and what makes one possible without hand-writing thousands
of declarations. [winui3-nim](https://github.com/TheSimpleZ/winui3-nim) is an
example of the layer above.

## Troubleshooting

**`Pointer size mismatch between Nim and C/C++ backend` in `nimbase.h`.** Your
Nim is targeting 32-bit while your C compiler builds 64-bit — usually because
`nimble` and a direct `nim c` are picking different Nim installations. Put

```
--cpu:amd64
```

in your project's `nim.cfg`.

**`REGDB_E_CLASSNOTREG` from `activationFactory`.** The class is real but
nothing in the process knows where to find it. For a class that ships in
Windows this should not happen; for one belonging to a separate runtime, such
as the Windows App SDK, that runtime is not deployed alongside your executable.
Assign `activationHint` to add your own explanation to the error.

**`ambiguous identifier`.** Two *different* declarations share a name. It will
not come from importing a binding module and its dependency together — every
module re-exports what it depends on, so `import winrt/gaming` already brings
`winrt/foundation` with it and naming both is harmless. It comes from another
package declaring its own version of a Windows type, which is a different Nim
type even where the bytes match. Import one of them with `except`, or qualify
the use.

## Documentation

* [docs/internals.md](docs/internals.md) — how the bindings are produced: the
  ECMA-335 reader, the ABI mapping, the module split and why it is shaped that
  way, parameterised IIDs.
* [docs/generating.md](docs/generating.md) — regenerating against a newer
  Windows SDK, and the diagnostic tools.

Every module carries its own doc comments; `nim doc src/winrt.nim` renders
them.

## License

MIT. See [LICENSE](LICENSE).
