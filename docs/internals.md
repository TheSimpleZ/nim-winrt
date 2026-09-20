# How the bindings are made

This is the design of `tools/` and the shape of what it emits. You do not need
any of it to *use* the package — start at the [README](../README.md) for that.

```text
Windows.winmd ──> tools/winmd.nim ──> tools/generate.nim ──> src/winrt/abi/*.nim
 (ECMA-335)        the reader           the ABI layer          IIDs, slots, layouts
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
and fits in one module written in dependency order. `generic.nim` holds the
parameterised interfaces, `IVector<T>` and the rest, as generic vtable
objects. Beside them is one module of interfaces per namespace group,
`abi/devices` and so on, each importing `types`. An interface is a bare
`pointer` at this layer, so a module of interfaces depends on nothing but the
value types, and no group can be placed ahead of something it names.

**The API layer** is `src/winrt/`. `classes.nim` holds every wrapper type —
4,495 of them, each an object one pointer wide — and beside it one module of
members per group. Classes are mutually recursive across every namespace there
is: a `StorageFile` method returns an `IRandomAccessStream`, `Windows.UI` and
`Windows.Graphics` name each other throughout. Nim has no mutually recursive
modules, so no arrangement of self-contained modules can express that; a
wrapper type costs nothing to declare, so all of them are declared first.

A members module imports `abi/types`, `abi/generic`, the ABI groups its
methods actually call into — four to thirteen of them — and `classes`. It does
not import the other members modules, and it does not import all of the ABI:
measured, a module that imported every ABI module took 34 seconds to compile,
and one that imports the groups it uses takes four.

It also *re-exports* those ABI groups, which is not tidiness but necessity: an
IID is a constant declared beside its vtable, and the generic that reads one is
instantiated where the method is called, so a program calling
`PowerManager.batteryStatus` has to be able to see `IID_IPowerManagerStatics`.
Each is aliased on the way through — `import ./abi/system as abiSystem` —
because `winrt/abi/foundation` and `winrt/foundation` are both `foundation` to
an export list.

Splitting the members by namespace group at all is compile cost. `ui.nim` is
97,000 lines; making everyone who wants a gamepad pay for it would be absurd.
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
`XamlIFrameworkView`, `WebUISuspendingEventArgs`. `generate.settleNames` runs
before any module is written and both generators apply the same rule in the
same order, so the layers agree on every spelling. Two more pairs are a class
and an enum — `Panel`, `PackageStatus` — and those are qualified where they
appear.

Parameters are named from the metadata — `lampIndex`, `desiredColor` — and
where the metadata leaves one unnamed, its type names it:
`newQueryOptions(query: CommonFileQuery, fileTypeFilter: seq[string])`. A
value with no name of its own is `input`.

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
access: `it.vtbl.get_Host(it.raw, tmp.addr)`. `IInspectableVtbl` in `com`
contributes the six every WinRT interface begins with — `QueryInterface`,
`AddRef`, `Release`, `GetIids`, `GetRuntimeClassName`, `GetTrustLevel` — and
a delegate derives from `IUnknownVtbl`, the first three. Both bases are
`{.pure.}`, so no hidden type field disturbs the layout;
`tests/tactivation.nim` checks the offsets.

A parameterised interface is one generic object rather than one per
instantiation, its fields typed through `Abi(T)`:

```nim
const IID_IVector* = guid"913337E9-11A1-4345-A3A2-4E7F956E222D"
type IVectorVtbl*[T] = object of IInspectableVtbl
  GetAt*: proc(self: pointer, a1: uint32, value: ptr Abi(T)): HRESULT {.abi.}
  ...
```

`{.abi.}` is `stdcall, raises: [], gcsafe`, defined once in `abidef.nim` and
`include`d, because a user pragma does not cross a module boundary in Nim.
`raises: []` is what lets `Release` be called from a `=destroy` hook.

### Type mapping

| metadata | Nim | note |
| --- | --- | --- |
| `Boolean` | `bool` | one byte on the wire, matching Nim |
| `Char` | `Char16` | a UTF-16 code unit, distinct from `uint16` |
| `Int8` … `UInt64`, `Single`, `Double` | the obvious | |
| `String` | `HSTRING` | a handle, not a Nim string |
| interface, `Object`, delegate | `pointer` | see below |
| enum | a `{.pure, size: 4.}` enum | flags enums are `distinct uint32` |
| struct | a generated `object` | crosses by value, so layout must be exact |
| a struct holding a string or a reference | a `<Name>Abi` twin | see below |
| `Generic<A, B>` | `GenericVtbl[A, B]`'s pointer | an interface pointer like any other |
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

A struct is the one type both layers would otherwise share, and a field that
is an `HSTRING` at the ABI cannot be a `string` in the API — a `string` is not
the width of a handle. So the six structs that hold a string or an
`IReference<T>` are written twice. `SortEntryAbi` has a `WinRtString` and
`HttpProgressAbi` a `Reference[uint64]`, each the width of the handle it
holds, with `=copy` and `=destroy` hooks that duplicate and delete it; beside
it `SortEntry` has a plain `string` and `HttpProgress` an `Option[uint64]`,
and `toAbi`/`fromAbi` convert. Nobody using the library ever names the twin.
The owning hooks are what make a struct read out of Windows safe to keep and a
struct built in Nim safe to hand over: `seqview` and `mapview` copy and
destroy values through `copyValue[T]` and `destroyValue[T]` rather than by
bytes. Both hooks are COM calls and touch no GC memory, so they may run on any
thread.

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
  ## Windows.Foundation.IUriRuntimeClass.get_Host
  let it = queryInterface[IUriRuntimeClassVtbl](self)
  var ret: HSTRING
  check it.vtbl.get_Host(it.raw, ret.addr), "Uri.host"
  takeString(ret)

proc combineUri*(self: Uri, relativeUri: string): Uri =
  ## Windows.Foundation.IUriRuntimeClass.CombineUri
  let it = queryInterface[IUriRuntimeClassVtbl](self)
  let a0 = toWinRtString(relativeUri)
  var ret: pointer
  check it.vtbl.CombineUri(it.raw, a0.handle, ret.addr), "Uri.combineUri"
  adopt[Uri](ret)
```

`queryInterface[V]` narrows the object to the interface that declares the
method and hands back an `Interface[V]` — the pointer, released when the
scope ends, with `it.vtbl` typed so that only that interface's methods can be
reached through it. There are no templates in a generated body and no
`with`-blocks: every line is an ordinary call, and the conversions are named
outright — `takeString`, `adopt`, `takeSeq`, `takeTable`, `takeReference`,
`fromAbi` — rather than left to one dispatcher, so the line says what happens.

**Every call re-queries.** Each wrapper QueryInterfaces the receiver before
dispatching. That is not free, but it makes the worst bug in this codebase
unrepresentable — reaching a slot through the wrong interface is a silent
wrong function, not an error.

**Object inheritance, not `distinct pointer` plus converters.** Converters
were the obvious first attempt and are unusable at this scale: Nim weighs every
converter in scope at every type mismatch, and 1,715 of them took one module
from 3.6 seconds to over seven minutes to compile. Nim's own object subtyping
costs nothing at compile time and leaves each wrapper exactly one pointer wide.
Every class derives from `WinRtObject` in `objects`, which carries the one
`=destroy`, `=copy` and `=sink` for the whole projection; a derived value
passes where a base is expected, and an inherited method resolves without
being emitted again for every subclass.

**A shared interface's methods are written once.** An interface that only one
class implements is written on that class, with `self: Uri`. One that several
implement gets a type class named with Nim's own convention —
`SomeInputStream = IInputStream | IRandomAccessStream | StorageFile | ...`,
every class that lists it, every interface that requires it, and the interface
itself — and its methods are written once over that. This is why the member
count here is lower than the number of call sites it covers.

### Where an IID comes from

An interface's IID is a constant beside its vtable, and a class's metadata name
and default interface are constants in `classes.nim`. Generic code reaches them
through four macros in `com.nim` — `iid(T)`, `className(T)`, `defaultIid(T)`,
`runtimeName(T)` — each of which turns a type into the name of its constant:
`iid(IUriRuntimeClassVtbl)` is `IID_IUriRuntimeClass`, and so is
`iid(IUriRuntimeClass)`, because the API's object for an interface and the
ABI's vtable for it differ only by the suffix.

These are the only macros in the library, and they are macros because the
alternatives were measured. A proc overload per interface is eight thousand
overloads of one name and costs five seconds of compile time in every program
that imports anything. A sorted table searched in the compiler's VM costs ten
milliseconds per lookup, because the VM copies the table each time — 66
seconds to compile `winrt/ui` alone. Reading a constant costs nothing.

An instantiation of a parameterised interface has no declared IID, so
`iid(IVectorVtbl[Uri])` expands instead to a `const` that hashes the
instantiation's signature (below) once per instantiation, in the compiler.

### What crosses, and how

| WinRT | Nim | how |
| --- | --- | --- |
| a runtime class | its wrapper type | adopted on the way out, narrowed on the way in |
| an interface with no class, `Object` | `WinRtObject` | the same, untyped |
| `String` | `string` | `takeString` out, `toWinRtString` in |
| an enum, a struct, a number | itself | by value |
| a struct holding a string or a reference | itself, with `string` and `Option` | `fromAbi` out, `toAbi` in |
| `T[]` | `openArray[T]` in, `seq[T]` out | values pointed at where they lie; strings and objects marshalled |
| `IVectorView<T>`, `IIterable<T>`, `IVector<T>` | `seq[T]` | read with `takeSeq`; passed as a `seqview` object |
| `IMapView<K, V>`, `IMap<K, V>`, `IIterable<IKeyValuePair<K, V>>` | `Table[K, V]` | read with `takeTable`; passed as a `mapview` object |
| `IReference<T>` | `Option[T]` | read with `takeReference`; passed boxed through `PropertyValue`, or by an object of our own where it cannot box |
| `IAsyncAction`, `IAsyncOperation<T>` and their `WithProgress` pairs | `Future[T]` | `asyncops` |
| a delegate | a closure in, an object with `invoke` out | `delegate.nim` |
| an event | `on<Name>(handler)` and `remove<Name>(token)` | typed sender and arguments |
| `[out]` parameters | the result, or a tuple | one out-parameter is the result; several are a tuple, with `value` or `ok` for the declared return |

Collections and maps nest — `Table[string, seq[string]]`, `seq[seq[Point]]`,
`seq[Table[string, WinRtObject]]` — because the conversions are generic over
the metadata type and recurse through it.

A collection or map handed *to* the runtime is a copy. A callee that inserts
into it changes its copy, which is what every projection does — C++/WinRT
hands over a `single_threaded_vector` the caller no longer holds — and the
alternative, writing back into the caller's `seq` after the call, would have
to guess when the callee is finished with it.

### Two types on the plumbing, and why

The conversions are generic over the metadata type *and* over the Nim type
they produce, which the generated call spells out:

```nim
takeSeq[IVectorVtbl[SortEntry], seq[SortEntry]](ret)
```

The second is redundant to a reader — it is the proc's return type — and it is
there because of a Nim rule with teeth. A generic whose *signature* expands a
template, as `takeSeq[M](p: pointer): Api(M)` would, reports an injected
symbol wherever it is instantiated; and a method taking a `Some...` type class
is itself generic, so it is instantiated in the *calling program*, which is
where that note would appear. Writing both types keeps every signature
template-free, and `Api(M)` and `Abi(T)` are still used freely inside the
bodies, where nothing is reported.

### Parameterised IIDs

`IVector<Something>` has no GUID in any metadata file. WinRT derives one: build
a *signature string* describing the instantiation, then take a version-5 UUID
of it under the fixed namespace `{11f47ad5-7b73-42c0-abae-878b1e16adee}`.
Every projection does exactly this, and it is the only way to `QueryInterface`
for a generic at all.

`src/winrt/signatures.nim` does it in Nim that the compiler's VM can run — a
plain SHA-1 and `uuid5` — so `iid(IVectorVtbl[Uri])` is a constant in the
binary and nothing is hashed at run time. The generator does the same thing in
`tools/piid.nim` for the one case it must settle itself: a class whose default
interface is an instantiation, `DeviceInformationCollection` being an
`IVectorView<DeviceInformation>`, whose `DefaultIid_` constant it writes out.

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
needs the class-to-interface map and not just names — hence `className(T)` and
`defaultIid(T)` beside `runtimeName(T)`.

Getting it wrong is silent. A mistyped signature yields a well-formed GUID that
no object implements, so `QueryInterface` answers `E_NOINTERFACE` and the call
site looks like an unsupported feature rather than a wrong hash. The only real
check is against a live object, which is what the tests do: `tests/tapi.nim`
reads collections, maps and references through computed IIDs, and a wrong one
would fail there.

## Starting the runtime

`RoInitialize` has to have been called on a thread before that thread can
activate anything, and the old shape of this library made every program say so
first. It no longer does: `ensureRuntime()` runs at the top of
`activationFactory` and `activate`, guarded by a `threadvar`, so the first call
a thread makes brings the runtime up multithreaded. A UI framework calls
`initRuntime(singleThreaded)` before its first call and gets the other model;
a thread the host already initialised answers `RPC_E_CHANGED_MODE`, which is
not treated as a failure.

The two values are `RoInitialize`'s own — `singleThreaded = 0`,
`multiThreaded = 1` — and `ThreadingModel` is declared in that order for the
reason that inverting them costs an afternoon: with the model reversed,
everything still activates, and only a thread-pool callback that never arrives
says anything is wrong.

## Async

An `IAsyncOperation<T>` becomes a `Future[T]`, completed by the operation's
own completion handler. Two details are in `asyncops.nim`: the handler object
answers `QueryInterface` for `IAgileObject`, so WinRT invokes it on the
completing thread instead of marshalling back to a thread that is blocked in
`waitFor`; and all it does there is signal an `AsyncEvent`, because
`asyncdispatch` is single-threaded and completing a `Future` from a thread pool
thread would be a data race.

The `WithProgress` variants declare `put_Progress` and `get_Progress` first,
which pushes `put_Completed` and `GetResults` two slots down and completes
through a different parameterised delegate. The four operation interfaces are
told apart by `when` inside `ResultOf`, `CompletedHandler` and
`ProgressHandler`, so one `future` covers all of them.

A wrapper is not itself `{.async.}`: it starts the operation and returns the
Future that `future[AsyncOp, R](op, what)` builds for it. That Future is the
one the caller holds, which is what lets `cancel(fut)` find the operation
behind it in a list of those still running and call `IAsyncInfo.Cancel`; the
completion callback drops the entry, and a cancelled operation fails its
Future with a `CancelledError`. For a `WithProgress` operation the wrapper
takes a `progress` closure as its last parameter and hands `put_Progress` an
ordinary delegate around it.

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
ABI's shape around the one the caller wrote, converting each argument, and
`newDelegate(WorkItemHandlerVtbl, shim)` names the delegate by its vtable type,
which is where its IID is read from.

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
`mapview` and `values` each do by hand: an object on the COM heap with
`QueryInterface`, an atomic reference count and the rest of `IInspectable`
filled in, and each interface's own methods supplied by the caller as
`{.abi.}` procs in a copy of the generated `XVtbl`. The IID of each comes from
the vtable type — `iid(typeof(table))` — so an interface of your own is
declared the way the generated ABI declares one, the IID beside the vtable.
The vtables are copied per object rather than shared per type because two
objects of one interface may carry different methods.

An object may implement several interfaces, and a COM interface pointer has
to point at a vtable pointer, so the object holds one *slot* per interface:
the vtable pointer COM reads, followed by a pointer back to the object's
header, the interface's IID and whether it derives from `IInspectable`. An
interface pointer is the address of its slot; `stateOf(self)` reads the
header through whichever slot `self` is, which is why a method of any
interface reaches the same state. `QueryInterface` answers `IUnknown` and
`IAgileObject` with the first slot, `IInspectable` with the first slot that
is one — an object of COM-only interfaces such as `IBufferByteAccess` is not
an `IInspectable` — and each IID with its own; `GetIids` lists the
inspectable ones. The slots are sized from the tuple of vtables `implement`
was given, so the object is one allocation.

A method may be called on any thread, and there is no dispatcher in between
as there is for a delegate, because a method has to answer before it
returns. The release that frees the object may come from any thread too, so
the state is disposed of through `runOnDispatcher`: run at once when the
releasing thread is the dispatcher's, otherwise posted as a job it does not
wait for — the same pending list a delegate invocation travels, minus the
event — since waiting could deadlock a dispatcher that is itself blocked on
the runtime thread doing the releasing.

## Failures

A WinRT method that fails usually says why: it calls `RoOriginateError` with
a message before returning, and the runtime keeps that message on the calling
thread until someone asks. `check` asks, once, right after the call that
failed, through `GetRestrictedErrorInfo` and `IRestrictedErrorInfo`; the
message is taken only if it was attached to the same HRESULT, since a stale
one would describe an earlier failure. When there is none, `FormatMessage`
supplies the system's description of the code. Either way the exception reads
`Uri.new failed: E_INVALIDARG: <what Windows said>`.

## What is left

Nothing in `Windows.winmd` is skipped: 4,495 classes, 30,003 members,
1,401 events, and 33,724 vtable slots all of which are typed. The generator
still counts anything it cannot spell, because a future SDK may add a shape it
does not know, and prints the reason beside the count of each module it
wrote.
