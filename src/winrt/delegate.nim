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
## ## The thread it arrives on
##
## The runtime invokes a delegate on whatever thread suits it: a thread-pool
## work item runs on the pool, a device watcher reports from one of its own.
## That thread is not a Nim thread, and under ORC that rules one thing out
## entirely: touching a reference count. Copying a `ref` — even the implicit
## copy in `let h = handlers[i]` — registers the object as a possible cycle
## root in a per-thread list that only a Nim-started thread has initialised,
## and a foreign thread crashes on the spot.
##
## Nor may it allocate: Nim's allocator keeps its state per thread, and on a
## thread it did not set up the first allocation is a crash. Every object
## here lives on the COM heap instead — see `comAlloc` in `core`.
##
## So the path from `Invoke` to the closure holds no `ref` and allocates
## nothing. The COM object carries the closure's *address*; the closure itself
## is a plain object the `handlers` table below keeps alive, and the trampoline
## reads it through a `ptr` and calls it through a `{.cursor.}`. `Release` on
## a foreign thread has the same problem the other way — dropping the table's
## reference is a count — so a released delegate is only *retired*, pushed
## onto a lock-free list threaded through the objects themselves, and the
## table lets go of its closure the next time it is touched from the main
## thread.
##
## What the handler itself does is the caller's business, and the same rules
## apply to it: a handler that may run on a runtime thread must not allocate
## or touch GC memory there. Signal the main thread and do the work there —
## `asyncops` shows the pattern with an `AsyncEvent`.

import std/atomics
import ./core
include ./abidef

type
  HandlerObj = object of RootObj
    ## A handler as the table keeps it. Each argument shape derives from this
    ## and the trampoline for that shape knows which one it holds.
    swallow: bool   ## report S_OK even if the handler raised

  Handler = ref HandlerObj
  Handler0Obj = object of HandlerObj
    fn: proc() {.closure.}
  Handler1Obj[A] = object of HandlerObj
    fn: proc(a: A) {.closure.}
  Handler2Obj[A, B] = object of HandlerObj
    fn: proc(a: A, b: B) {.closure.}
  Handler3Obj[A, B, C] = object of HandlerObj
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
    ## On the COM heap, because its lifetime belongs to COM and not to Nim.
    vtbl: ptr Vtbl           ## must stay first
    refs: int32
    iid: GUID
    handler: pointer         ## the `HandlerObj`, by address — see above
    slot: int32              ## its index in `handlers`
    next: ptr DelegateImpl   ## the retired list, once released

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
  handlers: seq[Handler] = @[]
  freeSlots: seq[int32] = @[]
  retired: Atomic[ptr DelegateImpl]

proc retire(d: ptr DelegateImpl) =
  ## Push a released delegate onto the retired list: a compare-and-swap and
  ## nothing else, so it is safe from any thread.
  d.next = retired.load(moAcquire)
  while not retired.compareExchange(d.next, d, moAcquireRelease, moAcquire):
    discard   # `d.next` now holds the current head; try again

proc drain() =
  ## Let go of every retired delegate and its handler. Main thread only, like
  ## the table.
  var d = retired.exchange(nil, moAcquireRelease)
  while not d.isNil:
    handlers[d.slot] = nil
    freeSlots.add d.slot
    let next = d.next
    comFree(d)
    d = next

proc takeSlot(handler: Handler): int32 =
  drain()
  if freeSlots.len > 0:
    result = freeSlots.pop()
    handlers[result] = handler
  else:
    handlers.add handler
    result = int32(handlers.len - 1)

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
    retire(d)
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
  let stored {.inject.} =
    cast[ptr HandlerObj](cast[ptr DelegateImpl](self).handler)
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

# Each trampoline reads its closure through a `ptr` and a `{.cursor.}`: no
# reference is copied, which is what makes it safe on a thread Nim did not
# start.

proc invoke0(self: pointer): HRESULT {.callback.} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler0Obj](stored).fn
    fn()

proc invoke1[A](self: pointer, a: A): HRESULT {.callback.} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler1Obj[A]](stored).fn
    fn(a)

proc invoke2[A, B](self: pointer, a: A, b: B): HRESULT {.callback.} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler2Obj[A, B]](stored).fn
    fn(a, b)

proc invoke3[A, B, C](self: pointer, a: A, b: B, c: C): HRESULT {.callback.} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler3Obj[A, B, C]](stored).fn
    fn(a, b, c)

proc make(iid: GUID, handler: Handler, vtbl: ptr Vtbl): pointer =
  let d = cast[ptr DelegateImpl](comAlloc(sizeof(DelegateImpl)))
  d.vtbl = vtbl
  d.refs = 1
  d.iid = iid
  d.handler = cast[pointer](handler)
  d.slot = takeSlot(handler)
  cast[pointer](d)

template vtable(entry: untyped): ptr Vtbl =
  ## One table per instantiation, which is what `{.global.}` inside a generic
  ## means; `queryInterface`, `addRef` and `release` are the same for all.
  var vtbl {.global.} = Vtbl(queryInterface: queryInterface, addRef: addRef,
                             release: release, invoke: cast[pointer](entry))
  vtbl.addr

# Each constructor returns a delegate with a refcount of 1. Hand it to the
# method or `add_Xxx` that wanted it, which takes its own reference, and
# release yours; the object frees itself when the runtime lets go, which may
# be after the call returns.
#
# `A`, `B` and `C` are the types `Invoke` is declared with *at the ABI* — a
# `pointer` for an object, an `HSTRING` for a string, a `bool`, an enum, a
# struct by value. The generated wrappers build a closure of that shape around
# the one the caller wrote.
#
# `event` is the difference between a callback and an event handler: a
# handler that raises is reported either way, but only a callback's failure is
# reported *to the runtime* — see `guarded`.

proc newDelegate*(iid: GUID, handler: proc() {.closure.},
                  event = false): pointer =
  ## A delegate whose `Invoke` takes no arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler0Obj)(fn: handler, swallow: event)), vtable(invoke0))

proc newDelegate*[A](iid: GUID, handler: proc(a: A) {.closure.},
                     event = false): pointer =
  ## A delegate whose `Invoke` takes one argument.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler1Obj[A])(fn: handler, swallow: event)),
       vtable(invoke1[A]))

proc newDelegate*[A, B](iid: GUID, handler: proc(a: A, b: B) {.closure.},
                        event = false): pointer =
  ## A delegate whose `Invoke` takes two arguments — every event handler.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler2Obj[A, B])(fn: handler, swallow: event)),
       vtable(invoke2[A, B]))

proc newDelegate*[A, B, C](iid: GUID,
                           handler: proc(a: A, b: B, c: C) {.closure.},
                           event = false): pointer =
  ## A delegate whose `Invoke` takes three arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler3Obj[A, B, C])(fn: handler, swallow: event)),
       vtable(invoke3[A, B, C]))

proc delegateTableSizes*(): tuple[slots, free: int] =
  ## Diagnostic: how many slots the handler table holds, and how many of those
  ## are free for reuse. `tests/tdelegate.nim` asserts the first number stops
  ## growing; without the free list it would grow by one per subscription for
  ## the life of the process. Retired slots are collected first, so the answer
  ## is current.
  drain()
  (handlers.len, freeSlots.len)
