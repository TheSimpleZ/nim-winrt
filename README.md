# winrt

[![CI](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml)

The Windows Runtime, projected into Nim. Every class, method, property and
event in the Windows SDK's metadata — 4,670 classes, 33,056 methods, 2,908
events — generated and checked in, so using them is just importing a module.

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
| Wi-Fi, mobile broadband, sockets, HTTP | `winrt/networking`, `winrt/web` |
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

```text
nimble install https://github.com/TheSimpleZ/nim-winrt
```

or in your `.nimble` file:

```nim
requires "https://github.com/TheSimpleZ/nim-winrt >= 0.5.0"
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
| `examples/shapes.nim` | collections, maps, out-parameters and a `Future` |
| `examples/lowlevel.nim` | the same call through the ABI module by hand |

## What things look like from Nim

Each WinRT shape has one Nim spelling, and it is the one you would expect:

| WinRT | Nim |
| --- | --- |
| a class | an object, one pointer wide, reference-counted for you |
| `String` | `string` |
| an enum | an enum; a `[Flags]` enum is a `distinct uint32` with `or` and `and` |
| a struct | an object with the same fields |
| `IVectorView<T>`, `IVector<T>`, `IIterable<T>` | `seq[T]`, in either direction |
| `IMapView<K, V>`, `IMap<K, V>` | `Table[K, V]`, in either direction |
| `IReference<T>` | `Option[T]` |
| `T[]` | `openArray[T]` in, `seq[T]` out |
| `IAsyncOperation<T>` | `Future[T]` |
| an `[out]` parameter | a field of the returned tuple |
| a delegate | a closure |
| an event | `onName(handler)`, which returns a token for `removeName` |

Collections nest — a `FileSavePicker`'s file type choices are a
`Table[string, seq[string]]` — and a collection you hand *in* is copied, so
the runtime cannot change your `seq` behind your back.

```nim
import winrt, winrt/[devices, globalization, web]

# A seq of structs in, and back out.
let path = Geopath.create(@[
  BasicGeoposition(latitude: 59.33, longitude: 18.07),
  BasicGeoposition(latitude: 57.71, longitude: 11.97)])
echo path.positions.len                             # 2

# A Table in.
let form = HttpFormUrlEncodedContent.create({"q": "nim"}.toTable)
echo waitFor form.readAsStringAsync()               # q=nim

# An out-parameter beside the declared return.
let (outcome, info) = PhoneNumberInfo.tryParse("+46 8 123 456", "SE")
```

### Events

An event handler takes the sender and the arguments as the classes they are:

```nim
import winrt, winrt/system

let token = PowerManager.onEnergySaverStatusChanged(
  proc(sender, args: WinRtObject) = echo "changed")
PowerManager.removeEnergySaverStatusChanged(token)
```

`WinRtObject` is what every class derives from, and what you get where the
metadata says only `Object`. Any class passes where it is expected.

### Async

A WinRT method that does anything slow hands back an operation object rather
than a result. Those are ordinary Nim `Future`s here, so they compose with
`std/asyncdispatch` and nothing else is needed:

```nim
import winrt, winrt/devices

let adc = waitFor AdcController.getDefaultAsync()
```

or `await` them inside an `{.async.}` proc. There is no separate blocking
spelling of each method: `waitFor` already is one.

The Future is completed by the operation's own completion handler, on whatever
thread the operation finishes on, and the dispatcher is only woken from there —
`asyncdispatch` is single-threaded, so completing a `Future` from a thread pool
thread would be a data race. A module that has no async methods does not
import `std/asyncdispatch`.

### Callbacks run where the runtime runs them

A closure you hand to `ThreadPool.runAsync`, or to a device watcher's event,
runs on a thread the runtime chose, not on yours. Nim's memory management
is not prepared for that thread: **a handler that may run there must not
allocate or touch garbage-collected memory** — no `echo`, no string building,
no `seq` appends. Write to a plain variable, or signal the main thread with an
`AsyncEvent` and do the work there, which is exactly how the async support
above completes a `Future`. A handler for a UI event runs on the UI thread and
has no such constraint.

## Import what you use

The bindings are one module per namespace group, and each group is two modules:
`winrt/gaming` is the API, `winrt/abi/gaming` the vtable underneath it.
Importing the first gives you the second too, along with `winrt` itself and
the type declarations every module shares. A module costs what it contains:

| module | namespace | interfaces | compile cost |
| --- | --- | ---: | ---: |
| `winrt/foundation` | `Windows.Foundation.*` | 72 | +0.7s |
| `winrt/ai` | `Windows.AI.*` | 139 | +1.3s |
| `winrt/applicationmodel` | `Windows.ApplicationModel.*` | 1,010 | +7.1s |
| `winrt/data` | `Windows.Data.*` | 62 | +0.9s |
| `winrt/devices` | `Windows.Devices.*` | 1,006 | +4.0s |
| `winrt/gaming` | `Windows.Gaming.*` | 71 | +1.2s |
| `winrt/globalization` | `Windows.Globalization.*` | 63 | +0.7s |
| `winrt/graphics` | `Windows.Graphics.*` | 287 | +2.0s |
| `winrt/management` | `Windows.Management.*` | 125 | +1.2s |
| `winrt/media` | `Windows.Media.*` | 842 | +5.0s |
| `winrt/networking` | `Windows.Networking.*` | 362 | +2.3s |
| `winrt/perception` | `Windows.Perception.*` | 52 | +0.9s |
| `winrt/security` | `Windows.Security.*` | 254 | +1.5s |
| `winrt/services` | `Windows.Services.*` | 127 | +1.6s |
| `winrt/storage` | `Windows.Storage.*` | 195 | +1.7s |
| `winrt/system` | `Windows.System.*` | 280 | +1.7s |
| `winrt/ui` | `Windows.UI.*` | 3,074 | +6.7s |
| `winrt/web` | `Windows.Web.*` | 165 | +1.5s |

Compile cost is measured against a program that imports `winrt` alone, which
takes 0.6s; the figures are for one import on a 2026 laptop and are what the
bindings' declarations cost the compiler. Nothing you do not call reaches the
binary: a program that imports all eighteen comes out byte for byte the same
size as one that imports `winrt` alone.

Every module can name every type. A method in `winrt/devices` that returns a
`Windows.Storage.StorageFile` returns a `StorageFile`, and a `winrt/ui` method
that takes a `Windows.Graphics.SizeInt32` takes one.

Importing `winrt` alone gives the runtime itself — strings, GUIDs, apartment
setup, activation, delegates — and none of the bindings.

## When you need the layer underneath

Every WinRT call is the same four steps, and this is what the generated code
compiles into:

```nim
import winrt
import winrt/abi/foundation

proc main() =
  discard initApartment()

  # 1. An interface pointer, from the activation factory. `factory` is typed
  #    by its interface, so only that interface's methods can be called on it.
  withStatics("Windows.Foundation.Uri", IUriRuntimeClassFactory, factory):

    # 2. The method, as a field of the interface's vtable. Every method
    #    returns an HRESULT; the declared return is a trailing out-parameter.
    var uri: pointer
    withHString("https://nim-lang.org", s):
      check factory.vtbl.CreateUri(factory, s, uri.addr), "Uri.CreateUri"
    defer: release(uri)

    # 3. Narrow to the interface that declares the method you want.
    withIface(uri, IUriRuntimeClass, it):

      # 4. An out HSTRING is yours to free; `takeString` converts and frees it.
      var h: HSTRING
      check it.vtbl.get_Host(it, h.addr), "Uri.get_Host"
      echo takeString(h)

main()
```

`winrt/abi/<module>` has every interface as `IID_X` and `XVtbl`, an object
whose fields are the methods in vtable order — the same shape the C headers
and C++/WinRT use, and the same shape winim uses for COM.

### The one thing that will bite you

Methods are numbered **per interface**, not per object. Calling a method
through a pointer for an interface the object did not hand you reaches
whatever sits at that position in a different table — a wrong call rather than
an error. The vtable types make that a compile error where they can, and
`withIface` gives you a pointer typed by the interface that declares the
method; use that one and not whichever pointer happens to be at hand.

## What is and is not covered

Everything in `Windows.winmd`. Every interface that carries a GUID — 8,186 of
them, 33,724 vtable slots, 1,725 enums and 124 structs — and on top of that
every class, method, property, constructor and event: 4,670 classes, 33,056
methods and 2,908 events, with nothing skipped. The generator still counts and
prints anything it cannot spell, because a future SDK may add a shape it does
not know; on this one the count is zero.

What is *not* here is anything outside that metadata: Win32, the Windows App
SDK's own runtime, and third-party components. The generator can be pointed at
another `.winmd` — see [docs/generating.md](docs/generating.md).

## Troubleshooting

**`Pointer size mismatch between Nim and C/C++ backend` in `nimbase.h`.** Your
Nim is targeting 32-bit while your C compiler builds 64-bit — usually because
`nimble` and a direct `nim c` are picking different Nim installations. Put

```text
--cpu:amd64
```

in your project's `nim.cfg`.

**`REGDB_E_CLASSNOTREG` from `activationFactory`.** The class is real but
nothing in the process knows where to find it. For a class that ships in
Windows this should not happen; for one belonging to a separate runtime, such
as the Windows App SDK, that runtime is not deployed alongside your executable.
Assign `activationHint` to add your own explanation to the error.

**A crash inside a callback, with no Nim traceback.** The handler ran on a
runtime thread and touched Nim's heap — see *Callbacks run where the runtime
runs them* above.

**`ambiguous identifier`.** Two *different* declarations share a name. It will
not come from importing two binding modules together — they share one set of
type declarations, so naming both is harmless. It comes from another package
declaring its own version of a Windows type, which is a different Nim type
even where the bytes match. Import one of them with `except`, or qualify the
use.

## Documentation

* [docs/internals.md](docs/internals.md) — how the bindings are produced: the
  ECMA-335 reader, the two layers and why they are shaped that way, what
  crosses and how, parameterised IIDs, delegates and threads.
* [docs/generating.md](docs/generating.md) — regenerating against a newer
  Windows SDK, and the diagnostic tools.

Every module carries its own doc comments; `nim doc src/winrt.nim` renders
them.

## License

MIT. See [LICENSE](LICENSE).
