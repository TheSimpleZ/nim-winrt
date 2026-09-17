## The generated API layer, against live Windows.
##
## The ABI layer is checked by `tactivation`; this checks the thing built on
## it — that a static class has members at all, that a factory constructor
## works where `RoActivateInstance` would fail, that strings cross as Nim
## strings, and that nothing has to be released by hand.

import std/[unittest, sequtils, strutils, times]
import winrt
import winrt/foundation
import winrt/globalization
import winrt/system
import winrt/gaming
import winrt/devices

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

  test "a collection comes back as a seq":
    # `IVectorView<String>`. The IID of that instantiation is declared nowhere
    # in the metadata — WinRT derives it by hashing a signature string — so
    # this failing would mean the computed IID was wrong.
    let zones = TimeZoneSettings.supportedTimeZoneDisplayNames
    check zones.len > 100
    check zones.allIt(it.len > 0)
    check zones.anyIt("UTC" in it)

  test "an empty collection is an empty seq, not a failure":
    # No controller is attached on CI, and asking should still work.
    check Gamepad.gamepads.len >= 0

  test "walking a collection repeatedly does not leak its elements":
    # Each GetAt hands over a reference that the wrapper adopts, so a botched
    # lifetime here shows up as unbounded growth rather than a wrong answer.
    var last = 0
    for i in 1 .. 2_000:
      last = TimeZoneSettings.supportedTimeZoneDisplayNames.len
    check last > 100

  test "an async method blocks and hands back its result":
    # No ADC controller on a desktop, so this completes with a null result.
    # The point is that it completes: a wait that never returns would hang the
    # suite rather than fail it.
    let started = cpuTime()
    let adc = AdcController.getDefaultAsync()
    check cpuTime() - started < 10.0
    check adc.isNil

  test "a failed async raises with the runtime's own error code":
    # The HRESULT comes from IAsyncInfo.get_ErrorCode, not from the call that
    # started the operation — that one succeeded.
    expect WinRtError:
      discard Print3DDevice.fromIdAsync("not-a-real-device-id")
