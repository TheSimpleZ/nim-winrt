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

# Three interfaces of our own, each declared the way the generated ABI
# declares one: the IID beside the vtable, which is where `implement` reads
# it from.
const
  IID_Raw = guid"11111111-0000-0000-0000-000000000003"
  IID_First = guid"11111111-0000-0000-0000-000000000001"
  IID_Second = guid"11111111-0000-0000-0000-000000000002"
  iidOther = guid"11111111-0000-0000-0000-00000000000F"

type
  RawVtbl = object of IUnknownVtbl        ## the shape of `IBufferByteAccess`
    read: proc(self: pointer, value: ptr int32): HRESULT {.abi.}
  FirstVtbl = object of IInspectableVtbl  ## the shape of a WinRT interface
    read: proc(self: pointer, value: ptr int32): HRESULT {.abi.}
  SecondVtbl = object of IInspectableVtbl
    read: proc(self: pointer, value: ptr int32): HRESULT {.abi.}

proc readState(self: pointer, value: ptr int32): HRESULT {.abi.} =
  ## The one method every table here carries: the state, through `self`.
  value[] = cast[ptr int32](stateOf(self))[]
  S_OK

proc unknown(obj: pointer): ptr IUnknownVtbl =
  ## What a COM caller does first: the object *is* a pointer to its table.
  cast[ptr ptr IUnknownVtbl](obj)[]

proc inspectable(obj: pointer): ptr IInspectableVtbl =
  cast[ptr ptr IInspectableVtbl](obj)[]

proc ask(obj: pointer, iid: GUID): pointer =
  var want = iid
  discard unknown(obj).queryInterface(obj, want.addr, result.addr)

proc drop(obj: pointer): uint32 {.discardable.} =
  unknown(obj).release(obj)

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
    let obj = implement(FirstVtbl(read: readState), SecondVtbl(read: readState),
                        RawVtbl(read: readState), state = state.addr)
    defer: release(obj)
    let second = ask(obj, IID_Second)
    let raw = ask(obj, IID_Raw)
    check second != nil
    check raw != nil
    check second != obj                # a different vtable pointer each
    check raw != second

    var v: int32
    check cast[ptr ptr FirstVtbl](obj)[].read(obj, v.addr) == S_OK
    check v == 42
    v = 0
    check cast[ptr ptr SecondVtbl](second)[].read(second, v.addr) == S_OK
    check v == 42
    v = 0
    check cast[ptr ptr RawVtbl](raw)[].read(raw, v.addr) == S_OK
    check v == 42

    # One count for the whole object, whichever pointer it is counted through.
    check drop(raw) == 2
    check drop(second) == 1

  test "QueryInterface answers for what was implemented and the three basics":
    let obj = implement(RawVtbl(read: readState), FirstVtbl(read: readState))
    defer: release(obj)
    check ask(obj, IID_IUnknown) == obj
    check ask(obj, IID_IAgileObject) == obj
    # IInspectable is the first interface that *is* one — not the first slot.
    let first = ask(obj, IID_First)
    check ask(obj, IID_IInspectable) == first
    check ask(obj, iidOther) == nil
    for i in 1 .. 4: drop(obj)

  test "an object of COM interfaces only is not an IInspectable":
    let obj = implement(RawVtbl(read: readState))
    defer: release(obj)
    check ask(obj, IID_IInspectable) == nil
    check ask(obj, IID_IUnknown) == obj
    drop(obj)

  test "GetIids lists the WinRT interfaces and leaves out the COM ones":
    let obj = implement(RawVtbl(read: readState), FirstVtbl(read: readState),
                        SecondVtbl(read: readState))
    defer: release(obj)
    let first = ask(obj, IID_First)
    var count: uint32
    var iids: ptr GUID
    check inspectable(first).getIids(first, count.addr, iids.addr) == S_OK
    check count == 2
    let listed = cast[ptr UncheckedArray[GUID]](iids)
    check listed[0] == IID_First
    check listed[1] == IID_Second
    comFree(iids)
    drop(first)

  test "the state is disposed of with the last reference, on this thread":
    var disposedOn = 0
    let obj = implement(FirstVtbl(read: readState),
                        state = disposedOn.addr, dispose = noteThread)
    let again = ask(obj, IID_First)
    drop(obj)
    check disposedOn == 0             # still held through `again`
    drop(again)
    check disposedOn == getThreadId() # the dispatcher's thread: at once

  test "a release from another thread disposes here, once the dispatcher polls":
    var disposedOn = 0
    let obj = implement(FirstVtbl(read: readState),
                        state = disposedOn.addr, dispose = noteThread)
    let t = createThread(nil, 0, cast[pointer](releaseElsewhere), obj, 0, nil)
    discard waitForSingleObject(t, 5000)
    discard closeHandle(t)
    check disposedOn == 0             # posted, not run: that thread did not wait
    poll(10)
    check disposedOn == getThreadId()
