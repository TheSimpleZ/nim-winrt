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
requires "https://github.com/TheSimpleZ/winrt-nim >= 0.3.0"
```

## A first program

```nim
import winrt
import winrt/system

discard initApartment()

echo PowerManager.batteryStatus            # Idle
echo PowerManager.remainingChargePercent   # 87
```

`PowerManager` is a *static* class — it has no instances, and everything it can
do is reached through its activation factory. That is the usual shape for the
small informational APIs, and you do not have to know it: the generator reads
which shape a class has out of the metadata and gives you members that work.

The three shapes, all generated:

```nim
import winrt, winrt/globalization, winrt/foundation, winrt/system

let cal = newCalendar()                       # no arguments
let uri = Uri.createUri("https://nim-lang.org/docs/manual.html")
echo uri.host                                 # nim-lang.org
echo PowerManager.batteryStatus               # no instances at all
```

Nothing above is released by hand and no string is converted. Objects are one
pointer wide and reference-counted by the compiler, so a `Uri` that goes out of
scope drops its reference; `uri.host` is a Nim `string`.

`nimble examples` builds and runs every program in `examples/`:

| example | shows |
| --- | --- |
| `examples/battery.nim` | a static class |
| `examples/uri.nim` | a class built through its factory |
| `examples/calendar.nim` | an ordinary class, constructed and read |
| `examples/events.nim` | subscribing and unsubscribing |

## Import what you use

The bindings are one module per namespace group, and each group is two modules:
`winrt/gaming` is the API, `winrt/abi/gaming` the vtable underneath it.
Importing the first gives you the second too. A module costs what it contains,
not what the package holds:

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

## When you need the layer underneath

The API layer covers most of the surface, and what it does not cover is
reported rather than hidden: a signature involving an array, a generic
collection or an async operation is skipped, and roughly 2% of methods are.
For those, and for anything where you want to see exactly what is happening,
`winrt/abi/<module>` has the raw vtable.

Every WinRT call is the same four steps, and this is what the generated code
above compiles into:

```nim
import winrt
import winrt/abi/foundation

proc main() =
  discard initApartment()

  # 1. An interface pointer, from the activation factory.
  let factory = activationFactory("Windows.Foundation.Uri",
                                  IID_IUriRuntimeClassFactory)
  defer: release(factory)

  # 2. The method, by its slot number, typed by its generated signature. The
  #    declared return is a trailing out-parameter, and the call itself
  #    returns an HRESULT.
  var uri: pointer
  withHString("https://nim-lang.org", s):
    let createUri = factory.vcall(Slot_IUriRuntimeClassFactory_CreateUri,
                                  Fn_IUriRuntimeClassFactory_CreateUri)
    createUri(factory, s, uri.addr).check("Uri.CreateUri")
  defer: release(uri)

  # 3. An out HSTRING is yours to free; `takeString` converts and frees it.
  var h: HSTRING
  uri.vcall(Slot_IUriRuntimeClass_get_Host,
            Fn_IUriRuntimeClass_get_Host)(uri, h.addr).check("Uri.get_Host")
  echo takeString(h)

main()
```

### The one thing that will bite you

Slots are numbered **per interface**, not per object. Counting into the table
of an interface the object did not hand you finds whatever sits at that index
in a different table — a wrong call rather than an error. Always call through
the pointer `queryInterface` or `activationFactory` gave you for the interface
that declares the method. The API layer does this for you; here it is yours to
get right.

## What is and is not covered

Every interface in `Windows.winmd` that carries a GUID is here — 8,178 of them,
33,719 vtable slots, 1,724 enums and 124 structs, with 98% of the slots given a
generated signature. On top of that sit 4,465 classes with 25,980 methods,
properties and constructors, and 2,840 events.

What the API layer does not reach, it says so rather than guessing:

* **Collections.** `IVector<T>`, `IVectorView<T>` and `IMap<K, V>` are not Nim
  `seq`s or tables yet. A method taking or returning one is skipped, and the
  ABI still has it.
* **Async.** A method returning `IAsyncOperation<T>` is skipped for the same
  reason. Reaching one means dropping to the ABI, holding the operation object
  and setting a completion handler yourself. This is the biggest gap — anything
  file, device or network shaped is async.
* **Arrays.** A handful of methods take or return one; they have no generated
  signature at either layer.

Both of those are the next things to build, and neither is a limit of the
approach — the metadata describes them fully.

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
