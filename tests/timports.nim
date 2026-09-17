## Does every generated module still compile, together?
##
## The bindings are checked in, so a regeneration against a newer SDK is a
## large diff that nobody reads line by line. Compiling this file is what
## catches a bad one: importing all eighteen modules at once type-checks every
## declaration in them and, because they share one namespace at the import
## site, also catches two modules defining the same name — which is exactly
## what a new SDK type or a changed namespace split would cause.
##
## It is cheap: about 2.5 seconds over an empty program on this metadata.

import std/unittest
# No `import winrt`: every generated module re-exports `winrt/core`, so the
# runtime comes along with the bindings and importing it again is redundant.
import winrt/[ai, applicationmodel, data, devices, foundation, gaming,
              globalization, graphics, management, media, networking,
              perception, security, services, storage, system, ui, web]

suite "bindings":
  test "an IID, a slot and a signature survived generation":
    # A slot number is an index into a vtable Windows owns, so the value
    # matters, not just that the constant exists.
    check IID_IUriRuntimeClassFactory.data1 == 0x44A9796F'u32
    check Slot_IUriRuntimeClassFactory_CreateUri == 6
    var fn: Fn_IUriRuntimeClassFactory_CreateUri
    check fn == nil

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

  test "a hoisted type lands in foundation, not ui":
    # `Windows.UI.Color` is pulled forward so that anything visual can name it
    # without importing the 52,000-line `ui` module; see `hoisted` in
    # tools/generate.nim.
    let c = Color(a: 255, r: 1, g: 2, b: 3)
    check c.b == 3
    check sizeof(Color) == 4

  test "a struct shared between modules is one type":
    # Both `foundation` and `system` name EventRegistrationToken in their
    # signatures. If each declared its own, this assignment would not compile.
    var token = EventRegistrationToken(value: 7)
    var fn: Fn_IPowerManagerStatics_remove_BatteryStatusChanged
    check fn == nil
    check token.value == 7
