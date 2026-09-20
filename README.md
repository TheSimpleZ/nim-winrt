# winrt

[![CI](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml/badge.svg)](https://github.com/TheSimpleZ/nim-winrt/actions/workflows/ci.yml)

The Windows Runtime, projected into Nim. Every class, method, property and
event in the Windows SDK's metadata — 4,495 classes, 30,003 members, 1,401
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
requires "https://github.com/TheSimpleZ/nim-winrt >= 1.0.0"
```

## A first program

```nim
import winrt/system

echo PowerManager.batteryStatus            # Idle
echo PowerManager.remainingChargePercent   # 87
```

That is the whole program. There is nothing to start: the first call brings
the runtime up on that thread, and nothing has to be shut down either.

`PowerManager` is a *static* class — it has no instances, and everything it can
do is reached through its activation factory. That is the usual shape for the
small informational APIs, and you do not have to know it: the generator reads
which shape a class has out of the metadata and gives you members that work.

The three shapes, all generated:

```nim
import winrt/[globalization, foundation, system]

let cal = newCalendar()                       # no arguments
let uri = newUri("https://nim-lang.org/docs/manual.html")
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
| `examples/buffer.nim` | an object of yours that Windows calls, through two interfaces |
| `examples/lowlevel.nim` | the same call through the ABI module by hand |

## What things look like from Nim

Each WinRT shape has one Nim spelling, and it is the one you would expect:

| WinRT | Nim |
| --- | --- |
| a class | an object, one pointer wide, reference-counted for you |
| `String` | `string`, including inside a struct |
| an enum | an enum; a `[Flags]` enum is a `distinct uint32` with `or` and `and` |
| a struct | an object with the same fields |
| an interface several classes implement | `SomeInputStream`, which any of them satisfies |
| `IVectorView<T>`, `IVector<T>`, `IIterable<T>` | `seq[T]`, in either direction |
| `IMapView<K, V>`, `IMap<K, V>` | `Table[K, V]`, in either direction |
| `IReference<T>` | `Option[T]`, including inside a struct |
| `T[]` | `openArray[T]` in, `seq[T]` out |
| `IAsyncOperation<T>` | `Future[T]`, which `cancel` can stop |
| `IAsyncOperationWithProgress<T, P>` | `Future[T]`, and a `progress: proc(value: P)` argument |
| an `[out]` parameter | the result, or a field of the returned tuple |
| a delegate | a closure, run on your thread |
| an event | `onName(handler)`, which returns a token for `removeName` |
| an interface Windows should call | `implement(XVtbl(...))`, one interface or several |
| a failure | `WinRtError`, with the `HRESULT` and the runtime's message |

Collections nest — a `FileSavePicker`'s file type choices are a
`Table[string, seq[string]]` — and a collection you hand *in* is copied, so
the runtime cannot change your `seq` behind your back.

```nim
import std/tables
import winrt/[devices, globalization, web]

# A seq of structs in, and back out.
let path = newGeopath(@[
  BasicGeoposition(latitude: 59.33, longitude: 18.07),
  BasicGeoposition(latitude: 57.71, longitude: 11.97)])
echo path.positions.len                             # 2

# A Table in.
let form = newHttpFormUrlEncodedContent({"q": "nim"}.toTable)
echo waitFor form.readAsStringAsync()               # q=nim

# An out-parameter beside the declared return.
let (outcome, info) = PhoneNumberInfo.tryParse("+46 8 123 456", "SE")
```

### One method, every class that has it

Most WinRT interfaces belong to a single class, and their methods are written
on that class. An interface that several classes implement — `IBuffer`,
`IInputStream`, `IClosable` — gets its methods written once, over a type class
named after it, so every implementer satisfies it and the wrong type is a
compile error rather than a failed `QueryInterface`:

```nim
proc readAsync*(self: SomeInputStream, buffer: SomeBuffer, count: uint32,
                options: InputStreamOptions): Future[IBuffer]
```

`SomeInputStream` is every class that lists `IInputStream`, every interface
that requires it, and `IInputStream` itself. A value you hold only as the
interface — one Windows handed you — has the same methods as a value you hold
as the class.

### Events

An event handler takes the sender and the arguments as the classes they are:

```nim
import winrt/system

let token = PowerManager.onEnergySaverStatusChanged(
  proc(sender: WinRtObject, args: WinRtObject) = echo "changed")
PowerManager.removeEnergySaverStatusChanged(token)
```

`WinRtObject` is what every class derives from, and what you get where the
metadata says only `Object`. Any class passes where it is expected, and
`obj.to(StorageFile)` goes the other way when you know what it really is.

### Async

A WinRT method that does anything slow hands back an operation object rather
than a result. Those are ordinary Nim `Future`s here, so they compose with
`std/asyncdispatch` and nothing else is needed:

```nim
import winrt/devices

let adc = waitFor AdcController.getDefaultAsync()
```

or `await` them inside an `{.async.}` proc. There is no separate blocking
spelling of each method: `waitFor` already is one.

The Future is completed by the operation's own completion handler, on whatever
thread the operation finishes on, and the dispatcher is only woken from there —
`asyncdispatch` is single-threaded, so completing a `Future` from a thread pool
thread would be a data race. Handlers ride on the same dispatcher, so a module
with async methods or events imports `std/asyncdispatch` and one with neither
does not.

An operation can be asked to stop. `cancel(fut)` calls its `Cancel`, and when
the operation honours that the Future fails with a `CancelledError`; one that
was about to finish anyway completes as it would have. An operation that
reports progress — an `IAsyncOperationWithProgress<T, P>` — takes a closure
for it as its last argument, called on your thread with each value:

```nim
let page = waitFor newHttpClient().getStringAsync(uri,
  progress = proc(value: HttpProgress) = echo value.stage, " ", value.bytesReceived)
```

### Handlers run on your thread

A closure you hand to `ThreadPool.runAsync`, or to a device watcher's event,
is invoked by the runtime on a thread of its choosing — and then run by this
library on the thread that created it, while the runtime's thread waits. So a
handler can do what any Nim code does: build strings, append to a `seq`,
touch your objects. What it costs is that your thread has to be running the
dispatcher for a handler from elsewhere to be delivered — `waitFor`,
`runForever` or `poll`, not `sleep`. A handler that genuinely wants the
runtime's thread, such as a work item meant to run in parallel, is made with
`newDelegate(..., raw = true)` and must not touch garbage-collected memory
there; `runOnDispatcher(fn, arg)` is how code on such a thread hands work
back to yours, without waiting for it.

### Threading

The runtime starts itself, multithreaded, the first time a thread reaches it.
That is what a service, a tool or a test wants: the runtime marshals nothing
and a callback arrives on whatever thread it happens on. A UI framework needs
the other model, and says so before its first call:

```nim
initRuntime(singleThreaded)
```

after which objects made on that thread are called on that thread, and that
thread has to pump COM messages for a call from elsewhere to arrive.

### Implementing an interface

Sometimes Windows wants an object of *yours*: an `INotifyPropertyChanged`
for data binding, an `ICommand`, a background task, an `IBuffer` over bytes
you already have. `implement` takes each interface's vtable type from the
ABI module with your methods filled in, and returns a COM object Windows can
hold, query and call. A buffer is two interfaces — `IBuffer` for the length,
and the COM-side `IBufferByteAccess` for the bytes — so the object implements
both, and `QueryInterface` leads Windows from one to the other:

```nim
import winrt/[storage, security]
include winrt/abidef          # the `abi` calling convention for your methods

const IID_IBufferByteAccess = guid"905A0FEF-BC53-11DF-8C49-001E4FC686DA"

type
  Bytes = ref object
    data: seq[byte]
  IBufferByteAccessVtbl = object of IUnknownVtbl
    Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.}

proc bytesOf(self: pointer): Bytes = cast[Bytes](stateOf(self))

let bytes = Bytes(data: @[byte 'h'.ord, 'i'.ord, '!'.ord])
GC_ref(bytes)                  # Windows holds it now; `dispose` lets go
let buffer = adopt[IBuffer](implement(
  IBufferVtbl(
    get_Capacity: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
      value[] = uint32(bytesOf(self).data.len)
      S_OK,
    get_Length: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
      value[] = uint32(bytesOf(self).data.len)
      S_OK,
    put_Length: proc(self: pointer, length: uint32): HRESULT {.abi.} =
      bytesOf(self).data.setLen(length)
      S_OK),
  IBufferByteAccessVtbl(
    Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.} =
      value[] = bytesOf(self).data[0].addr
      S_OK),
  state = cast[pointer](bytes),
  dispose = proc(state: pointer) {.nimcall, raises: [].} = GC_unref(cast[Bytes](state))))

echo CryptographicBuffer.encodeToBase64String(buffer)   # aGkh
```

Each interface's IID comes from its vtable type: `IBufferVtbl` is declared
beside `IID_IBuffer` in the ABI module, and an interface of your own is
declared the same way, as above. The methods are written at the ABI — raw
arguments, an `HRESULT` back — with `stateOf(self)` for whatever you attached
and `takeString`, `toWinRtString`, `adopt` and `borrow` to convert.
`QueryInterface`, reference counting and the rest of `IInspectable` are filled
in for you; two or three interfaces go as arguments, more as one tuple.
Windows may call your methods, and release the object, from any of its
threads: `dispose` runs on yours regardless, and a method that needs your
thread for something hands it over with `runOnDispatcher`.

### When a call fails

A failed call raises `WinRtError` carrying the `HRESULT` and the message the
runtime attached to it, which is usually the useful part:

```text
Uri.new failed: E_INVALIDARG: not a uri at all is not a valid absolute URI.
```

## Import what you use

The bindings are one module per namespace group, and each group is two modules:
`winrt/gaming` is the API, `winrt/abi/gaming` the vtable underneath it.
Importing the first gives you the second too, along with `winrt` itself and
the type declarations every module shares. A module costs what it contains:

| module | namespace | interfaces | compile cost |
| --- | --- | ---: | ---: |
| `winrt/foundation` | `Windows.Foundation.*` | 48 | +0.5s |
| `winrt/ai` | `Windows.AI.*` | 139 | +1.7s |
| `winrt/applicationmodel` | `Windows.ApplicationModel.*` | 1,010 | +8.4s |
| `winrt/data` | `Windows.Data.*` | 62 | +0.9s |
| `winrt/devices` | `Windows.Devices.*` | 1,006 | +5.7s |
| `winrt/gaming` | `Windows.Gaming.*` | 71 | +1.2s |
| `winrt/globalization` | `Windows.Globalization.*` | 63 | +0.9s |
| `winrt/graphics` | `Windows.Graphics.*` | 287 | +2.2s |
| `winrt/management` | `Windows.Management.*` | 125 | +1.6s |
| `winrt/media` | `Windows.Media.*` | 842 | +7.4s |
| `winrt/networking` | `Windows.Networking.*` | 362 | +2.8s |
| `winrt/perception` | `Windows.Perception.*` | 52 | +1.1s |
| `winrt/security` | `Windows.Security.*` | 254 | +1.8s |
| `winrt/services` | `Windows.Services.*` | 127 | +2.1s |
| `winrt/storage` | `Windows.Storage.*` | 195 | +1.7s |
| `winrt/system` | `Windows.System.*` | 280 | +2.3s |
| `winrt/ui` | `Windows.UI.*` | 3,074 | +16.5s |
| `winrt/web` | `Windows.Web.*` | 165 | +2.9s |

Compile cost is measured against a program that imports `winrt` alone, which
takes 1.8s; the figures are for one import on a 2026 laptop and are what the
bindings' declarations cost the compiler. Nothing you do not call reaches the
binary: a program that imports all eighteen comes out byte for byte the same
size as one that imports `winrt` alone.

Every module can name every type. A method in `winrt/devices` that returns a
`Windows.Storage.StorageFile` returns a `StorageFile`, and a `winrt/ui` method
that takes a `Windows.Graphics.SizeInt32` takes one.

Importing `winrt` alone gives the runtime itself — strings, GUIDs, activation,
delegates, futures — and none of the bindings.

## When you need the layer underneath

Every WinRT call is the same four steps, and this is what the generated code
compiles into:

```nim
import winrt
import winrt/abi/foundation

proc main() =
  # 1. An interface pointer, from the activation factory. `factory` is typed
  #    by its interface, so only that interface's methods can be called on it,
  #    and it is released when the scope ends.
  let factory = statics[IUriRuntimeClassFactoryVtbl]("Windows.Foundation.Uri")

  # 2. The method, as a field of the interface's vtable. Every method
  #    returns an HRESULT; the declared return is a trailing out-parameter.
  let text = toWinRtString("https://nim-lang.org")
  var uri: pointer
  check factory.vtbl.CreateUri(factory.raw, text.handle, uri.addr), "Uri.CreateUri"
  defer: release(uri)

  # 3. Narrow to the interface that declares the method you want.
  let it = queryInterface[IUriRuntimeClassVtbl](uri)

  # 4. An out HSTRING is yours to free; `takeString` converts and frees it.
  var host: HSTRING
  check it.vtbl.get_Host(it.raw, host.addr), "Uri.get_Host"
  echo takeString(host)

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
`queryInterface[XVtbl](obj)` gives you a value typed by the interface that
declares the method; use that one and not whichever pointer happens to be at
hand.

## What is and is not covered

Everything in `Windows.winmd`. Every interface that carries a GUID — 8,186 of
them, 33,724 vtable slots, 1,725 enums and 124 structs — and on top of that
every class, method, property, constructor and event: 4,495 classes, 30,003
members and 1,401 events, with nothing skipped. A shared interface's methods
are written once rather than once per implementer, which is why those counts
are lower than the number of call sites they cover. The generator still counts
and prints anything it cannot spell, because a future SDK may add a shape it
does not know; on this one the count is zero.

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

**A handler from another thread never runs, or a `waitFor` never returns.**
Handlers are delivered to the thread that created them by its dispatcher, so
that thread has to be polling: `waitFor`, `runForever` or `poll`. A thread
blocked in `sleep`, or in a synchronous call that itself waits for the handler,
delivers nothing. See *Handlers run on your thread* above.

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
