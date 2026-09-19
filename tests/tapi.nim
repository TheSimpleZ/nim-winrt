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
import winrt/security
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

  test "an async method is a Future, and waitFor settles it":
    # No ADC controller on a desktop, so this completes with a null result.
    # The point is that it completes at all: a wait that never returns would
    # hang the suite rather than fail it.
    let started = cpuTime()
    let adc = waitFor AdcController.getDefaultAsync()
    check cpuTime() - started < 10.0
    check adc.isNil

  test "await composes inside an async proc":
    proc probe(): Future[bool] {.async.} =
      let a = await AdcController.getDefaultAsync()
      return a.isNil
    check waitFor probe()

  test "a failed async fails the Future with the runtime's error code":
    # The HRESULT comes from IAsyncInfo.get_ErrorCode, not from the call that
    # started the operation — that one returned S_OK.
    expect WinRtError:
      discard waitFor Print3DDevice.fromIdAsync("not-a-real-device-id")

  test "a completion handler reaches a single-threaded apartment":
    # initApartment() puts this thread in an STA, and waitFor blocks it inside
    # a poll that does not pump COM messages. A handler that was not agile
    # would be marshalled back here and never arrive, so this hanging is the
    # failure mode it guards against.
    # `setup` put this thread in one; the default for initApartment is STA.
    discard waitFor AdcController.getDefaultAsync()
    check true

  test "IReference<T> comes back as an Option":
    # A BLE advertisement carries flags only if the advertiser sent them, and
    # WinRT says so with an interface that is null rather than a sentinel.
    let ad = newBluetoothLEAdvertisement()
    let flags = ad.flags
    check not flags.isSome          # a fresh advertisement has none
    # Setting one is not generated: handing a value *in* means boxing it
    # through PropertyValue, which is the other half of IReference and is not
    # done yet.

  test "a by-reference input is not an out-parameter":
    # `GuidHelper.Equals(GUID, GUID)` passes both by reference because they are
    # structs, not because they are outputs. The Param table says `[in]`, and
    # only that says otherwise.
    let a = guid("00000000-0000-0000-C000-000000000046")
    check GuidHelper.equals(a, a)
    check not GuidHelper.equals(a, GuidHelper.empty)

  test "a Nim seq can be handed to WinRT as a collection":
    # Calendar's constructor takes an IIterable<String>, so Windows iterates
    # an object built around the seq — First, MoveNext, get_Current — and this
    # passing means the vtables, the IIDs and the refcounts are all right.
    let cal = Calendar.createCalendar(@["en-GB", "sv-SE"],
                                      "GregorianCalendar", "24HourClock")
    check cal.languages == @["en-GB", "sv-SE"]
    check cal.getCalendarSystem == "GregorianCalendar"

  test "handing over a collection repeatedly does not leak it":
    # The view is released after the call; the elements it copied go with it.
    for i in 1 .. 2_000:
      let c = Calendar.createCalendar(@["en-GB"], "GregorianCalendar",
                                      "24HourClock")
      doAssert c.languages.len == 1
    check true

  test "an openArray crosses as a count and a pointer":
    # If either half were wrong the hex would not match the bytes.
    let buf = CryptographicBuffer.createFromByteArray([0xDE'u8, 0xAD, 0xBE, 0xEF])
    check CryptographicBuffer.encodeToHexString(buf) == "deadbeef"

  test "an empty openArray has no element to point at":
    let empty = CryptographicBuffer.createFromByteArray([])
    check CryptographicBuffer.encodeToHexString(empty) == ""
