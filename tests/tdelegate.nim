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
include winrt/abidef

# Two delegates of our own, declared the way the generated ABI declares one:
# the IID beside the vtable, which is where `newDelegate` reads it from.
const
  IID_OneArgHandler = guid"11111111-2222-3333-4444-555566667777"
  IID_TwoArgHandler = guid"11111111-2222-3333-4444-555566667778"

type
  OneArgHandlerVtbl = object of IUnknownVtbl
    Invoke: proc(self: pointer, args: pointer): HRESULT {.abi.}
  TwoArgHandlerVtbl = object of IUnknownVtbl
    Invoke: proc(self: pointer, sender, args: pointer): HRESULT {.abi.}

proc vtblOf(obj: pointer): ptr OneArgHandlerVtbl =
  ## What a COM caller does first: the object *is* a pointer to its table.
  cast[ptr ptr OneArgHandlerVtbl](obj)[]

proc invokeTwo(obj: pointer, sender, args: pointer): HRESULT =
  cast[ptr ptr TwoArgHandlerVtbl](obj)[].Invoke(obj, sender, args)

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
  discard vtblOf(d).Invoke(d, cast[pointer](5))
  0

proc liveSlots(): int =
  ## Slots in use. The table itself never shrinks, so this — not its length —
  ## is what has to come back down when a delegate is let go of.
  let (slots, free) = delegateTableSizes()
  slots - free

suite "delegate":
  test "Invoke sits at slot 3 and reaches the closure":
    var seen = 0
    let d = newDelegate(OneArgHandlerVtbl,
                        proc(args: pointer) = seen = cast[int](args))
    check vtblOf(d.raw).Invoke(d.raw, cast[pointer](42)) == S_OK
    check seen == 42

  test "an event delegate passes both arguments":
    var sender, args = 0
    let d = newDelegate(TwoArgHandlerVtbl, proc(s, a: pointer) =
      sender = cast[int](s)
      args = cast[int](a), event = true)
    check invokeTwo(d.raw, cast[pointer](7), cast[pointer](9)) == S_OK
    check sender == 7
    check args == 9

  test "a raising handler is contained, and an event still reports success":
    let bad = newDelegate(OneArgHandlerVtbl, proc(args: pointer) =
      raise newException(ValueError, "expected: tdelegate raises on purpose"))
    # A lifecycle callback reports the failure...
    check vtblOf(bad.raw).Invoke(bad.raw, nil) == E_FAIL

    let ev = newDelegate(TwoArgHandlerVtbl, proc(s, a: pointer) =
      raise newException(ValueError, "expected: tdelegate raises on purpose"),
      event = true)
    # ...but an event must not, or XAML tears the process down.
    check invokeTwo(ev.raw, nil, nil) == S_OK

  test "QueryInterface answers for IUnknown and its own IID only":
    let d = newDelegate(OneArgHandlerVtbl, proc(args: pointer) = discard)
    var first, second, third: pointer
    var unk = IID_IUnknown
    var own = IID_OneArgHandler
    var other = guid"00000000-0000-0000-C000-000000000047"
    check vtblOf(d.raw).queryInterface(d.raw, unk.addr, first.addr) == S_OK
    check first == d.raw
    check vtblOf(d.raw).queryInterface(d.raw, own.addr, second.addr) == S_OK
    check second == d.raw
    check vtblOf(d.raw).queryInterface(d.raw, other.addr, third.addr) == E_NOINTERFACE
    check third == nil
    # Each successful QueryInterface took a reference of its own; the one the
    # wrapper holds is dropped when it goes out of scope.
    check vtblOf(d.raw).release(d.raw) == 2
    check vtblOf(d.raw).release(d.raw) == 1

  test "a released delegate returns its handler slot":
    let base = liveSlots()
    var capacity = 0
    block:
      let d = newDelegate(OneArgHandlerVtbl, proc(args: pointer) = discard)
      check liveSlots() == base + 1
      capacity = delegateTableSizes().slots
      discard d.raw           # held to the end of the block
    check liveSlots() == base

    # The next delegate reuses the slot rather than growing the table.
    block:
      let e = newDelegate(OneArgHandlerVtbl, proc(args: pointer) = discard)
      check liveSlots() == base + 1
      check delegateTableSizes().slots == capacity
      discard e.raw

  test "a handler invoked from another thread runs on the dispatcher's":
    let main = getThreadId()
    var ranOn = 0
    var text = ""
    let d = newDelegate(OneArgHandlerVtbl, proc(args: pointer) =
      ranOn = getThreadId()
      text = "carried " & $cast[int](args))    # GC memory: safe only here
    let t = createThread(nil, 0, cast[pointer](invokeElsewhere), d.raw, 0, nil)
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
    let d = newDelegate(OneArgHandlerVtbl,
                        proc(args: pointer) = ranOn = getThreadId(), raw = true)
    let t = createThread(nil, 0, cast[pointer](invokeElsewhere), d.raw, 0, nil)
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check ranOn != 0
    check ranOn != getThreadId()
