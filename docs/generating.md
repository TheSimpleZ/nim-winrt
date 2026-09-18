# Regenerating the bindings

`src/winrt/*.nim` is generated and checked in. You only need this page to move
the package to a newer Windows SDK, or to work on the generator itself — see
[internals.md](internals.md) for how it works.

## What you need

The Windows SDK's union metadata, which the SDK installs at:

```
C:\Program Files (x86)\Windows Kits\10\UnionMetadata\<version>\Windows.winmd
```

That single file describes every WinRT type in the SDK. Nothing else is
needed — no C++ toolchain, no vendored headers.

## Running it

```
nimble bindings
```

This builds `tools/generate.nim` and runs it over
`10.0.26100.0/Windows.winmd`, rewriting all eighteen modules in `src/winrt`.
Allow two to three minutes: the reader walks 14,672 types and 71,813 methods,
and it is written for clarity rather than speed. To point it somewhere else:

```
WINMD="C:/Program Files (x86)/Windows Kits/10/UnionMetadata/10.0.22621.0/Windows.winmd" nimble bindings
```

The task refuses to run rather than half-generating if the file is not there.

It prints what it did, which is the first thing to read afterwards:

```
  14 groups placed ahead of something they reference; 128 signatures go out untyped
  foundation          19 enums   18 structs    72 interfaces    397 slots (68% typed)
  storage             59 enums    2 structs   195 interfaces    864 slots (99% typed)
  ...
  18 modules  1724 enums  124 structs
  8178 interfaces  33719 slots  98% typed  405 unmapped
```

A new SDK should move those numbers *up*. A drop in the typed percentage, or a
jump in the number of cut edges, means the metadata grew a shape the generator
does not handle — run `tools/unmapped.nim` (below) to find out which.

## Checking the result

```
nimble test
```

`tests/timports.nim` is the one that matters here: it imports all eighteen
modules into one scope, which type-checks every generated declaration and
turns a name collision between two modules into a compile error rather than a
surprise for whoever first imports both. `tests/tactivation.nim` then proves a
generated IID and slot number still reach the real runtime.

Then read the diff. Generation is deterministic — the same metadata produces
byte-identical files — so everything you see is something the SDK changed. Two
shapes of change are worth looking at closely:

* **A slot number moving.** This should not happen: WinRT interfaces are
  immutable once shipped, and a new version of an interface is a new interface
  (`IPowerManagerStatics2`). If a slot moves, something is wrong with the read,
  not with Windows.
* **An `Fn_` becoming `# signature not mapped`.** A type that used to resolve
  no longer does, usually because a struct moved to a winmd this one only
  references.

Finally, `nimble examples` builds and runs the four example programs against
the regenerated bindings.

## The diagnostics

These are standalone programs under `tools/`, all taking a `.winmd` path.
None of them are part of the build.

### `dump.nim` — is the reader reading it correctly?

```
nim c -r tools/dump.nim <winmd>                       # namespaces by size
nim c -r tools/dump.nim <winmd> <TypeName> [...]      # one type's IID and slots
```

```
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

Check those against the SDK headers or `winmdroot` when bringing up a new
metadata file. Row widths are global, so a reader that is wrong is wrong
*plausibly* — this is how you tell.

### `inspect.nim` — one type in detail

```
nim c -r tools/inspect.nim <winmd> <TypeName>
```

Flags, base type, custom attributes and implemented interfaces, in declaration
order — which matters, because WinRT lists a runtime class's *default*
interface first. Use it when a class will not activate, or to find out which
interface actually declares the method you want.

### `unmapped.nim` — what is not typed, and why

```
nim c -r tools/unmapped.nim <winmd> <namespace-prefix>
```

"2% of signatures" is not actionable; this groups every untyped method by the
*shape* that stopped it, with examples, so the remaining work can be judged one
shape at a time. It also counts separately the methods that are typed only as
an opaque `pointer` because a generic instantiation crosses that way.

```
methods            33724
untyped            392  (1%)
typed as pointer   5226  (a generic instantiation)

  257  array of a primitive
         e.g. ITableActionEntity.GetTextContent
   30  pointer or type variable
   16  array of Point
  ...

typed as an opaque pointer, by generic:
 1648  IAsyncOperation`1
 1134  TypedEventHandler`2
  804  IReference`1
```

### `piidcheck.nim` — are the computed generic IIDs right?

```
nim c -r tools/piidcheck.nim <winmd> <namespace-prefix>
```

Every generic instantiation the metadata uses, with the signature string it
hashes to and the resulting IID:

```
  34  Windows.Foundation.EventHandler`1<skObject>
        pinterface({9de1c535-6ae1-11e0-84e1-18a905bcc53f};cinterface(IInspectable))
        {C50898F6-C536-5F47-8583-8B2C2438A13B}
```

A wrong signature produces a well-formed GUID that no object implements, so
there is no way to tell from the IID alone — the signature string is the part
you can check by eye against the Windows Runtime ABI documentation, and a live
`QueryInterface` is the only real proof. `examples/events.nim` uses the IID
above and Windows accepts it, which is that proof for one case.

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

`generate.nim` also runs in single-file mode, which is what
[nim-winui3](https://github.com/TheSimpleZ/nim-winui3) uses over
`Microsoft.UI.Xaml.winmd`:

```
nim c -r tools/generate.nim <winmd> <prefix> <out.nim> [core-import] [provider]
```

`core-import` is where the generated module finds `HSTRING` and `GUID`
(`./core` inside this package, `winrt/core` from a package depending on it).
`provider` names a module that already projects the `Windows.*` types the
winmd merely references, so they are imported rather than declared a second
time — without it an app importing both packages would have two incompatible
`Point` types.

`tools/wrappers.nim` takes the same arguments and emits the friendly layer on
top. Neither is used to build this package.
