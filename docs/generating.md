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
  types             1725 enums  124 structs (6 with an ABI twin)
  generic             24 interfaces     64 methods
  ai                 139 interfaces    355 methods (100% typed)
  ...
  20 modules  1725 enums  124 structs
  8186 interfaces  33724 methods  100% typed  0 unmapped

  classes            4495 classes   559 interfaces  327 type classes
  ai                  343 procs    7 constructors     3 events  0 skipped
  ...
  19 modules  4495 classes  30003 procs  (1465 constructors)  1401 events  0 skipped
```

Every slot in the ABI is typed and nothing in the API layer is skipped. A new
SDK that adds a shape the generator does not know shows up as a non-zero
`unmapped` or `skipped`, and the count is followed by a line naming what
stopped it, per module:

```text
  media              3103 procs   96 constructors   102 events  2 skipped
        2  a parameter with no spelling
```

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

`tools/piid.nim` is the same computation the generator itself uses for the one
case it has to settle at generation time: a class whose default interface is
an instantiation. Everywhere else the hash is taken in the compiler by
`src/winrt/signatures.nim`, so the two implementations are checked against
each other by any test that reads a collection.

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

## Generating for another runtime

Both generators take the same two arguments — the metadata and an output
directory — and `generate.nim` takes an optional third, the import path its
modules use to find the hand-written plumbing:

```text
nim c -r tools/generate.nim <winmd> --split <out-dir> [package-path]
nim c -r tools/wrappers.nim <winmd> --split <out-dir>
```

`package-path` is `..` inside this package, which is the default, and
`winrt` for a package that depends on this one — the Windows App SDK's own
metadata, say, projected by a separate package whose generated modules import
`winrt/com` rather than `../com`.
