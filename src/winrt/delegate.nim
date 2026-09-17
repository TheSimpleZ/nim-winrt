## Implementing COM objects that the Windows Runtime calls back into.
##
## Everything else in this library is Nim calling WinRT. This is the other
## direction: the runtime needs objects it can invoke — the application's start
## callback, and every event handler — and those have to be real COM objects
## with a real vtable.
##
## Three details are easy to get wrong and fatal when you do:
##
## * **A WinRT delegate derives from `IUnknown`, not `IInspectable`.** Its
##   vtable is four slots — QueryInterface, AddRef, Release, Invoke — with no
##   `GetRuntimeClassName`. Assuming the usual six puts `Invoke` at slot 6 and
##   calls into whatever happens to follow the table.
##
## * **The vtable pointer must be the first field.** The caller receives a pointer
##   to the object and immediately dereferences it as a pointer to a pointer to
##   the table.
##
## * **An event handler must not report failure.** XAML treats a failing
##   HRESULT out of its own event dispatch as fatal and tears the process down,
##   so one bug in one handler would end the application with nothing in the
##   log. See `eventInvoke`.
##
## ## One table, two shapes
##
## A WinRT delegate's `Invoke` takes either one argument or two — an event
## handler gets a sender and event arguments — and those are different vtable
## layouts that cannot be interchanged. On x64 the extra argument rides in a
## register, so calling through the wrong shape happens to survive, which is
## worse than failing: it works until the day it does not.
##
## So there are two `Invoke` trampolines and two vtables, and *everything else*
## is shared. Handlers are normalised to two parameters on the way in, with the
## one-argument kind ignoring the second. That matters because the bookkeeping
## below — the slot table, the free list, the refcounting — was previously
## written twice, and a fix to one copy is a fix missing from the other.

import ./core

type
  DelegateProc* = proc(args: pointer) {.closure.}
    ## A delegate whose `Invoke` takes one argument.

  EventProc* = proc(sender, args: pointer) {.closure.}
    ## A WinRT event handler: sender, then event arguments.

  StoredProc = proc(a, b: pointer) {.closure.}
    ## How both kinds are kept. A `DelegateProc` is wrapped to ignore `b`.

  DelegateVtbl {.pure.} = object
    queryInterface: proc(self: pointer, riid: ptr GUID,
                         ppv: ptr pointer): HRESULT {.stdcall.}
    addRef: proc(self: pointer): uint32 {.stdcall.}
    release: proc(self: pointer): uint32 {.stdcall.}
    invoke: proc(self: pointer, args: pointer): HRESULT {.stdcall.}

  EventVtbl {.pure.} = object
    queryInterface: proc(self: pointer, riid: ptr GUID,
                         ppv: ptr pointer): HRESULT {.stdcall.}
    addRef: proc(self: pointer): uint32 {.stdcall.}
    release: proc(self: pointer): uint32 {.stdcall.}
    invoke: proc(self: pointer, sender, args: pointer): HRESULT {.stdcall.}

  DelegateImpl {.pure.} = object
    ## Manually allocated, because its lifetime belongs to COM and not to Nim.
    vtbl: ptr DelegateVtbl   ## must stay first
    refs: int32
    iid: GUID
    slot: int32              ## index into `handlers`

const
  IID_IUnknown* = GUID(
    data1: 0x00000000'u32, data2: 0'u16, data3: 0'u16,
    data4: [0xC0'u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])

# Handlers live here so the GC can see them: a closure's environment is
# GC-managed and the COM object is not, so burying one inside the other gives a
# callback into freed memory some minutes after it starts working.
#
# An entry is cleared rather than removed, because a live delegate holds its
# index. The index then goes on a free list and is handed to the next delegate,
# which is what stops a long-running app from growing one dead slot per
# subscription — a tray app that re-subscribes on every device change would
# otherwise never stop growing. Reuse is safe precisely because a slot is only
# freed when the delegate holding it has been destroyed.
var
  handlers: seq[StoredProc] = @[]
  freeSlots: seq[int32] = @[]

proc takeSlot(handler: StoredProc): int32 =
  if freeSlots.len > 0:
    result = freeSlots.pop()
    handlers[result] = handler
  else:
    handlers.add handler
    result = int32(handlers.len - 1)

proc dropSlot(slot: int32) =
  if slot >= 0 and slot < handlers.len.int32 and not handlers[slot].isNil:
    handlers[slot] = nil
    freeSlots.add slot

proc handlerAt(self: pointer): StoredProc =
  let d = cast[ptr DelegateImpl](self)
  if d.slot < 0 or d.slot >= handlers.len.int32: nil
  else: handlers[d.slot]

proc report(what, msg: string) =
  ## Say what happened, and make sure it is actually seen.
  ##
  ## stderr is block-buffered once redirected to a file, so a message written
  ## just before the process dies is lost — which is precisely the case anyone
  ## reading this message is investigating.
  try:
    stderr.writeLine "winrt: " & what & " raised: " & msg
    stderr.flushFile()
  except CatchableError:
    discard

# ------------------------------------------------------------- IUnknown

proc addRef(self: pointer): uint32 {.stdcall.} =
  let d = cast[ptr DelegateImpl](self)
  d.refs.inc
  uint32(d.refs)

proc release(self: pointer): uint32 {.stdcall.} =
  let d = cast[ptr DelegateImpl](self)
  d.refs.dec
  if d.refs <= 0:
    # Drop the closure first: after `deallocShared` the slot index is gone.
    dropSlot(d.slot)
    deallocShared(d)
    return 0
  uint32(d.refs)

proc queryInterface(self: pointer, riid: ptr GUID,
                    ppv: ptr pointer): HRESULT {.stdcall.} =
  if ppv.isNil:
    return E_POINTER
  let d = cast[ptr DelegateImpl](self)
  # A delegate answers for IUnknown and for its own IID, and nothing else.
  if riid[] == IID_IUnknown or riid[] == d.iid:
    ppv[] = self
    discard addRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

# --------------------------------------------------------------- Invoke

proc plainInvoke(self: pointer, args: pointer): HRESULT {.stdcall.} =
  ## The one-argument shape, used for lifecycle callbacks.
  ##
  ## This one *does* report failure, unlike `eventInvoke`: if the application's
  ## initialization callback cannot do its job there is nothing to carry on
  ## with, and `Application.Start` should say so.
  let handler = handlerAt(self)
  if handler.isNil:
    return E_FAIL
  try:
    handler(args, nil)
    S_OK
  except CatchableError as e:
    report("handler", e.msg)
    E_FAIL
  except Exception as e:
    report("handler (defect)", e.msg)
    E_FAIL

proc eventInvoke(self: pointer, sender, args: pointer): HRESULT {.stdcall.} =
  ## The two-argument shape, and it always returns S_OK.
  ##
  ## A failing HRESULT out of an event handler is not a neutral way to report a
  ## problem: XAML treats a failure returned from its own event dispatch as
  ## fatal and tears the application down, so one bug in one handler ends the
  ## process with nothing in the log. There is nothing useful the runtime could do
  ## with the failure in any case — the event has been delivered either way. So
  ## the exception is contained, reported, and the event reported as handled.
  let handler = handlerAt(self)
  if handler.isNil:
    return S_OK
  try:
    handler(sender, args)
  except CatchableError as e:
    report("event handler", e.msg)
  except Exception as e:
    report("event handler (defect)", e.msg)
  S_OK

# One vtable per shape, shared by every delegate of that shape: the tables are
# identical and only the object's IID and slot differ. That also keeps the
# number of distinct trampolines constant however many delegates exist.
var plainVtbl = DelegateVtbl(
  queryInterface: queryInterface, addRef: addRef, release: release,
  invoke: plainInvoke)

var eventVtbl = EventVtbl(
  queryInterface: queryInterface, addRef: addRef, release: release,
  invoke: eventInvoke)

proc make(iid: GUID, handler: StoredProc, vtbl: pointer): pointer =
  let d = cast[ptr DelegateImpl](allocShared0(sizeof(DelegateImpl)))
  d.vtbl = cast[ptr DelegateVtbl](vtbl)
  d.refs = 1
  d.iid = iid
  d.slot = takeSlot(handler)
  cast[pointer](d)

proc newEventDelegate*(iid: GUID, handler: EventProc): pointer =
  ## A COM delegate for a WinRT *event*, whose `Invoke` takes a sender and
  ## event arguments.
  ##
  ## Returned with a refcount of 1. Hand it to `add_Xxx`, which AddRefs it, and
  ## release your own reference; the object frees itself when the event source
  ## lets go.
  doAssert not handler.isNil, "winrt: event handler must not be nil"
  make(iid, handler, eventVtbl.addr)

proc newDelegate*(iid: GUID, handler: DelegateProc): pointer =
  ## A COM delegate whose `Invoke` takes a single argument.
  ##
  ## Returned with a refcount of 1, like `newEventDelegate`.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, proc(a, b: pointer) = handler(a), plainVtbl.addr)

proc delegateTableSizes*(): tuple[slots, free: int] =
  ## Diagnostic: how many slots the handler table holds, and how many of those
  ## are free for reuse. `tests/tdelegate.nim` asserts the first number stops
  ## growing; without the free list it would grow by one per subscription for
  ## the life of the process.
  (handlers.len, freeSlots.len)
