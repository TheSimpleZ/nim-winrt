# winrt

[![CI](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml)

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
| toast notifications, tiles, badges | `winrt/ui` |
| geolocation | `winrt/devices` |
| the camera, media playback, speech | `winrt/media` |
| app packaging, background tasks, app data | `winrt/applicationmodel` |
| MIDI, USB, HID, serial, smart cards | `winrt/devices` |
| Wi-Fi, mobile broadband, sockets | `winrt/networking` |
| the power and battery state | `winrt/system` |
| sensors: accelerometer, light, pedometer | `winrt/devices` |

Not everything Windows can do is in here, and the notification-area tray icon
is the one people expect and do not find: that is `Shell_NotifyIcon` in
shell32, a Win32 call with no WinRT equivalent. `Windows.UI.Notifications`
covers toasts, tiles and badges, which are a different thing. For Win32 use
[winim](https://github.com/khchen/winim) alongside this — a tray application
that reads a gamepad needs one call from each.

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
nimble install https://github.com/TheSimpleZ/nim-winrt
```

or in your `.nimble` file:

```nim
requires "https://github.com/TheSimpleZ/nim-winrt >= 0.3.0"
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
`winrt/gaming` adds 0.3s, `winrt/devices` 2.8s and `winrt/ui` 9.4s.

Each module also imports `winrt/foundation`, because nearly everything names
something in it. It does not import its other dependencies: doing that recovers
about 900 more methods and takes `winrt/ui` from ten seconds to sixty-four, so
a method whose parameter is a class from a third namespace is skipped instead.
The ABI layer still has it.

## Async

A WinRT method that does anything slow hands back an operation object rather
than a result. Those are ordinary Nim `Future`s here, so they compose with
`std/asyncdispatch` and nothing else is needed:

```nim
import winrt, winrt/devices

let adc = waitFor AdcController.getDefaultAsync()
```

or `await` them inside an `{.async.}` proc. There is no separate blocking
spelling of each method: `waitFor` already is one.

The Future is completed by the operation's own completion handler, not by
polling it. Two details make that safe, and both are in `asyncops.nim`: the
handler object answers `QueryInterface` for `IAgileObject`, so WinRT invokes it
on the completing thread instead of marshalling back to a single-threaded
apartment that is blocked in `waitFor`; and all it does there is signal an
`AsyncEvent`, because `asyncdispatch` is single-threaded and completing a
`Future` from a thread pool thread would be a data race.

A module that has no async methods does not import `std/asyncdispatch`, so a
program that never awaits does not pay for it.

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
generated signature. On top of that sit 4,482 classes with 29,734 methods,
properties and constructors, and 2,840 events: **91% of the class surface**.

The other 9% is reported rather than guessed at — every generator run prints
what it skipped and why. It falls into two kinds.

**Deliberately bounded.** A method whose parameter is a class, enum or struct
belonging to a third namespace group is skipped, because naming it would mean
importing that group's module. Each module imports `winrt/foundation` for this
reason and stops there: importing every dependency recovers about 900 more
methods and takes `import winrt/ui` from ten seconds to sixty-four. That is a
trade, not an omission, and the ABI layer still has every one of them.

| | methods |
| --- | ---: |
| a class or interface from a third namespace | 933 |
| an enum from one | 251 |
| a struct from one | 77 |

**Not built yet.** Each needs machinery that does not exist rather than a
decision:

| | methods | what it needs |
| --- | ---: | --- |
| a collection as a *parameter* | 703 | a COM object exposing a Nim `seq` as `IIterable<T>` |
| an array | 285 | element types through the reader, and three ABI conventions |
| `IReference<T>` as a *parameter* | 282 | boxing a value through `PropertyValue` |
| `IMap<K, V>` / `IMapView<K, V>` | 126 | iterating `IKeyValuePair<K, V>` |
| an async result this cannot fetch | 119 | the remaining `GetResults` shapes |

Reading a collection, awaiting an operation, unwrapping an `IReference<T>` and
receiving out-parameters all work — it is the other direction that is missing
in each case.

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
