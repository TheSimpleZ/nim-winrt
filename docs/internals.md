# How the bindings are made

This is the design of `tools/` and the shape of what it emits. You do not need
any of it to *use* the package — start at the [README](../README.md) for that.

```text
Windows.winmd ──> tools/winmd.nim ──> tools/generate.nim ──> src/winrt/abi/*.nim
 (ECMA-335)        the reader           the ABI layer          IIDs, slots, signatures
                        │
                        └──────────────> tools/wrappers.nim ──> src/winrt/*.nim
                                          the API layer          classes, methods, events
```

Three properties are worth stating up front, because most of the design
follows from them:

* **The output is checked in.** Nobody installing this package runs a
  generator or needs the Windows SDK. The generator is a maintenance tool that
  runs when the SDK moves.
* **Nothing is guessed.** A signature whose shape cannot be spelled in Nim is
  left out and counted, never approximated. Emitting a *wrong* ABI type would
  be worse than emitting none: it would not fail, it would corrupt.
* **Determinism.** Regenerating against the same metadata produces
  byte-identical files, so the diff after a regeneration is exactly what the
  new SDK changed and can actually be read.

## Reading a `.winmd`

`tools/winmd.nim` is a small ECMA-335 reader — about 800 lines, no
dependencies.

A `.winmd` is a PE file containing no code. Its CLI data directory points at a
metadata root (`BSJB`), which holds a few heaps — `#Strings`, `#GUID`, `#Blob`
— and a set of tables in the `#~` stream. Types are rows in `TypeDef`, methods
in `MethodDef`, and a type's methods are the rows from its own `MethodList` up
to the next type's.

The one genuine trap is that **row widths are global**. A column indexing
another table is 2 bytes if that table has fewer than 65,536 rows and 4
otherwise, and a *coded* index — one whose low bits tag which of several
tables it points into — widens based on the largest table in its set. So every
table's row count has to be read before any row can be located, and a single
wrong width shifts every subsequent row by a few bytes: you get plausible
garbage, not an error. That is why `schema` describes all 43 tables including
ones nothing here reads, and why `colWidth` is one function rather than a rule
repeated at each call site.

Two things the reader resolves that a first version did not, both of which
turned out to matter:

* **`[out]` is a Param flag, not a signature marker.** A by-reference
  parameter is either an out-parameter or a by-reference *input*
  (`GuidHelper.Equals(ref Guid, ref Guid)`), and only the `Param` table's
  flags say which. Treating every by-reference parameter as an output turned
  a two-argument predicate into a no-argument call returning three values.
* **A `TypeSpec` is a signature.** A class implementing `IVector<Transition>`
  has a `TypeSpec` in its `InterfaceImpl` row, not a name, and it has to be
  parsed like any other signature blob to find out which instantiation it is.

## The two layers

Every WinRT type is written exactly once, and the two layers are split the
same way for the same reason.

**The ABI layer** is `src/winrt/abi/`. `types.nim` holds every enum and struct
in the metadata — value types nest but never cycle, so the whole set is a DAG
and fits in one module written in dependency order. Beside it is one module of
interfaces per namespace group, `abi/devices` and so on, each importing
`types`. An interface is a bare `pointer` at this layer, so a module of
interfaces depends on nothing but the value types, and no group can be placed
ahead of something it names.

**The API layer** is `src/winrt/`. `classes.nim` holds every wrapper type —
4,670 of them, each `object of WinRtObject`, one pointer wide — and beside it
one module of members per group. Classes are mutually recursive across every
namespace there is: a `StorageFile` method returns an `IRandomAccessStream`,
`Windows.UI` and `Windows.Graphics` name each other throughout. Nim has no
mutually recursive modules, so no arrangement of self-contained modules can
express that; a wrapper type costs nothing to declare, so all of them are
declared first.

A members module imports `abi/types`, the ABI groups its methods actually call
into — four to thirteen of them — and `classes`. It does not import the other
members modules, and it does not import all of the ABI: measured, a module that
imported all nineteen ABI modules took 34 seconds to compile, and one that
imports the groups it uses takes four.

Splitting the members by namespace group at all is compile cost. `ui.nim` is
95,000 lines; making everyone who wants a gamepad pay for it would be absurd.
The split is by the *second* segment — `Windows.Devices.Enumeration.Pnp` lands
in `winrt/devices` — which gives 18 modules that line up with how the
documentation is organised. Binary size is unaffected either way: these are
declarations, and Nim emits nothing for the ones you do not call.

### Names

Nim compares identifiers with underscores removed and every character after
the first folded to lower case, so two overloads of one method are one field
name to the compiler. `nimgen.nimIdent` computes the key Nim itself would use,
and a genuine collision gets a numeric suffix (`MonthAsString2`); both
generators key the same way, or the API layer would name a field the ABI did
not write. `get_Text` beside `GetText` is *not* a collision — the first
character is case-sensitive — and gets no suffix.

With every type of a kind in one module, two types sharing a short name is a
collision rather than two modules' private business. It happens nine times in
the whole of `Windows.winmd` — `AnimationDirection` is a composition easing
and a XAML slide, `IFrameworkView` an app-model interface and a XAML one,
the XAML lifecycle handlers all have a WebUI twin — and the second is written
under its namespace's last segment: `PrimitivesAnimationDirection`,
`XamlIFrameworkView`, `WebUISuspendingEventArgs`. Both generators apply the
same rule so the layers agree on the spelling. Two more pairs are a class and
an enum — `Panel`, `PackageStatus` — and those are qualified where they appear.

## What the ABI layer emits

For every interface and delegate carrying a `GuidAttribute`, an IID and a
vtable: an object whose fields are the methods, in declaration order.

```nim
## Windows.Foundation.IUriRuntimeClass
const IID_IUriRuntimeClass* = guid"9E365E57-48B2-4160-956F-C7385120BBFC"
type IUriRuntimeClassVtbl* = object of IInspectableVtbl
  get_AbsoluteUri*: proc(self: pointer, value: ptr HSTRING): HRESULT {.abi.}
  get_DisplayUri*: proc(self: pointer, value: ptr HSTRING): HRESULT {.abi.}
  ...
```

This is how the C headers and C++/WinRT spell a COM interface, and how winim
spells one. A field's position *is* its vtable slot, so there is no slot
number to keep in step with a signature, and a call is a type-checked field
access: `it.vtbl.get_Host(it, tmp.addr)`. `IInspectableVtbl` in `core`
contributes the six every WinRT interface begins with — `QueryInterface`,
`AddRef`, `Release`, `GetIids`, `GetRuntimeClassName`, `GetTrustLevel` — and
a delegate derives from `IUnknownVtbl`, the first three. Both bases are
`{.pure.}`, so no hidden type field disturbs the layout;
`tests/tactivation.nim` checks the offsets.

A method whose signature cannot be spelled — there are 35, all methods of the
open generics like `IVector<T>.GetAt(T)` — is a `pointer` field, so the
methods after it still line up.

`{.abi.}` is `stdcall, raises: [], gcsafe`, defined once in `abidef.nim` and
`include`d, because a user pragma does not cross a module boundary in Nim.
`raises: []` is what lets `Release` be called from a `=destroy` hook.

### Type mapping

| metadata | Nim | note |
| --- | --- | --- |
| `Boolean` | `bool` | one byte on the wire, matching Nim |
| `Char` | `uint16` | UTF-16 code unit |
| `Int8` … `UInt64`, `Single`, `Double` | the obvious | |
| `String` | `HSTRING` | a handle, not a Nim string |
| interface, `Object`, delegate | `pointer` | see below |
| enum | a `{.pure, size: 4.}` enum | flags enums are `distinct uint32` |
| struct | a generated `object` | crosses by value, so layout must be exact |
| `Generic<A, B>` | `pointer` | an interface pointer like any other |
| `T[]` in | `size: uint32, data: ptr T` | a pass or fill array |
| `T[]` out | `size: ptr uint32, data: ptr ptr T` | a receive array: the callee allocates |
| `ByRef T` | `ptr T` | |

**Interfaces are bare pointers.** At the ABI every WinRT interface *is* an
`IInspectable`, so one pointer type serves for all of them and the IID is what
tells them apart at runtime. This is what lets a module of interfaces depend on
nothing but the value types. As partial compensation, a parameter is named
after the interface it expects — `a1UIElement`, not `a1` — so the signature
says what it wants.

**Structs cross by value.** Nim emits them as plain C structs, so the C
compiler applies the same x64 calling convention that Windows' own C++ was
built with: small ones in registers, larger ones behind a hidden pointer, none
of it spelled out here.

**Every method returns HRESULT.** The *declared* return type becomes a
trailing out-parameter. `get_Host() -> HSTRING` is
`proc(self: pointer, value: ptr HSTRING): HRESULT`. Getting this backwards is
silent memory corruption, so it is applied in one place rather than at 33,724
call sites.

**Enums are real Nim enums** where they can be. `{.size: 4.}` pins the
representation to the int32 on the wire and `{.pure.}` keeps `None`, `All` and
`Unknown` — which appear in dozens of unrelated enums — behind the type name.
An enum marked `[Flags]` holds combinations, which no Nim enum can, so those
are `distinct uint32` with the bitwise operators; the WinRT type system says a
flags enum's underlying type is `UInt32`, and `ContactQuerySearchFields.All`
is `0xFFFFFFFF`, which as an `int32` reads back as -1.

## What the API layer emits

A property is one line, and any other method is the same three whatever it
does:

```nim
proc host*(self: Uri): string =
  ## Windows.Foundation.Uri.get_Host
  withIface(self.p, IUriRuntimeClass, it):
    result = it.getString(get_Host)

proc combineUri*(self: Uri, relativeUri: string): Uri =
  ## Windows.Foundation.Uri.CombineUri
  withIface(self.p, IUriRuntimeClass, it):
    withHString(relativeUri, h0):
      var tmp: pointer
      check it.vtbl.CombineUri(it, h0, tmp.addr), "Uri.CombineUri"
      result = adopt[Uri](tmp)
```

`withIface` narrows the object to the interface that declares the method,
binds `it` as a `ptr Iface[IUriRuntimeClassVtbl]` — so only that interface's
methods can be called on it — and releases it afterwards. It takes the
interface's plain name and builds `IID_IUriRuntimeClass` and
`IUriRuntimeClassVtbl` from it. `getString`, `getValue`, `getObject`,
`putString` and `putValue` in `core` are the five shapes a property takes;
everything else is a field call and a `check`.

**Every call re-queries.** Each wrapper QueryInterfaces the receiver before
dispatching. That is not free, but it makes the worst bug in this codebase
unrepresentable — reaching a slot through the wrong interface is a silent
wrong function, not an error.

**Object inheritance, not `distinct pointer` plus converters.** Converters
were the obvious first attempt and are unusable at this scale: Nim weighs every
converter in scope at every type mismatch, and 1,715 of them took one module
from 3.6 seconds to over seven minutes to compile. Nim's own object subtyping
costs nothing at compile time and leaves each wrapper exactly one pointer wide.
Every class derives from `WinRtObject` in `core`, which carries the one
`=destroy`, `=copy` and `=sink` for the whole projection; a derived value
passes where a base is expected, and an inherited method resolves without
being emitted again for every subclass.

### What crosses, and how

| WinRT | Nim | how |
| --- | --- | --- |
| a runtime class | its wrapper type | adopted on the way out, narrowed on the way in |
| an interface with no class, `Object` | `WinRtObject` | the same, untyped |
| `String` | `string` | `takeString` out, `withHString` in |
| an enum, a struct, a number | itself | by value |
| `T[]` | `openArray[T]` in, `seq[T]` out | values pointed at where they lie; strings and objects marshalled |
| `IVectorView<T>`, `IIterable<T>`, `IVector<T>` | `seq[T]` | read with `toSeq`; passed as a `seqview` object |
| `IMapView<K, V>`, `IMap<K, V>`, `IIterable<IKeyValuePair<K, V>>` | `Table[K, V]` | read with `toTable`; passed as a `mapview` object |
| `IReference<T>` | `Option[T]` | read with `readReference`; passed boxed through `PropertyValue`, or `reference.nim` where it cannot box |
| `IAsyncAction`, `IAsyncOperation<T>` and their `WithProgress` pairs | `Future[T]` | `asyncops` |
| a delegate | a closure in, an object with `invoke` out | `delegate.nim` |
| an event | `on<Name>(handler: EventHandler[S, A])` and `remove<Name>(token)` | typed sender and arguments |
| `[out]` parameters | a tuple | beside the declared return |

Collections and maps nest — `Table[string, seq[string]]`, `seq[seq[Point]]`,
`seq[Table[string, WinRtObject]]` — because `toSeq` and `toTable` decide the
element's shape from its Nim type and recurse.

A collection or map handed *to* the runtime is a copy. A callee that inserts
into it changes its copy, which is what every projection does — C++/WinRT
hands over a `single_threaded_vector` the caller no longer holds — and the
alternative, writing back into the caller's `seq` after the call, would have
to guess when the callee is finished with it.

### Parameterised IIDs

`IVector<Something>` has no GUID in any metadata file. WinRT derives one: build
a *signature string* describing the instantiation, then take a version-5 UUID
of it under the fixed namespace `{11f47ad5-7b73-42c0-abae-878b1e16adee}`.
Every projection does exactly this, and it is the only way to `QueryInterface`
for a generic at all. `tools/piid.nim` implements it, and the API generator
emits the results as constants at the top of each module.

Each type has a spelling given in the Windows Runtime ABI documentation:

| | |
| --- | --- |
| `Int32`, `UInt32`, `Boolean` | `i4`, `u4`, `b1` |
| `String`, `Guid` | `string`, `g16` |
| `Object` | `cinterface(IInspectable)` |
| an interface | `{iid}` |
| a delegate | `delegate({iid})` |
| an enum | `enum(Name;i4)`, or `u4` if it is a flags enum |
| a struct | `struct(Name;field;field;…)` |
| a runtime class | `rc(Name;defaultInterfaceSignature)` |
| a parameterised interface | `pinterface({generic-iid};arg;arg;…)` |

A runtime class is described by its *default* interface, which is why this
needs the class-to-interface map and not just names — and for a class whose
default interface is itself parameterised, `DeviceInformationCollection`
being an `IVectorView<DeviceInformation>`, that interface's own signature.

Getting it wrong is silent. A mistyped signature yields a well-formed GUID that
no object implements, so `QueryInterface` answers `E_NOINTERFACE` and the call
site looks like an unsupported feature rather than a wrong hash. The only real
check is against a live object, which is what the tests do: `tests/tapi.nim`
reads collections, maps and references through computed IIDs, and a wrong one
would fail there.

### Async

An `IAsyncOperation<T>` becomes a `Future[T]`, completed by the operation's
own completion handler. Two details are in `asyncops.nim`: the handler object
answers `QueryInterface` for `IAgileObject`, so WinRT invokes it on the
completing thread instead of marshalling back to a single-threaded apartment
that is blocked in `waitFor`; and all it does there is signal an `AsyncEvent`,
because `asyncdispatch` is single-threaded and completing a `Future` from a
thread pool thread would be a data race.

The `WithProgress` variants declare `put_Progress` and `get_Progress` first,
which pushes `put_Completed` and `GetResults` two slots down and completes
through a different parameterised delegate. `AsyncLayout` says which, and the
generator decides it from the operation's name.

## Calling back: delegates

`src/winrt/delegate.nim` is the other direction — objects the runtime invokes.
Three details are fatal to get wrong:

* **A WinRT delegate derives from `IUnknown`, not `IInspectable`.** Its vtable
  is four slots: QueryInterface, AddRef, Release, Invoke.
* **The vtable pointer must be the first field**, because the caller receives a
  pointer to the object and immediately dereferences it as a pointer to a
  pointer to the table.
* **An event handler must not report failure.** XAML treats a failing HRESULT
  out of its own event dispatch as fatal and tears the process down. A
  handler that raises is reported to stderr either way; only a *callback's*
  failure — a work item, the application's initialization — is reported to the
  runtime, because there the caller can still do something about it.

`Invoke` takes whatever the delegate declares — nothing, an object, a sender
and arguments, a `SignalNotifier` and a `bool` — and each is a different C
signature. The trampoline is generic over the argument types and instantiated
per delegate signature, its vtable with it: `{.global.}` inside a generic proc
is one table per instantiation. The generated wrapper builds a closure of the
ABI's shape around the one the caller wrote, converting each argument.

### The thread it arrives on

The runtime invokes a delegate on whatever thread suits it, and that thread is
not a Nim thread. Under ORC two things are then out: copying a `ref` — the
cycle-root list it registers into is per thread and uninitialised on one Nim
did not start — and allocating, for the same reason one level down in the
allocator. Both were found by probe; both segfault.

So every COM object this library implements — a delegate, a collection handed
to the runtime, a boxed value, a completion handler — lives on the COM heap
(`comAlloc`, over `CoTaskMemAlloc`), and the path from `Invoke` to the closure
holds no `ref` and allocates nothing: the delegate carries the closure's
*address*, reads it through a `ptr` and calls it through a `{.cursor.}`. The
closure itself is kept alive by a table on the main thread. A delegate
released on a foreign thread is only *retired* — pushed onto a lock-free list
threaded through the objects themselves — and the table lets go of its closure
the next time it is touched from the main thread. `delegateTableSizes()`
exposes the table, and `tests/tdelegate.nim` asserts released slots are
reused.

The handler itself is not asked to obey that rule. When `Invoke` arrives on a
thread other than the one that created the delegate, the trampoline describes
the call in a `Job` on its own stack — the typed arguments and a proc that
knows how to make the call — pushes it onto a lock-free list, triggers an
`AsyncEvent` and blocks on a Win32 event. The dispatcher thread, woken by
`asyncdispatch`, runs the handler and signals. The handler therefore runs on
the thread that runs the dispatcher, with the runtime's thread waiting, and
may allocate freely; the cost is that the dispatcher has to be polling for a
handler from elsewhere to be delivered at all. `newDelegate(..., raw = true)`
opts out and takes on the rule: no GC memory on the runtime's thread.
`tests/tdelegate.nim` invokes a delegate from a raw Win32 thread both ways.

## Implementing an interface

`src/winrt/implement.nim` is the general form of what `delegate`, `seqview`,
`mapview` and `reference` each do by hand: an object on the COM heap whose
first field points at a vtable, with `QueryInterface`, an atomic reference
count and the rest of `IInspectable` filled in, and the interface's own
methods supplied by the caller as `{.abi.}` procs in a copy of the generated
`XVtbl`. The vtable is copied per object rather than shared per type because
two objects of one interface may carry different methods. `stateOf(self)`
returns the pointer the caller attached, which is how a method reaches its
data without a closure — a method here may be called on any thread, and there
is no dispatcher in between as there is for a delegate.

One interface per object. An object implementing several unrelated interfaces
needs a vtable pointer per interface and, in every method, the offset back to
the object — the arrangement `seqview` uses for `IIterable<T>`,
`IVectorView<T>` and `IVector<T>` on one object.

## Failures

A WinRT method that fails usually says why: it calls `RoOriginateError` with
a message before returning, and the runtime keeps that message on the calling
thread until someone asks. `check` asks, once, right after the call that
failed, through `GetRestrictedErrorInfo` and `IRestrictedErrorInfo`; the
message is taken only if it was attached to the same HRESULT, since a stale
one would describe an earlier failure. When there is none, `FormatMessage`
supplies the system's description of the code. Either way the exception reads
`Uri.CreateUri failed: E_INVALIDARG: <what Windows said>`.

## What is left

Nothing in `Windows.winmd` is skipped: 4,670 classes, 33,056 methods,
properties and constructors, 2,908 events. The generator still counts and
prints anything it cannot spell, because a future SDK may add a shape it does
not know, and `WINRT_DUMP_SKIPS=1 nimble bindings` names each method and why.

An `IAsyncOperation<T>` is a `Future[T]`, and a `Future` has no `cancel` and
no progress callback, so the `WithProgress` operations are awaited but report
nothing along the way. That is a consequence of the model chosen, not a
missing shape.
