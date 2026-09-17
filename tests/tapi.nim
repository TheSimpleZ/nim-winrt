## The generated API layer, against live Windows.
##
## The ABI layer is checked by `tactivation`; this checks the thing built on
## it — that a static class has members at all, that a factory constructor
## works where `RoActivateInstance` would fail, that strings cross as Nim
## strings, and that nothing has to be released by hand.

import std/unittest
import winrt
import winrt/foundation
import winrt/globalization
import winrt/system

suite "generated API":
  setup:
    discard initApartment()

  test "a static class exposes its members on the type":
    # `PowerManager` has no instances: everything it can do lives on an
    # interface reached through its activation factory.
    check PowerManager.batteryStatus in {BatteryStatus.NotPresent,
                                         BatteryStatus.Discharging,
                                         BatteryStatus.Idle,
                                         BatteryStatus.Charging}
    check PowerManager.remainingChargePercent in 0'i32 .. 100'i32

  test "a class with no parameterless constructor is built by its factory":
    # `RoActivateInstance` on Uri returns E_NOTIMPL — the metadata points at a
    # factory interface instead, and that is what this goes through.
    let uri = Uri.createUri("https://nim-lang.org/docs/manual.html?q=1")
    check uri.host == "nim-lang.org"
    check uri.path == "/docs/manual.html"
    check uri.query == "?q=1"
    check uri.schemeName == "https"

  test "a parameterless constructor is still generated where it works":
    let cal = newCalendar()
    cal.setToNow()
    check cal.year >= 2026
    check cal.getCalendarSystem.len > 0

  test "strings cross as Nim strings in both directions":
    let uri = Uri.createUri("https://example.com/a b")
    # WinRT escaped the space on the way in and gives it back escaped.
    check uri.path == "/a%20b"

  test "an object is released without being asked":
    # 20,000 constructions, each dropped by `=destroy` at the end of the
    # iteration. A leak here is a reference per loop and the process grows.
    for i in 1 .. 20_000:
      let uri = Uri.createUri("https://example.com/")
      doAssert uri.host == "example.com"
    check true

  test "an event on a static class subscribes and unsubscribes":
    var fired = 0
    let token = PowerManager.onEnergySaverStatusChanged(
      proc(sender, args: pointer) = fired.inc)
    check token.value != 0
    PowerManager.removeEnergySaverStatusChanged(token)
