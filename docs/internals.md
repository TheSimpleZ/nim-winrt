# How the bindings are made

This is the design of `tools/` and the shape of what it emits. You do not need
any of it to *use* the package — start at the [README](../README.md) for that.

```
Windows.winmd ──> tools/winmd.nim ──> tools/generate.nim ──> src/winrt/*.nim
 (ECMA-335)        the reader           the ABI emitter        checked in
                        │
                        └──────────────> tools/wrappers.nim ──> a friendly API
                                          (used by nim-winui3)
```

Three properties are worth stating up front, because most of the design
follows from them:

* **The output is checked in.** Nobody installing this package runs a
  generator or needs the Windows SDK. The generator is a maintenance tool that
  runs when the SDK moves.
* **Nothing is guessed.** A signature whose shape cannot be spelled in Nim is
  emitted as a slot number with no `Fn_` type. Emitting a *wrong* ABI type
  would be worse than emitting none: it would not fail, it would corrupt.
* **Determinism.** Regenerating against the same metadata produces byte-
  identical files, so the diff after a regeneration is exactly what the new SDK
  changed and can actually be read.

## Reading a `.winmd`

`tools/winmd.nim` is a small ECMA-335 reader — about 700 lines, no
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

Two lookups are memoised on the `WinMd` object because the naive version is
quadratic: the full-name-to-row index, and the `Constant` table keyed by field
(which is how enum values are found — an enum's fields are its members, and
the compiler-generated `value__` is the one field with no constant).

## What a binding looks like

For every interface and delegate carrying a `GuidAttribute`, `generate.nim`
emits an IID, and per method a slot constant and a signature type:

```nim
const IID_IUriRuntimeClass* = GUID(
    data1: 0x9E365E57'u32, data2: 0x48B2'u16, data3: 0x4160'u16,
    data4: [0x95'u8, 0x6F, 0xC7, 0x38, 0x51, 0x20, 0xBB, 0xFC])
const Slot_IUriRuntimeClass_get_Host* = 11
type Fn_IUriRuntimeClass_get_Host* = proc(self: pointer,
                                          value: ptr HSTRING): HRESULT {.stdcall.}
```

Slot numbering starts at 6 for an interface — `IInspectable` contributes
`QueryInterface`, `AddRef`, `Release`, `GetIids`, `GetRuntimeClassName`,
`GetTrustLevel` — and at 3 for a delegate, which derives from `IUnknown` and
so has no `IInspectable` methods. Getting that constant wrong would shift every
slot in the file, which is why it is derived from `isDelegate` rather than
assumed.

### Type mapping

| metadata | Nim | note |
| --- | --- | --- |
| `Boolean` | `bool` | one byte on the wire, matching Nim |
| `Char` | `uint16` | UTF-16 code unit |
| `Int8` … `UInt64`, `Single`, `Double` | the obvious | |
| `String` | `HSTRING` | a handle, not a Nim string |
| interface, `Object` | `pointer` | see below |
| enum | `int32` | every WinRT enum is 32 bits on the wire |
| struct | a generated `object` | crosses by value, so layout must be exact |
| `Generic<A, B>` | `pointer` | an interface pointer like any other |
| `T[]` | *unmapped* | |
| `ByRef T` | `ptr T` | |

**Interfaces are bare pointers.** At the ABI every WinRT interface *is* an
`IInspectable`, so one pointer type serves for all of them and the IID is what
tells them apart at runtime. This is the single decision with the widest
consequences: it costs type safety at the call site, and it buys the module
split below, because only enums and structs then create dependencies between
namespaces. As partial compensation, a parameter is named after the interface
it expects — `a1UIElement`, not `a1` — so the call site says what it wants.

**Structs cross by value.** Nim emits them as plain C structs, so the C
compiler applies the same x64 calling convention that Windows' own C++ was
built with: small ones in registers, larger ones behind a hidden pointer, none
of it spelled out here. That only works if the layout is right, which is why
a struct the generator cannot lay out leaves every signature mentioning it
untyped instead.

### Every method returns HRESULT

The *declared* return type becomes a trailing out-parameter. `get_Host() ->
HSTRING` is `proc(self: pointer, value: ptr HSTRING): HRESULT`. Getting this
backwards is silent memory corruption, so it is applied in one place rather
than at 33,719 call sites.

### Naming

Nim compares identifiers with underscores removed and every character after
the first folded to lower case. `Windows.UI.Text.ITextRange` declares both
`get_Text` and `GetText`, and prefixed with `Slot_` those are *one identifier*
to the compiler. A table keyed on the raw spelling sees no clash and emits a
redefinition, so `nimgen.nimIdent` computes the key Nim itself would use, and
a genuine collision gets a numeric suffix (`Slot_ICalendar_MonthAsString2`).
The winner is whichever comes first in the metadata, which is stable across
regenerations.

`tools/nimgen.nim` holds that rule and the rest of the naming — keyword
escaping, `.`-stripping, the PascalCase-to-camelCase decision for struct
fields — so the two generators cannot answer them differently.

## The module split

342 namespaces would be 342 files for no gain: a WinRT namespace is a naming
convention, not a unit anyone imports. The split is by the *second* segment —
`Windows.Devices.Enumeration.Pnp` lands in `winrt/devices` — which gives 18
modules that line up with how the documentation is organised.

The point of splitting at all is compile cost. `ui.nim` is 3.3 MB and 12,390
slots; making everyone who wants a gamepad pay for it would be absurd.
Measured against `import winrt`: `gaming` +0.03s, `devices` +0.3s, `ui` +1.9s,
everything +2.0s. Binary size is unaffected either way — these are
declarations, and Nim emits nothing for the ones you do not call.

### Ordering

A module can only name a type an *earlier* module defined, so `groupPlan`
topologically sorts the groups on the edges "group A's signatures mention
group B's enums or structs". Interfaces are exempt, being bare pointers — that
is what keeps the graph sparse enough to sort at all.

`Windows.Foundation` is pinned first: it holds `TimeSpan`,
`EventRegistrationToken` and everything hoisted, and nearly every edge points
at it. The rest is Kahn's algorithm, alphabetical on ties so the layout is
reproducible.

The graph is not quite a DAG — `Windows.Graphics` and `Windows.UI` name each
other's types, among others — so cycles have to be cut. When nothing is
unblocked, the group that *owes* the least in total goes next and all its
outstanding edges are dropped at once. Cutting the single cheapest edge is the
obvious move and the wrong one: it unblocks nobody, so the next pass finds
another cycle and cuts again. On the current SDK the cost is 14 placements
ahead of something they reference and 128 signatures going out untyped, and
the generator prints it rather than swallowing it.

### Hoisting

Four types are written into `foundation` even though they belong elsewhere:

```nim
const hoisted = [
  "Windows.UI.Color",
  "Windows.UI.Text.FontWeight",
  "Windows.UI.Core.CorePhysicalKeyStatus",
  "Windows.UI.Xaml.Interop.TypeName",
]
```

`Windows.UI.Color` is the case this exists for: four bytes that anything visual
passes around, sitting in the module that is a third of the package. Pulling it
forward costs five lines and saves everyone else importing `ui`. The
edge-weighting in `groupPlan` is adjusted to match, or it would invent
dependencies on `Windows.UI` that the output does not have — and the struct
queue skips a type an earlier module already wrote, or `ui` would declare its
own second `Color` and the two would be incompatible Nim types with the same
name.

### Structs that are not in the metadata

`tools/foreign.nim` carries layouts for types a winmd *references* but does not
define — mostly relevant when generating against a partial winmd such as
`Microsoft.UI.Xaml.winmd`, where `Point` and `Rect` live elsewhere. These are
ABI contracts fixed since Windows 8 and published in the SDK headers, and a
wrong field type fails loudly and immediately, unlike a wrong GUID.

When a struct is present in the metadata *and* in the foreign table, the file
on disk wins. Both sources go through one queue, because the dependency edges
run both ways — a foreign `ManipulationDelta` holds a `Point` the metadata may
define, and an in-namespace `Duration` holds a `TimeSpan` it may not — so the
queue emits whatever is fully resolvable and goes round again until a pass adds
nothing.

## Parameterised IIDs

`IVector<Something>` has no GUID in any metadata file. WinRT derives one: build
a *signature string* describing the instantiation, then take a version-5 UUID
of it under the fixed namespace `{11f47ad5-7b73-42c0-abae-878b1e16adee}`.
Every projection does exactly this, and it is the only way to `QueryInterface`
for a generic at all. `tools/piid.nim` implements it.

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
needs the class-to-interface map and not just names. Instantiations nest:
`IAsyncOperation<IVectorView<GameListEntry>>` is a `pinterface` whose argument
is another `pinterface`.

Getting it wrong is silent. A mistyped signature yields a well-formed GUID that
no object implements, so `QueryInterface` answers `E_NOINTERFACE` and the call
site looks like an unsupported feature rather than a wrong hash. The only real
check is against a live object — which is what `tools/piidcheck.nim` exists to
set up: it prints every instantiation the metadata uses together with the
signature string it was built from, the part a person can verify by eye.

The ABI layer does not yet emit these constants; `tools/wrappers.nim` does, for
the events it generates.

## Calling back: delegates

`src/winrt/delegate.nim` is the other direction — objects the runtime invokes.
Three details are fatal to get wrong:

* **A WinRT delegate derives from `IUnknown`, not `IInspectable`.** Its vtable
  is four slots: QueryInterface, AddRef, Release, Invoke. Assuming the usual
  six puts `Invoke` at slot 6 and calls into whatever follows the table.
* **The vtable pointer must be the first field**, because the caller receives a
  pointer to the object and immediately dereferences it as a pointer to a
  pointer to the table.
* **An event handler must not report failure.** XAML treats a failing HRESULT
  out of its own event dispatch as fatal and tears the process down, so one
  bug in one handler would end the application with nothing in the log. The
  exception is caught, reported to stderr (flushed, because stderr is block-
  buffered once redirected and the message would otherwise die with the
  process), and `S_OK` returned. A one-argument lifecycle callback *does*
  report failure, because there the caller can still do something about it.

`Invoke` comes in two shapes — one argument, or a sender plus arguments — and
those are different vtable layouts. On x64 the extra argument rides in a
register, so calling through the wrong shape happens to survive, which is worse
than failing. There are therefore two trampolines and two vtables, and
everything else is shared: handlers are normalised to two parameters on the way
in, with the one-argument kind ignoring the second.

The closures live in a module-level `seq`, not inside the COM object. A
closure's environment is GC-managed and the COM object is not, so burying one
inside the other gives a callback into freed memory some minutes after it
starts working. A released delegate returns its index to a free list rather
than leaving a hole, which is what stops a program that re-subscribes on every
device change from growing one dead slot per subscription.
`delegateTableSizes()` exposes both numbers, and `tests/tdelegate.nim` asserts
the recycling actually happens.

## The wrapper generator

`tools/wrappers.nim` emits an idiomatic API on top of the ABI layer —
`window.title = "Hi"` instead of a QueryInterface, a slot index and a manually
released HSTRING. It is not used to build this package; it is here because
[nim-winui3](https://github.com/TheSimpleZ/nim-winui3) builds it from
`../nim-winrt/tools` and runs it over the XAML metadata.

Two decisions in it are worth recording:

* **Object inheritance, not `distinct pointer` plus converters.** Converters
  were the obvious first attempt and are unusable at this scale: Nim weighs
  every converter in scope at every type mismatch, and 1,715 of them took one
  module from 3.6 seconds to over seven minutes to compile. Nim's own object
  subtyping costs nothing at compile time and, with `pure` and `inheritable`,
  leaves each wrapper exactly one pointer wide.
* **Every call re-queries.** Each wrapper QueryInterfaces the receiver before
  dispatching. That is not free, but it makes the worst bug in this codebase
  unrepresentable — reaching a slot through the wrong interface is a silent
  wrong function, not an error — and UI calls happen at the speed of a person
  clicking.

## What is still missing

* **Arrays.** Almost all of the ~400 untyped slots take or return one.
* **Typed generics.** About 5,200 slots are typed only as `pointer` because
  their parameter is an `IVector<T>` or similar. Making those honest means a
  collection layer plus emitting the computed IIDs into the ABI modules.
* **Async.** `IAsyncOperation<T>` comes back as a pointer and you drive the
  completion yourself. An `await` would sit naturally on top of the delegate
  machinery that already exists.

`nimble bindings` and the diagnostics that measure all of this are documented
in [generating.md](generating.md).
