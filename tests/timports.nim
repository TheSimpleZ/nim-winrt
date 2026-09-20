## Does every generated module still compile, together?
##
## The bindings are checked in, so a regeneration against a newer SDK is a
## large diff that nobody reads line by line. Compiling this file is what
## catches a bad one: importing all eighteen modules at once type-checks every
## declaration in them and, because they share one namespace at the import
## site, also catches two modules defining the same name — which is exactly
## what a new SDK type or a changed namespace split would cause.

import std/unittest
# No `import winrt`: every generated module re-exports the runtime, so it
# comes along with the bindings and importing it again is redundant.
import winrt/[ai, applicationmodel, data, devices, foundation, gaming,
               globalization, graphics, management, media, networking,
               perception, security, services, storage, system, ui, web]
import winrt/abi/[foundation, system]

suite "bindings":
  test "an IID and a vtable survived generation":
    # A field's offset is an index into a vtable Windows owns, so the position
    # matters, not just that the field exists.
    check IID_IUriRuntimeClassFactory.data1 == 0x44A9796F'u32
    check offsetOf(IUriRuntimeClassFactoryVtbl, CreateUri) == 6 * sizeof(pointer)
    var vtbl: IUriRuntimeClassFactoryVtbl
    check vtbl.CreateUri == nil

  test "a type and its vtable answer to the same IID":
    # `iid` reads the constant beside the vtable, and the API's object for a
    # shared interface is named after the same interface, so both reach it.
    check iid(IClosableVtbl) == iid(IClosable)
    check iid(IClosableVtbl) == guid"30D5A829-7FA4-4026-83BB-D75BAE4EA99E"

  test "a class knows its metadata name and its default interface":
    check className(Uri) == "Windows.Foundation.Uri"
    check defaultIid(Uri) == iid(IUriRuntimeClassVtbl)

  test "a plain enum is a real Nim enum, sized for the wire":
    check ord(BatteryStatus.Charging) == 3
    check sizeof(BatteryStatus) == 4
    check $BatteryStatus.Charging == "Charging"
    # A newer Windows can return a value this metadata predates. The built-in
    # `$` renders that as the empty string, so the generated one takes over.
    check $cast[BatteryStatus](99'i32) == "BatteryStatus(99)"

  test "a [Flags] enum combines, prints and tests membership":
    let held = GamepadButtons_A or GamepadButtons_Menu
    check GamepadButtons_A in held
    check GamepadButtons_B notin held
    check $held == "Menu or A"

  test "a [Flags] enum is unsigned, as the type system requires":
    # "An enum with an underlying type of UInt32 must carry the FlagsAttribute.
    # An enum with an underlying type of Int32 must not." Signed is not just
    # untidy: `All` is 0xFFFFFFFF, and as an int32 that reads back as -1.
    check sizeof(ContactQuerySearchFields) == 4
    check uint32(ContactQuerySearchFields_All) == 0xFFFFFFFF'u32
    check $ContactQuerySearchFields_All != "-1"

  test "a struct from a large namespace is reachable from a small module":
    # `Windows.UI.Color` lives in `abi/types` with every other struct, so
    # anything visual can name it without importing `ui`.
    let c = Color(a: 255, r: 1, g: 2, b: 3)
    check c.b == 3
    check sizeof(Color) == 4

  test "a struct holding a string is plain Nim on this side of the ABI":
    # `SortEntry` crosses with an HSTRING inside it and is read with a
    # `string`: the twin does the owning, and nobody using it sees one.
    let entry = SortEntry(propertyName: "System.ItemNameDisplay",
                          ascendingOrder: true)
    check entry.propertyName == "System.ItemNameDisplay"
    check entry == SortEntry(propertyName: "System.ItemNameDisplay",
                             ascendingOrder: true)
    check sizeof(SortEntryAbi) == sizeof(pointer) + sizeof(bool) + 7

  test "a struct shared between modules is one type":
    # Both `foundation` and `system` name EventRegistrationToken in their
    # signatures. If each declared its own, a `foundation` token could not be
    # handed to a `system` method.
    var vtbl: IPowerManagerStaticsVtbl
    vtbl.remove_BatteryStatusChanged =
      proc(self: pointer, token: EventRegistrationToken): HRESULT
          {.stdcall, raises: [], gcsafe.} =
        if token.value == 7: S_OK else: E_FAIL
    check vtbl.remove_BatteryStatusChanged(nil, EventRegistrationToken(value: 7)) == S_OK
