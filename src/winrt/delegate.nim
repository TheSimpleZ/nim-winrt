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
## * **The vtable pointer must be the first field.** The caller receives a
##   pointer to the object and immediately dereferences it as a pointer to a
##   pointer to the table.
##
## * **An event handler must not report failure.** XAML treats a failing
##   HRESULT out of its own event dispatch as fatal and tears the process down,
##   so one bug in one handler would end the application with nothing in the
##   log. See `guarded`.
##
## ## One table, one shape per signature
##
## `Invoke` takes whatever the delegate declares: nothing, an object, a sender
## and arguments, a `SignalNotifier` and a `bool`. Each of those is a different
## C signature, and calling through the wrong one reads an argument out of a
## register that never held it. So the trampoline is generic over the argument
## types and instantiated per delegate signature, and its vtable with it —
## `{.global.}` inside a generic proc is one table per instantiation.
##
## Everything else is shared: the object layout, the refcounting, and the
## table of live handlers below. A closure's environment is GC-managed and the
## COM object is not, so the closure cannot live inside the object; it lives
## here, where the GC can see it, and the object holds its index.

import ./core
include ./abidef

type
  EventProc* = proc(sender, args: pointer) {.closure.}
    ## A WinRT event handler: sender, then event arguments.

  Stored = ref object of RootObj
    ## A handler as the table keeps it. Each argument shape derives from this
    ## and the trampoline for that shape knows which one it holds.
    swallow: bool   ## report S_OK even if the handler raised

  Stored0 = ref object of Stored
    fn: proc() {.closure.}
  Stored1[A] = ref object of Stored
    fn: proc(a: A) {.closure.}
  Stored2[A, B] = ref object of Stored
    fn: proc(a: A, b: B) {.closure.}
  Stored3[A, B, C] = ref object of Stored
    fn: proc(a: A, b: B, c: C) {.closure.}

  Vtbl = object
    ## IUnknown, then Invoke. The type of `invoke` differs per shape, so the
    ## slot is a bare pointer here and each shape's table is built over it.
    queryInterface: proc(self: pointer, riid: ptr GUID,
                         ppv: ptr pointer): HRESULT {.callback.}
    addRef: proc(self: pointer): uint32 {.callback.}
    release: proc(self: pointer): uint32 {.callback.}
    invoke: pointer

  DelegateImpl {.pure.} = object
    ## Manually allocated, because its lifetime belongs to COM and not to Nim.
    vtbl: ptr Vtbl           ## must stay first
    refs: int32
    iid: GUID
    slot: int32              ## index into `handlers`

# An entry is cleared rather than removed, because a live delegate holds its
# index. The index then goes on a free list and is handed to the next delegate,
# which is what stops a long-running app from growing one dead slot per
# subscription — a tray app that re-subscribes on every device change would
# otherwise never stop growing. Reuse is safe precisely because a slot is only
# freed when the delegate holding it has been destroyed.
var
  handlers: seq[Stored] = @[]
  freeSlots: seq[int32] = @[]

proc takeSlot(handler: Stored): int32 =
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

proc handlerAt(self: pointer): Stored =
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

proc addRef(self: pointer): uint32 {.callback.} =
  let d = cast[ptr DelegateImpl](self)
  d.refs.inc
  uint32(d.refs)

proc release(self: pointer): uint32 {.callback.} =
  let d = cast[ptr DelegateImpl](self)
  d.refs.dec
  if d.refs <= 0:
    # Drop the closure first: after `deallocShared` the slot index is gone.
    dropSlot(d.slot)
    deallocShared(d)
    return 0
  uint32(d.refs)

proc queryInterface(self: pointer, riid: ptr GUID,
                    ppv: ptr pointer): HRESULT {.callback.} =
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

template guarded(self: pointer, body: untyped): HRESULT =
  ## Run the handler and decide what to tell the runtime.
  ##
  ## A handler that raises is contained and reported either way. Whether the
  ## call then *fails* depends on who is asking. A method that took a callback
  ## — the application's initialization, a work item — is entitled to hear that
  ## it did not run. An event source is not: a failing HRESULT out of XAML's
  ## own event dispatch tears the process down, and the event has been
  ## delivered either way, so those report success regardless.
  let stored {.inject.} = handlerAt(self)
  if stored.isNil:
    E_FAIL
  else:
    var hr = S_OK
    try:
      body
    except CatchableError as e:
      report("handler", e.msg)
      if not stored.swallow: hr = E_FAIL
    except Exception as e:
      report("handler (defect)", e.msg)
      if not stored.swallow: hr = E_FAIL
    hr

proc invoke0(self: pointer): HRESULT {.callback.} =
  guarded(self): Stored0(stored).fn()

proc invoke1[A](self: pointer, a: A): HRESULT {.callback.} =
  guarded(self): Stored1[A](stored).fn(a)

proc invoke2[A, B](self: pointer, a: A, b: B): HRESULT {.callback.} =
  guarded(self): Stored2[A, B](stored).fn(a, b)

proc invoke3[A, B, C](self: pointer, a: A, b: B, c: C): HRESULT {.callback.} =
  guarded(self): Stored3[A, B, C](stored).fn(a, b, c)

proc make(iid: GUID, handler: Stored, vtbl: ptr Vtbl): pointer =
  let d = cast[ptr DelegateImpl](allocShared0(sizeof(DelegateImpl)))
  d.vtbl = vtbl
  d.refs = 1
  d.iid = iid
  d.slot = takeSlot(handler)
  cast[pointer](d)

# Each constructor returns a delegate with a refcount of 1. Hand it to the
# method or `add_Xxx` that wanted it, which takes its own reference, and
# release yours; the object frees itself when the runtime lets go, which may
# be after the call returns.
#
# `A`, `B` and `C` are the types `Invoke` is declared with *at the ABI* — a
# `pointer` for an object, an `HSTRING` for a string, a `bool`, an enum, a
# struct by value. The generated wrappers build a closure of that shape around
# the one the caller wrote.

proc newDelegate*(iid: GUID, handler: proc() {.closure.}): pointer =
  ## A delegate whose `Invoke` takes no arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release, invoke: cast[pointer](invoke0))
  make(iid, Stored0(fn: handler), vtbl.addr)

proc newDelegate*[A](iid: GUID, handler: proc(a: A) {.closure.}): pointer =
  ## A delegate whose `Invoke` takes one argument.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release,
                             invoke: cast[pointer](invoke1[A]))
  make(iid, Stored1[A](fn: handler), vtbl.addr)

proc newDelegate*[A, B](iid: GUID,
                        handler: proc(a: A, b: B) {.closure.}): pointer =
  ## A delegate whose `Invoke` takes two arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release,
                             invoke: cast[pointer](invoke2[A, B]))
  make(iid, Stored2[A, B](fn: handler), vtbl.addr)

proc newDelegate*[A, B, C](iid: GUID,
                           handler: proc(a: A, b: B, c: C) {.closure.}): pointer =
  ## A delegate whose `Invoke` takes three arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release,
                             invoke: cast[pointer](invoke3[A, B, C]))
  make(iid, Stored3[A, B, C](fn: handler), vtbl.addr)

proc newEventDelegate*(iid: GUID, handler: EventProc): pointer =
  ## A delegate for a WinRT *event*: sender and arguments, and a handler that
  ## raises is reported but never fails the event.
  doAssert not handler.isNil, "winrt: event handler must not be nil"
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release,
                             invoke: cast[pointer](invoke2[pointer, pointer]))
  make(iid, Stored2[pointer, pointer](fn: handler, swallow: true), vtbl.addr)

proc delegateTableSizes*(): tuple[slots, free: int] =
  ## Diagnostic: how many slots the handler table holds, and how many of those
  ## are free for reuse. `tests/tdelegate.nim` asserts the first number stops
  ## growing; without the free list it would grow by one per subscription for
  ## the life of the process.
  (handlers.len, freeSlots.len)
