## Is a delegate a COM object the runtime could actually call?
##
## The runtime is not needed to answer that: a delegate is a plain vtable this
## library builds by hand, so the test drives it the way WinRT would — read the
## table out of the object, call slots by index — and checks the answers. That
## catches the two mistakes the layout invites: a vtable pointer that is not
## first, and an `Invoke` at the wrong index.
##
## The handler table is checked too. It is process-wide and never shrinks, so
## the property worth asserting is that releasing a delegate returns its slot
## rather than abandoning it.

import std/unittest
import winrt

type
  Vtbl = object
    queryInterface: proc(self: pointer, riid: ptr GUID,
                         ppv: ptr pointer): HRESULT {.stdcall.}
    addRef: proc(self: pointer): uint32 {.stdcall.}
    release: proc(self: pointer): uint32 {.stdcall.}
    invoke1: proc(self: pointer, args: pointer): HRESULT {.stdcall.}

proc vtblOf(obj: pointer): ptr Vtbl =
  ## What a COM caller does first: the object *is* a pointer to its table.
  cast[ptr ptr Vtbl](obj)[]

# A thread Nim did not start, the way the runtime's threads are.
proc createThread(attributes: pointer, stackSize: uint, start: pointer,
                  parameter: pointer, flags: uint32, id: ptr uint32): pointer
  {.importc: "CreateThread", stdcall, dynlib: "kernel32".}
proc waitForSingleObject(h: pointer, ms: uint32): uint32
  {.importc: "WaitForSingleObject", stdcall, dynlib: "kernel32".}
proc closeHandle(h: pointer): int32
  {.importc: "CloseHandle", stdcall, dynlib: "kernel32".}

proc invokeElsewhere(d: pointer): uint32 {.stdcall.} =
  ## What the runtime does: call `Invoke` from its own thread.
  discard vtblOf(d).invoke1(d, cast[pointer](5))
  0

const testIid = GUID(
  data1: 0x11111111'u32, data2: 0x2222'u16, data3: 0x3333'u16,
  data4: [0x44'u8, 0x44, 0x55, 0x55, 0x66, 0x66, 0x77, 0x77])

suite "delegate":
  test "Invoke sits at slot 3 and reaches the closure":
    var seen = 0
    let d = newDelegate(testIid, proc(args: pointer) = seen = cast[int](args))
    defer: discard vtblOf(d).release(d)

    check vtblOf(d).invoke1(d, cast[pointer](42)) == S_OK
    check seen == 42

  test "an event delegate passes both arguments":
    var sender, args = 0
    let d = newDelegate(testIid, proc(s, a: pointer) =
      sender = cast[int](s)
      args = cast[int](a), event = true)
    defer: discard vtblOf(d).release(d)

    # Two-argument Invoke, which is a different table shape from the above.
    let invoke2 = cast[proc(self, s, a: pointer): HRESULT {.stdcall.}](
      cast[ptr UncheckedArray[pointer]](vtblOf(d))[3])
    check invoke2(d, cast[pointer](7), cast[pointer](9)) == S_OK
    check sender == 7
    check args == 9

  test "a raising handler is contained, and an event still reports success":
    let bad = newDelegate(testIid, proc(args: pointer) =
      raise newException(ValueError, "expected: tdelegate raises on purpose"))
    defer: discard vtblOf(bad).release(bad)
    # A lifecycle callback reports the failure...
    check vtblOf(bad).invoke1(bad, nil) == E_FAIL

    let ev = newDelegate(testIid, proc(s, a: pointer) =
      raise newException(ValueError, "expected: tdelegate raises on purpose"),
      event = true)
    defer: discard vtblOf(ev).release(ev)
    let invoke2 = cast[proc(self, s, a: pointer): HRESULT {.stdcall.}](
      cast[ptr UncheckedArray[pointer]](vtblOf(ev))[3])
    # ...but an event must not, or XAML tears the process down.
    check invoke2(ev, nil, nil) == S_OK

  test "QueryInterface answers for IUnknown and its own IID only":
    let d = newDelegate(testIid, proc(args: pointer) = discard)
    defer: discard vtblOf(d).release(d)

    var out1, out2, out3: pointer
    var unk = IID_IUnknown
    var own = testIid
    var other = guid("00000000-0000-0000-C000-000000000047")
    check vtblOf(d).queryInterface(d, unk.addr, out1.addr) == S_OK
    check out1 == d
    check vtblOf(d).queryInterface(d, own.addr, out2.addr) == S_OK
    check out2 == d
    check vtblOf(d).queryInterface(d, other.addr, out3.addr) == E_NOINTERFACE
    check out3 == nil
    # Each successful QueryInterface took a reference of its own.
    check vtblOf(d).release(d) == 2
    check vtblOf(d).release(d) == 1

  test "a released delegate returns its handler slot":
    proc live(): int =
      ## Slots in use. The table itself never shrinks, so this — not its
      ## length — is what has to come back down.
      let (slots, free) = delegateTableSizes()
      slots - free

    let base = live()
    let d = newDelegate(testIid, proc(args: pointer) = discard)
    check live() == base + 1
    let capacity = delegateTableSizes().slots

    check vtblOf(d).release(d) == 0
    check live() == base

    # The next delegate reuses the slot rather than growing the table.
    let e = newDelegate(testIid, proc(args: pointer) = discard)
    check live() == base + 1
    check delegateTableSizes().slots == capacity
    discard vtblOf(e).release(e)

  test "a handler invoked from another thread runs on the dispatcher's":
    let main = getThreadId()
    var ranOn = 0
    var text = ""
    let d = newDelegate(testIid, proc(args: pointer) =
      ranOn = getThreadId()
      text = "carried " & $cast[int](args))    # GC memory: safe only here
    defer: discard vtblOf(d).release(d)
    let t = createThread(nil, 0, cast[pointer](invokeElsewhere), d, 0, nil)
    # The invoking thread is blocked until this one runs the handler, which
    # happens when the dispatcher is polled.
    while ranOn == 0: poll(10)
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check ranOn == main
    check text == "carried 5"

  test "work posted from another thread runs on the dispatcher's, unwaited":
    ensureDispatcher()
    var ranOn = 0
    proc job(arg: pointer) {.nimcall, raises: [].} =
      cast[ptr int](arg)[] = getThreadId()
    proc postElsewhere(arg: pointer): uint32 {.stdcall.} =
      runOnDispatcher(job, arg)
      0
    let t = createThread(nil, 0, cast[pointer](postElsewhere), ranOn.addr, 0, nil)
    # Returns at once: the posting thread does not wait for the job.
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check ranOn == 0
    poll(10)
    check ranOn == getThreadId()

  test "a raw delegate runs where it is invoked":
    var ranOn = 0
    let d = newDelegate(testIid, proc(args: pointer) = ranOn = getThreadId(),
                        raw = true)
    defer: discard vtblOf(d).release(d)
    let t = createThread(nil, 0, cast[pointer](invokeElsewhere), d, 0, nil)
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check ranOn != 0
    check ranOn != getThreadId()
