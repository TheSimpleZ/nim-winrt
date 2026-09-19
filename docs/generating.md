# Regenerating the bindings

`src/winrt/*.nim` and `src/winrt/abi/*.nim` are generated and checked in. You
only need this page to move the package to a newer Windows SDK, or to work on
the generator itself — see [internals.md](internals.md) for how it works.

## What you need

The Windows SDK's union metadata, which the SDK installs at:

```text
C:\Program Files (x86)\Windows Kits\10\UnionMetadata\<version>\Windows.winmd
```

That single file describes every WinRT type in the SDK. Nothing else is
needed — no C++ toolchain, no vendored headers.

## Running it

```text
nimble bindings
```

This builds `tools/generate.nim` and `tools/wrappers.nim` and runs both over
`10.0.26100.0/Windows.winmd`: the ABI layer first, then the API layer over
it. Allow a minute or two. To point it somewhere else:

```text
WINMD="C:/Program Files (x86)/Windows Kits/10/UnionMetadata/10.0.22621.0/Windows.winmd" nimble bindings
```

The task refuses to run rather than half-generating if the file is not there.

It prints what it did, which is the first thing to read afterwards:

```text
  types             1725 enums  124 structs
  ai                 139 interfaces    355 slots (100% typed)
  ...
  19 modules  1725 enums  124 structs
  8186 interfaces  33724 slots  99% typed  35 unmapped

src\winrt\ai.nim
  classes    65
  procs      446  (constructors 1)
  events     6
  skipped    0
  ...
  19 modules  4670 classes  33056 procs  (923 constructors)  2908 events
  0 skipped
```

The 35 unmapped ABI slots are the methods of the open generics themselves —
`IVector<T>.GetAt(T)` — whose parameters are type variables; they are the same
35 for every SDK. Every concrete method is typed, and nothing in the API layer
is skipped. A new SDK that adds a shape the generator does not know will show
up as a non-zero `skipped` with a reason beside it, and

```text
WINRT_DUMP_SKIPS=1 nimble bindings
```

names each method and the parameter or result that stopped it.

## Checking the result

```text
nimble test
```

`tests/timports.nim` is the one that matters here: it imports all eighteen
modules into one scope, which type-checks every generated declaration and
turns a name collision between two modules into a compile error rather than a
surprise for whoever first imports both. `tests/tactivation.nim` proves a
generated IID and slot number still reach the real runtime, and `tests/tapi.nim`
exercises each shape the API layer carries — collections and maps both ways,
arrays, references, async operations, events, delegates — against live
Windows.

Then read the diff. Generation is deterministic — the same metadata produces
byte-identical files — so everything you see is something the SDK changed. Two
shapes of change are worth looking at closely:

* **A slot number moving.** This should not happen: WinRT interfaces are
  immutable once shipped, and a new version of an interface is a new interface
  (`IPowerManagerStatics2`). If a slot moves, something is wrong with the read,
  not with Windows.
* **A method disappearing from the API layer.** The generator prints why it
  skipped it. A shape it has never seen means the generator needs teaching,
  not the metadata.

Finally, `nimble examples` builds and runs the example programs against the
regenerated bindings.

## The diagnostics

These are standalone programs under `tools/`, all taking a `.winmd` path.
None of them are part of the build.

### `dump.nim` — is the reader reading it correctly?

```text
nim c -r tools/dump.nim <winmd>                       # namespaces by size
nim c -r tools/dump.nim <winmd> <TypeName> [...]      # one type's IID and slots
```

```text
$ nim c -r tools/dump.nim Windows.winmd Windows.Foundation.IUriRuntimeClassFactory
tables      20
typedefs    14672
methods     71813
with a GUID 8186

Windows.Foundation.IUriRuntimeClassFactory
  IID {44A9796F-723E-4FDF-A218-033E75B0C084}
  [6] CreateUri
  [7] CreateWithRelativeUri
```

Check those against the SDK headers when bringing up a new metadata file. Row
widths are global, so a reader that is wrong is wrong *plausibly* — this is how
you tell.

### `inspect.nim` — one type in detail

```text
nim c -r tools/inspect.nim <winmd> <TypeName>
```

Flags, base type, custom attributes and implemented interfaces, in declaration
order — which matters, because WinRT lists a runtime class's *default*
interface first. Use it when a class will not activate, or to find out which
interface actually declares the method you want.

### `piidcheck.nim` — are the computed generic IIDs right?

```text
nim c -r tools/piidcheck.nim <winmd> <namespace-prefix>
```

Every generic instantiation the metadata uses, with the signature string it
hashes to and the resulting IID:

```text
  34  Windows.Foundation.EventHandler`1<skObject>
        pinterface({9de1c535-6ae1-11e0-84e1-18a905bcc53f};cinterface(IInspectable))
        {C50898F6-C536-5F47-8583-8B2C2438A13B}
```

A wrong signature produces a well-formed GUID that no object implements, so
there is no way to tell from the IID alone — the signature string is the part
you can check by eye against the Windows Runtime ABI documentation, and a live
`QueryInterface` is the only real proof. The tests are that proof for the
shapes they read.

## Adding a struct layout

A struct the generator cannot lay out leaves every signature mentioning it
untyped. When the struct is genuinely defined in another winmd, its fields go
in `tools/foreign.nim`:

```nim
("Windows.Foundation.Point", @[("x", "float32"), ("y", "float32")]),
```

Order is load-bearing — a struct containing another must come after it — and
the source header is named in a comment beside each entry. `piid.nim` derives
the signature string from the same field list, so the layout and the IID
computation cannot drift apart.

Three sibling tables cover the cases that are not plain structs:
`foreignAliases` for types this library already spells (`System.Guid` is
`GUID`), `foreignEnums` for enums that arrive as unresolvable TypeRefs and are
therefore reported as structs, and `foreignFlagEnums` for which of those are
unsigned — a signature says `enum(Name;i4)` or `enum(Name;u4)` and getting it
wrong yields an IID that matches nothing.

## Generating for another winmd

Both generators also run in single-file mode, which is what a package
projecting another runtime — Windows App SDK, say — would use over its own
metadata:

```text
nim c -r tools/generate.nim <winmd> <prefix> <out.nim> [core-import] [provider]
nim c -r tools/wrappers.nim <winmd> <prefix> <out.nim> [core-import] [abi-import]
```

`core-import` is where the generated module finds `HSTRING` and `GUID`
(`./core` inside this package, `winrt/core` from a package depending on it).
`provider` names a module that already projects the `Windows.*` types the
winmd merely references, so they are imported rather than declared a second
time — without it an app importing both packages would have two incompatible
`Point` types.
