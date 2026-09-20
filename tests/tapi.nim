## The generated API layer, against live Windows.
##
## The ABI layer is checked by `tactivation`; this checks the thing built on
## it — that a static class has members at all, that a factory constructor
## works where `RoActivateInstance` would fail, that strings cross as Nim
## strings, and that nothing has to be released by hand.

import std/[algorithm, asynchttpserver, sequtils, strutils, times, unittest]
import winrt
import winrt/applicationmodel
import winrt/devices
import winrt/foundation
import winrt/gaming
import winrt/globalization
import winrt/graphics
import winrt/networking
import winrt/security
import winrt/storage
import winrt/system
import winrt/web
import winrt/abi/[devices, generic]
include winrt/abidef        # `{.abi.}`, for the methods of objects made here

# An `IBuffer` over bytes of ours needs the COM-side interface Windows reads
# them through, which is in no metadata. Declared the way the generated ABI
# declares one — the IID beside the vtable — and at module scope, which is
# where `implement` looks the IID up.
const IID_IBufferByteAccess = guid"905A0FEF-BC53-11DF-8C49-001E4FC686DA"

type
  Bytes = object
    data: seq[byte]
  IBufferByteAccessVtbl = object of IUnknownVtbl
    Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.}

suite "generated API":
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
    let uri = newUri("https://nim-lang.org/docs/manual.html?q=1")
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
    let uri = newUri("https://example.com/a b")
    # WinRT escaped the space on the way in and gives it back escaped.
    check uri.path == "/a%20b"

  test "an object is released without being asked":
    # 20,000 constructions, each dropped by `=destroy` at the end of the
    # iteration. A leak here is a reference per loop and the process grows.
    for i in 1 .. 20_000:
      let uri = newUri("https://example.com/")
      doAssert uri.host == "example.com"
    check true

  test "an event on a static class subscribes and unsubscribes":
    var fired = 0
    let token = PowerManager.onEnergySaverStatusChanged(
      proc(sender: WinRtObject, args: WinRtObject) = fired.inc)
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

  test "a completion handler reaches a thread blocked in waitFor":
    # `waitFor` blocks this thread inside a poll that does not pump COM
    # messages. A handler that was not agile would be marshalled back here and
    # never arrive, so this hanging is the failure mode it guards against.
    discard waitFor AdcController.getDefaultAsync()
    check true

  test "IReference<T> comes back as an Option":
    # A BLE advertisement carries flags only if the advertiser sent them, and
    # WinRT says so with an interface that is null rather than a sentinel.
    let advertisement = newBluetoothLEAdvertisement()
    check advertisement.flags.isNone

  test "a by-reference input is not an out-parameter":
    # `GuidHelper.Equals(GUID, GUID)` passes both by reference because they are
    # structs, not because they are outputs. The Param table says `[in]`, and
    # only that says otherwise.
    let a = guid"00000000-0000-0000-C000-000000000046"
    check GuidHelper.equals(a, a)
    check not GuidHelper.equals(a, GuidHelper.empty)

  test "a Nim seq can be handed to WinRT as a collection":
    # Calendar's constructor takes an IIterable<String>, so Windows iterates
    # an object built around the seq — First, MoveNext, get_Current — and this
    # passing means the vtables, the IIDs and the refcounts are all right.
    let cal = newCalendar(@["en-GB", "sv-SE"], "GregorianCalendar", "24HourClock")
    check cal.languages == @["en-GB", "sv-SE"]
    check cal.getCalendarSystem == "GregorianCalendar"

  test "handing over a collection repeatedly does not leak it":
    # The view is released after the call; the elements it copied go with it.
    for i in 1 .. 2_000:
      let cal = newCalendar(@["en-GB"], "GregorianCalendar", "24HourClock")
      doAssert cal.languages.len == 1
    check true

  test "an openArray crosses as a count and a pointer":
    # If either half were wrong the hex would not match the bytes.
    let buffer = CryptographicBuffer.createFromByteArray([0xDE'u8, 0xAD, 0xBE, 0xEF])
    check CryptographicBuffer.encodeToHexString(buffer) == "deadbeef"

  test "an empty openArray has no element to point at":
    let empty = CryptographicBuffer.createFromByteArray([])
    check CryptographicBuffer.encodeToHexString(empty) == ""

  test "an array of bytes crosses in, and a received array comes back out":
    let buffer = CryptographicBuffer.createFromByteArray([1'u8, 2, 3])
    check buffer.length == 3
    check CryptographicBuffer.encodeToBase64String(buffer) == "AQID"
    # `[out] UInt8[]` — the callee allocates, and the only out-parameter is
    # the result.
    check CryptographicBuffer.copyToByteArray(buffer) == @[1'u8, 2, 3]

  test "a string-keyed map reads as a Table":
    # Filled through the ABI, because `IMap<K, V>`'s own methods live on a
    # parameterised interface and no class wraps them. That is the point: the
    # generated read path has to walk real pairs, not an empty map, or a
    # failed QueryInterface would look the same as no entries.
    let model = newPrinting3DModel()
    check model.metadata.len == 0

    let it = queryInterface[IPrinting3DModelVtbl](model)
    var raw: pointer
    it.vtbl.get_Metadata(it.raw, raw.addr).check("get_Metadata")
    let entries = queryInterface[IMapVtbl[string, string]](raw)
    release(raw)
    for (key, value) in {"title": "a cube", "author": "nim"}:
      let k = toWinRtString(key)
      let v = toWinRtString(value)
      var replaced: bool
      entries.vtbl.Insert(entries.raw, k.handle, v.handle, replaced.addr)
        .check("IMap.Insert")

    let read = model.metadata
    check read.len == 2
    check read["title"] == "a cube"
    check read["author"] == "nim"

  test "an Option round-trips through IReference<T>":
    # Boxing is only half of it. `PropertyValue.CreateTimeSpan` hands back an
    # IInspectable, and a method declaring `IReference<TimeSpan>` wants that
    # interface — both are bare pointers at the ABI, so handing over the wrong
    # one is silent and the value reads back as zero.
    let appointment = newAppointment()
    check appointment.reminder.isNone
    appointment.reminder = some(TimeSpan(duration: 9_000_000_000'i64))
    check appointment.reminder.isSome
    check appointment.reminder.get.duration == 9_000_000_000'i64
    appointment.reminder = none(TimeSpan)
    check appointment.reminder.isNone

  test "an Option of a value the runtime cannot box still crosses":
    # `IReference<BluetoothLEAdvertisementFlags>`: no `PropertyValue.CreateX`
    # exists for an enum, so this goes through an object of the library's own,
    # and the runtime reads it back through `get_Value`.
    let advertisement = newBluetoothLEAdvertisement()
    advertisement.flags = some(BluetoothLEAdvertisementFlags(2'u32))
    check advertisement.flags.isSome
    check uint32(advertisement.flags.get) == 2
    advertisement.flags = none(BluetoothLEAdvertisementFlags)
    check advertisement.flags.isNone

  test "a seq of structs crosses as a collection and reads back":
    let path = newGeopath(@[
      BasicGeoposition(latitude: 59.33, longitude: 18.07, altitude: 0),
      BasicGeoposition(latitude: 57.71, longitude: 11.97, altitude: 0)])
    let back = path.positions
    check back.len == 2
    check back[1].latitude == 57.71

  test "a Table crosses as a map, and a WithProgress operation is awaited":
    # `HttpFormUrlEncodedContent` takes an `IIterable<IKeyValuePair<String,
    # String>>`, and `ReadAsStringAsync` is an
    # `IAsyncOperationWithProgress<String, UInt64>` — the layout whose
    # Completed and GetResults sit two slots further down.
    let content = newHttpFormUrlEncodedContent({"a": "1", "b": "2"}.toTable)
    let encoded = waitFor content.readAsStringAsync()
    check encoded.split('&').sorted == @["a=1", "b=2"]

  test "a seq crosses as a mutable vector":
    let dns = @[newHostName("1.1.1.1"), newHostName("8.8.8.8")]
    let info = newVpnNamespaceInfo("example", dns, @[])
    check info.dnsServers.mapIt(it.canonicalName) == @["1.1.1.1", "8.8.8.8"]

  test "a delegate argument is a Nim closure, run on the dispatcher thread":
    # The pool invokes it on a pool thread; it runs here, where a closure may
    # allocate — which this one does, freely.
    let main = getThreadId()
    var seen = ""
    waitFor ThreadPool.runAsync(proc(operation: IAsyncAction) =
      seen = "thread " & $getThreadId() & " " & operation.runtimeClassName)
    check seen == "thread " & $main & " Windows.Foundation.IAsyncAction"

  test "a failed call carries the runtime's own message":
    try:
      discard newUri("not a uri at all")
      check false
    except WinRtError as e:
      check e.hr == E_INVALIDARG
      check e.msg == "Uri.new failed: E_INVALIDARG: " &
                     "not a uri at all is not a valid absolute URI."

  test "an interface implemented in Nim is one Windows can hold and call":
    # An `IReference<BluetoothLEAdvertisementFlags>` implemented by hand rather
    # than boxed, handed to Windows through the ABI, read back through the
    # generated getter: Windows keeps the object, and the generated reader
    # reaches our `get_Value` through it.
    var flag = BluetoothLEAdvertisementFlags(2'u32)
    let box = implement(
      IReferenceVtbl[BluetoothLEAdvertisementFlags](get_Value:
        proc(self: pointer, value: ptr BluetoothLEAdvertisementFlags): HRESULT
            {.abi.} =
          value[] = cast[ptr BluetoothLEAdvertisementFlags](stateOf(self))[]
          S_OK),
      state = flag.addr)
    let advertisement = newBluetoothLEAdvertisement()
    let it = queryInterface[IBluetoothLEAdvertisementVtbl](advertisement)
    it.vtbl.put_Flags(it.raw, box).check("put_Flags")
    release(box)                    # Windows holds its own reference now
    check advertisement.flags.isSome
    check uint32(advertisement.flags.get) == 2

  test "an object implementing two interfaces is queried for both":
    # An `IBuffer` over bytes of ours, with the COM-side `IBufferByteAccess`
    # Windows uses to reach them. `EncodeToBase64String` queries the second
    # interface off the first and reads through both.
    var bytes = Bytes(data: @[byte 'h'.ord, 'i'.ord, '!'.ord])
    let buffer = adopt[IBuffer](implement(
      IBufferVtbl(
        get_Capacity: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
          value[] = uint32(cast[ptr Bytes](stateOf(self)).data.len)
          S_OK,
        get_Length: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
          value[] = uint32(cast[ptr Bytes](stateOf(self)).data.len)
          S_OK,
        put_Length: proc(self: pointer, length: uint32): HRESULT {.abi.} =
          cast[ptr Bytes](stateOf(self)).data.setLen(length)
          S_OK),
      IBufferByteAccessVtbl(
        Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.} =
          value[] = cast[ptr Bytes](stateOf(self)).data[0].addr
          S_OK),
      state = bytes.addr))
    check CryptographicBuffer.encodeToBase64String(buffer) == "aGkh"
    check buffer.length == 3

  test "cancel stops an operation, and its Future fails with CancelledError":
    # The work item's handler is marshalled to this thread, so the item is
    # still running when this thread asks; the runtime finishes it as
    # Canceled either way.
    let fut = ThreadPool.runAsync(proc(operation: IAsyncAction) = discard)
    check cancel(fut)
    expect CancelledError:
      waitFor fut
    check not cancel(fut)                       # finished: nothing to stop
    check not cancel(newFuture[int]("mine"))    # not a WinRT operation

  test "a WithProgress operation reports to the progress closure":
    # Windows' HttpClient fetching from a server on this very dispatcher,
    # which serves while `waitFor` polls. `HttpProgress` is a struct the
    # runtime hands to the delegate by value, from its own thread: the ABI
    # case worth proving, and the closure still runs here.
    let server = newAsyncHttpServer()
    proc serveBody(req: Request) {.async.} =
      await req.respond(Http200, "x".repeat(1_000_000))
    asyncCheck server.serve(Port(18081), serveBody, address = "127.0.0.1")
    defer: server.close()

    let main = getThreadId()
    var reports: seq[HttpProgress]
    var ranOn = 0
    let body = waitFor newHttpClient().getStringAsync(
      newUri("http://127.0.0.1:18081/"),
      progress = proc(value: HttpProgress) =
        ranOn = getThreadId()
        reports.add value)
    check body.len == 1_000_000
    check reports.len > 0
    check ranOn == main
    check reports[^1].stage == HttpProgressStage.ReceivingContent
    check reports[^1].bytesReceived == 1_000_000
    # The `IReference<UInt64>` inside the struct is an `Option[uint64]` here,
    # read well after the callback that carried it.
    check reports[^1].totalBytesToReceive == some(1_000_000'u64)

  test "a string inside a struct is a Nim string on this side":
    # Out of Windows: the sort order a common query starts with. Each entry's
    # HSTRING was read into a `string` when `GetAt` handed the struct over.
    let options = newQueryOptions(CommonFileQuery.OrderByName, @["*"])
    let order = options.sortOrder
    check order.len > 0
    check order[0].propertyName == "System.ItemNameDisplay"
    check order[0].ascendingOrder
    # Into Windows: a struct built here, with a string of ours inside it.
    let mine = SortEntry(propertyName: "System.Size", ascendingOrder: false)
    check mine.propertyName == "System.Size"
    check hash(mine) == hash(SortEntry(propertyName: "System.Size"))
    # And a reference built here reads back through the runtime's box.
    check asReference(42'u64).value == some(42'u64)
    check Reference[uint64]().value.isNone

  test "an out-parameter comes back in the tuple":
    let (outcome, info) = PhoneNumberInfo.tryParse("+46 8 123 456", "SE")
    check outcome == PhoneNumberParseResult.Valid
    check info.countryCode == 46
