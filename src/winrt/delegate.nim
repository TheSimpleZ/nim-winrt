## Implementing the delegates the Windows Runtime calls back into.
##
## Everything else in this library is Nim calling WinRT. This is the other
## direction: the runtime needs objects it can invoke — every event handler,
## every callback a method takes — and those have to be real COM objects with
## a real vtable.
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
## ## Handlers run on the dispatcher thread
##
## The runtime invokes a delegate on whatever thread suits it: a thread-pool
## work item runs on the pool, a device watcher reports from one of its own.
## That thread is not a Nim thread, and Nim's memory management is not
## prepared for it: copying a `ref` or allocating anything there crashes the
## process, which rules out `echo`, string building and most handlers anyone
## would write.
##
## So a handler runs on the thread that runs `asyncdispatch` — the one that
## created the delegate — and the runtime's thread waits for it. The
## trampoline notices it is elsewhere, describes the call in a `Job` on its own
## stack, pushes that onto a lock-free list, wakes the dispatcher and blocks on
## an event; the dispatcher runs the handler and signals. Nothing on the
## foreign thread touches Nim memory. What it costs is that the dispatcher must
## be running — `waitFor`, `runForever` or `poll` — for a handler from another
## thread to run at all, and a handler is delivered when the dispatcher gets to
## it rather than the instant the runtime raised it.
##
## A handler that genuinely wants the runtime's thread — a work item meant to
## run in parallel — asks for `raw = true` and takes on the rule above: no GC
## memory there.
##
## ## What the object holds
##
## Nothing GC-managed. The closure's environment is GC memory and the COM
## object is not, so burying one inside the other gives a callback into freed
## memory some minutes after it starts working; the closure lives in the
## `handlers` table below, where the GC can see it, and the object carries its
## address and its index. The object itself is on the COM heap, because the
## runtime may release it from any thread, and a release from a foreign thread
## only *retires* it — onto a lock-free list threaded through the objects — for
## the dispatcher thread to let go of the closure the next time it is touched.

import std/[asyncdispatch, atomics]
import ./core
include ./abidef

export asyncdispatch

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
    raw: bool                ## run where invoked, whatever thread that is
    iid: GUID
    handler: pointer         ## the `HandlerObj`, by address — see above
    slot: int32              ## its index in `handlers`
    next: ptr DelegateImpl   ## the retired list, once released

  Job {.pure.} = object
    ## One invocation carried to the dispatcher thread: how to run it, on
    ## which delegate, and the event that says it has been.
    run: proc(job: ptr Job): HRESULT {.nimcall, raises: [].}
    delegate: pointer
    done: pointer            ## a Win32 event the poster waits on
    hr: HRESULT
    next: ptr Job

  Job1[A] {.pure.} = object
    base: Job
    a: A
  Job2[A, B] {.pure.} = object
    base: Job
    a: A
    b: B
  Job3[A, B, C] {.pure.} = object
    base: Job
    a: A
    b: B
    c: C

# ---------------------------------------------------------------- the table

# An entry is cleared rather than removed, because a live delegate holds its
# index. The index then goes on a free list and is handed to the next delegate,
# which is what stops a long-running app from growing one dead slot per
# subscription. Reuse is safe precisely because a slot is only freed when the
# delegate holding it has been destroyed.
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
  ## Let go of every retired delegate and its handler. Dispatcher thread only,
  ## like the table.
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

# ----------------------------------------------------------- the dispatcher

proc createEventW(attributes: pointer, manualReset, initialState: int32,
                  name: pointer): pointer
  {.importc: "CreateEventW", stdcall, dynlib: "kernel32", raises: [], gcsafe.}
proc setEvent(h: pointer): int32
  {.importc: "SetEvent", stdcall, dynlib: "kernel32", raises: [], gcsafe.}
proc waitForSingleObject(h: pointer, ms: uint32): uint32
  {.importc: "WaitForSingleObject", stdcall, dynlib: "kernel32", raises: [], gcsafe.}
proc closeHandle(h: pointer): int32
  {.importc: "CloseHandle", stdcall, dynlib: "kernel32", raises: [], gcsafe.}

var
  pending: Atomic[ptr Job]   ## jobs posted from other threads, newest first
  wakeup: AsyncEvent          ## what a poster triggers
  dispatcherThread: int       ## the thread that created the first delegate

proc runPending(fd: AsyncFD): bool {.gcsafe.} =
  ## Run every posted job, oldest first, and release each poster.
  var job = pending.exchange(nil, moAcquireRelease)
  var ordered: ptr Job = nil
  while not job.isNil:
    let next = job.next
    job.next = ordered
    ordered = job
    job = next
  while not ordered.isNil:
    # Read `next` before signalling: the job lives on the poster's stack, and
    # the poster is free to return the moment the event is set.
    let next = ordered.next
    # The handler is a closure and touches GC memory; that is fine *here*, on
    # the dispatcher thread, which is the whole arrangement — but the compiler
    # cannot see through a proc pointer to know it.
    {.cast(gcsafe).}:
      ordered.hr = ordered.run(ordered)
    discard setEvent(ordered.done)
    ordered = next
  false   # stay registered

proc ensureDispatcher() =
  ## The first delegate decides which thread handlers run on.
  if wakeup.isNil:
    wakeup = newAsyncEvent()
    addEvent(wakeup, runPending)
    dispatcherThread = getThreadId()

proc carry(job: ptr Job): HRESULT =
  ## From a thread that is not the dispatcher's: hand the job over and wait.
  job.done = createEventW(nil, 1, 0, nil)
  job.next = pending.load(moAcquire)
  while not pending.compareExchange(job.next, job, moAcquireRelease, moAcquire):
    discard
  try:
    trigger(wakeup)
  except CatchableError:
    discard
  discard waitForSingleObject(job.done, 0xFFFFFFFF'u32)
  discard closeHandle(job.done)
  job.hr

proc runsHere(self: pointer): bool {.inline.} =
  cast[ptr DelegateImpl](self).raw or getThreadId() == dispatcherThread

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
  ## — a work item, the application's initialization — is entitled to hear that
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

# Each `run` reads its closure through a `ptr` and a `{.cursor.}`: no
# reference is copied, so it is safe on the dispatcher thread whatever else is
# going on, and safe on a raw thread as long as the handler itself is.

proc run0(self: pointer): HRESULT {.raises: [].} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler0Obj](stored).fn
    fn()

proc run1[A](self: pointer, a: A): HRESULT {.raises: [].} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler1Obj[A]](stored).fn
    fn(a)

proc run2[A, B](self: pointer, a: A, b: B): HRESULT {.raises: [].} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler2Obj[A, B]](stored).fn
    fn(a, b)

proc run3[A, B, C](self: pointer, a: A, b: B, c: C): HRESULT {.raises: [].} =
  guarded(self):
    let fn {.cursor.} = cast[ptr Handler3Obj[A, B, C]](stored).fn
    fn(a, b, c)

# The same four, as a job the dispatcher runs.

proc job0(job: ptr Job): HRESULT {.nimcall, raises: [].} =
  run0(job.delegate)

proc job1[A](job: ptr Job): HRESULT {.nimcall, raises: [].} =
  let j = cast[ptr Job1[A]](job)
  run1[A](job.delegate, j.a)

proc job2[A, B](job: ptr Job): HRESULT {.nimcall, raises: [].} =
  let j = cast[ptr Job2[A, B]](job)
  run2[A, B](job.delegate, j.a, j.b)

proc job3[A, B, C](job: ptr Job): HRESULT {.nimcall, raises: [].} =
  let j = cast[ptr Job3[A, B, C]](job)
  run3[A, B, C](job.delegate, j.a, j.b, j.c)

# What the runtime calls. On the dispatcher thread, or for a raw delegate,
# straight through; from anywhere else, described on this thread's stack and
# carried over.

proc invoke0(self: pointer): HRESULT {.callback.} =
  if runsHere(self): return run0(self)
  var job = Job(run: job0, delegate: self)
  carry(job.addr)

proc invoke1[A](self: pointer, a: A): HRESULT {.callback.} =
  if runsHere(self): return run1[A](self, a)
  var job = Job1[A](base: Job(run: job1[A], delegate: self), a: a)
  carry(job.base.addr)

proc invoke2[A, B](self: pointer, a: A, b: B): HRESULT {.callback.} =
  if runsHere(self): return run2[A, B](self, a, b)
  var job = Job2[A, B](base: Job(run: job2[A, B], delegate: self), a: a, b: b)
  carry(job.base.addr)

proc invoke3[A, B, C](self: pointer, a: A, b: B, c: C): HRESULT {.callback.} =
  if runsHere(self): return run3[A, B, C](self, a, b, c)
  var job = Job3[A, B, C](base: Job(run: job3[A, B, C], delegate: self),
                          a: a, b: b, c: c)
  carry(job.base.addr)

# ----------------------------------------------------------- constructors

proc make(iid: GUID, handler: Handler, vtbl: ptr Vtbl, raw: bool): pointer =
  ensureDispatcher()
  let d = cast[ptr DelegateImpl](comAlloc(sizeof(DelegateImpl)))
  d.vtbl = vtbl
  d.refs = 1
  d.raw = raw
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
# reported *to the runtime* — see `guarded`. `raw` runs the handler on
# whatever thread the runtime invokes it from, instead of the dispatcher's.

proc newDelegate*(iid: GUID, handler: proc() {.closure.},
                  event = false, raw = false): pointer =
  ## A delegate whose `Invoke` takes no arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler0Obj)(fn: handler, swallow: event)),
       vtable(invoke0), raw)

proc newDelegate*[A](iid: GUID, handler: proc(a: A) {.closure.},
                     event = false, raw = false): pointer =
  ## A delegate whose `Invoke` takes one argument.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler1Obj[A])(fn: handler, swallow: event)),
       vtable(invoke1[A]), raw)

proc newDelegate*[A, B](iid: GUID, handler: proc(a: A, b: B) {.closure.},
                        event = false, raw = false): pointer =
  ## A delegate whose `Invoke` takes two arguments — every event handler.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler2Obj[A, B])(fn: handler, swallow: event)),
       vtable(invoke2[A, B]), raw)

proc newDelegate*[A, B, C](iid: GUID,
                           handler: proc(a: A, b: B, c: C) {.closure.},
                           event = false, raw = false): pointer =
  ## A delegate whose `Invoke` takes three arguments.
  doAssert not handler.isNil, "winrt: delegate handler must not be nil"
  make(iid, Handler((ref Handler3Obj[A, B, C])(fn: handler, swallow: event)),
       vtable(invoke3[A, B, C]), raw)

proc delegateTableSizes*(): tuple[slots, free: int] =
  ## Diagnostic: how many slots the handler table holds, and how many of those
  ## are free for reuse. `tests/tdelegate.nim` asserts the first number stops
  ## growing; without the free list it would grow by one per subscription for
  ## the life of the process. Retired slots are collected first, so the answer
  ## is current.
  drain()
  (handlers.len, freeSlots.len)
