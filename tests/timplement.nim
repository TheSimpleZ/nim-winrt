## Is an object made with `implement` one COM would recognise?
##
## The runtime is not needed: `implement` builds vtables by hand, so this
## drives them the way Windows would — query, count, call — and checks the
## answers. What it guards: that every interface's pointer leads back to the
## same object and the same state, that `QueryInterface` answers for exactly
## what was implemented, and that the state is disposed of on the dispatcher's
## thread whichever thread let go last.

import std/unittest
import winrt
include winrt/abidef

type
  # IUnknown-based, the shape of `IBufferByteAccess`.
  RawVtbl = object of IUnknownVtbl
    raw: proc(self: pointer, value: ptr int32): HRESULT {.abi.}
  # IInspectable-based, the shape of every WinRT interface.
  FirstVtbl = object of IInspectableVtbl
    first: proc(self: pointer, value: ptr int32): HRESULT {.abi.}
  SecondVtbl = object of IInspectableVtbl
    second: proc(self: pointer, value: ptr int32): HRESULT {.abi.}

const
  iidFirst = guid"11111111-0000-0000-0000-000000000001"
  iidSecond = guid"11111111-0000-0000-0000-000000000002"
  iidRaw = guid"11111111-0000-0000-0000-000000000003"
  iidOther = guid"11111111-0000-0000-0000-00000000000F"

proc readState(self: pointer, value: ptr int32): HRESULT {.abi.} =
  ## The one method every table here carries: the state, through `self`.
  value[] = cast[ptr int32](stateOf(self))[]
  S_OK

proc unk(obj: pointer): ptr IUnknownVtbl =
  ## What a COM caller does first: the object *is* a pointer to its table.
  cast[ptr ptr IUnknownVtbl](obj)[]

proc insp(obj: pointer): ptr IInspectableVtbl =
  cast[ptr ptr IInspectableVtbl](obj)[]

proc query(obj: pointer, iid: GUID): pointer =
  var want = iid
  discard unk(obj).queryInterface(obj, want.addr, result.addr)

proc drop(obj: pointer): uint32 {.discardable.} =
  unk(obj).release(obj)

# A thread Nim did not start, the way the runtime's threads are.
proc createThread(attributes: pointer, stackSize: uint, start: pointer,
                  parameter: pointer, flags: uint32, id: ptr uint32): pointer
  {.importc: "CreateThread", stdcall, dynlib: "kernel32".}
proc waitForSingleObject(h: pointer, ms: uint32): uint32
  {.importc: "WaitForSingleObject", stdcall, dynlib: "kernel32".}
proc closeHandle(h: pointer): int32
  {.importc: "CloseHandle", stdcall, dynlib: "kernel32".}

proc releaseElsewhere(obj: pointer): uint32 {.stdcall.} =
  ## What the runtime does when it is done with an object of ours.
  drop(obj)
  0

proc noteThread(state: pointer) {.nimcall, raises: [].} =
  ## A `dispose`: which thread it ran on, into the state.
  cast[ptr int](state)[] = getThreadId()

var state = 42'i32

suite "implement":
  test "each interface has its own vtable, and all reach the same state":
    let obj = implement((iidFirst, FirstVtbl(first: readState)),
                        (iidSecond, SecondVtbl(second: readState)),
                        (iidRaw, RawVtbl(raw: readState)),
                        state = state.addr)
    defer: release(obj)
    let second = query(obj, iidSecond)
    let raw = query(obj, iidRaw)
    check second != nil
    check raw != nil
    check second != obj                # a different vtable pointer each
    check raw != second

    var v: int32
    check cast[ptr ptr FirstVtbl](obj)[].first(obj, v.addr) == S_OK
    check v == 42
    v = 0
    check cast[ptr ptr SecondVtbl](second)[].second(second, v.addr) == S_OK
    check v == 42
    v = 0
    check cast[ptr ptr RawVtbl](raw)[].raw(raw, v.addr) == S_OK
    check v == 42

    # One count for the whole object, whichever pointer it is counted through.
    check drop(raw) == 2
    check drop(second) == 1

  test "QueryInterface answers for what was implemented and the three basics":
    let obj = implement((iidRaw, RawVtbl(raw: readState)),
                        (iidFirst, FirstVtbl(first: readState)))
    defer: release(obj)
    check query(obj, IID_IUnknown) == obj
    check query(obj, IID_IAgileObject) == obj
    # IInspectable is the first interface that *is* one — not the first slot.
    let first = query(obj, iidFirst)
    check query(obj, IID_IInspectable) == first
    check query(obj, iidOther) == nil
    for i in 1 .. 4: drop(obj)

  test "an object of COM interfaces only is not an IInspectable":
    let obj = implement(iidRaw, RawVtbl(raw: readState))
    defer: release(obj)
    check query(obj, IID_IInspectable) == nil
    check query(obj, IID_IUnknown) == obj
    drop(obj)

  test "GetIids lists the WinRT interfaces and leaves out the COM ones":
    let obj = implement((iidRaw, RawVtbl(raw: readState)),
                        (iidFirst, FirstVtbl(first: readState)),
                        (iidSecond, SecondVtbl(second: readState)))
    defer: release(obj)
    let first = query(obj, iidFirst)
    var count: uint32
    var iids: ptr GUID
    check insp(first).getIids(first, count.addr, iids.addr) == S_OK
    check count == 2
    let listed = cast[ptr UncheckedArray[GUID]](iids)
    check listed[0] == iidFirst
    check listed[1] == iidSecond
    comFree(iids)
    drop(first)

  test "the state is disposed of with the last reference, on this thread":
    var disposedOn = 0
    let obj = implement(iidFirst, FirstVtbl(first: readState),
                        state = disposedOn.addr, dispose = noteThread)
    let again = query(obj, iidFirst)
    drop(obj)
    check disposedOn == 0             # still held through `again`
    drop(again)
    check disposedOn == getThreadId() # the dispatcher's thread: at once

  test "a release from another thread disposes here, once the dispatcher polls":
    var disposedOn = 0
    let obj = implement(iidFirst, FirstVtbl(first: readState),
                        state = disposedOn.addr, dispose = noteThread)
    let t = createThread(nil, 0, cast[pointer](releaseElsewhere), obj, 0, nil)
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check disposedOn == 0             # posted, not run: that thread did not wait
    poll(10)
    check disposedOn == getThreadId()
