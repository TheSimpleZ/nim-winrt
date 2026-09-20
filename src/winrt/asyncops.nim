## Waiting for WinRT asynchronous operations.
##
## A WinRT method that does anything slow does not return a result. It returns
## an `IAsyncOperation<T>` — an object carrying the state of work already in
## progress — and the result is read out of that once it finishes.
##
## Here that becomes an ordinary Nim `Future`, so the generated wrappers
## compose with everything else in `std/asyncdispatch`:
##
## ```nim
## let adc = waitFor AdcController.getDefaultAsync()
## ```
##
## or `await` inside an async proc. There is deliberately no separate blocking
## spelling: `waitFor` is already that.
##
## Two more things the operation can do come along. `cancel(fut)` asks it to
## stop, after which the Future fails with a `CancelledError` — if the
## operation honours the request; one may finish first, or ignore it. And a
## `WithProgress` operation reports as it goes to the `progress` closure its
## wrapper takes as a last argument.
##
## ## How the Future is completed
##
## By the operation's own completion handler, which is what they are for. Two
## details make that safe, and both are easy to get wrong:
##
## * **The handler object must be agile.** WinRT raises completion on a thread
##   pool thread. If the handler is not agile, COM marshals the call back to
##   the apartment that registered it — and a single-threaded apartment sitting
##   inside `waitFor` is blocked in `poll`, which waits on an I/O completion
##   port and does not pump COM messages. The call would never arrive.
##   `Completion` below answers `QueryInterface` for `IAgileObject`, so the
##   runtime invokes it directly on the completing thread instead.
##
## * **That thread must not touch the dispatcher.** `asyncdispatch` is
##   single-threaded, so completing a `Future` from the thread pool is a data
##   race. The handler therefore does exactly one thing: `trigger` an
##   `AsyncEvent`, which is a `SetEvent` on a handle and touches no Nim
##   memory. The dispatcher wakes on its own thread and decides everything
##   there.
##
## The handler is its own small COM object rather than a `delegate.nim`
## delegate around a closure because it needs neither a closure nor the
## handler table: the one thing it does fits in a field, and the fewer moving
## parts on a thread Nim did not start, the better. A progress handler *is* an
## ordinary delegate, because it carries a value to a closure of yours.

import std/asyncdispatch
import ./[core, delegate]
include ./abidef

export asyncdispatch

const
  # Not exported, and not named `IID_IAsyncInfo`: the metadata declares that
  # interface too, so `winrt/abi/foundation` has a constant of that name and
  # two in scope is an ambiguity wherever both are imported.
  IidAsyncInfo = guid"00000036-0000-0000-C000-000000000046"

  SlotAsyncInfoStatus = 7
  SlotAsyncInfoErrorCode = 8
  SlotAsyncInfoCancel = 9
  SlotPutProgress = 6        ## on the `WithProgress` pair only

type
  AsyncLayout* = enum
    ## Where `put_Completed` and `GetResults` sit, which depends on whether
    ## the operation reports progress.
    ##
    ## `IAsyncAction` and `IAsyncOperation<T>` declare Completed first, so it
    ## is slot 6 and GetResults is 8. The `WithProgress` pair declare
    ## `put_Progress` and `get_Progress` first, pushing both two slots down.
    ## Calling a progress operation through the plain layout hands the
    ## completion handler to `put_Progress` — which fails, quietly, because
    ## the handler does not answer for the progress delegate's IID.
    alPlain      ## Completed at 6, GetResults at 8
    alProgress   ## Completed at 8, GetResults at 10

  CancelledError* = object of WinRtError
    ## What a Future fails with when the operation behind it was cancelled,
    ## by `cancel` or by Windows. Its `hr` is `E_ABORT`.

  ProgressHandler*[P] = proc(progress: P) {.closure.}
    ## What a `WithProgress` method takes as its last argument: a closure
    ## called with each progress value, on the dispatcher thread.

  AsyncState = enum
    ## Not `AsyncStatus`: `Windows.Foundation.AsyncStatus` is a real enum in the
    ## generated bindings, and two of that name in scope is an ambiguity.
    asStarted = 0, asCompleted = 1, asCanceled = 2, asError = 3

  FnAsyncStatus = proc(self: pointer,
                       status: ptr int32): HRESULT {.abi.}
  FnAsyncError = proc(self: pointer,
                      hr: ptr HRESULT): HRESULT {.abi.}
  FnPutHandler = proc(self: pointer,
                      handler: pointer): HRESULT {.abi.}
  FnNoArgs = proc(self: pointer): HRESULT {.abi.}
  FnResultsPtr = proc(self: pointer,
                      value: ptr pointer): HRESULT {.abi.}
  FnResultsString = proc(self: pointer,
                         value: ptr HSTRING): HRESULT {.abi.}
  FnResultsValue[T] = proc(self: pointer, value: ptr T): HRESULT {.abi.}

  CompletionVtbl {.pure.} = object
    queryInterface: proc(self: pointer, riid: ptr GUID,
                         ppv: ptr pointer): HRESULT {.abi.}
    addRef: proc(self: pointer): uint32 {.abi.}
    release: proc(self: pointer): uint32 {.abi.}
    invoke: proc(self: pointer,
                 info, status: pointer): HRESULT {.abi.}

  Completion {.pure.} = object
    ## On the COM heap on purpose: written by one thread and read by another,
    ## and neither need be one Nim knows about.
    vtbl: ptr CompletionVtbl
    refs: int32
    iid: GUID          ## the parameterised handler IID this answers for
    ev: AsyncEvent

proc completionAddRef(self: pointer): uint32 {.abi.} =
  let c = cast[ptr Completion](self)
  c.refs.inc
  uint32(c.refs)

proc completionRelease(self: pointer): uint32 {.abi.} =
  let c = cast[ptr Completion](self)
  c.refs.dec
  if c.refs <= 0:
    comFree(c)
    return 0
  uint32(c.refs)

proc completionQuery(self: pointer, riid: ptr GUID,
                     ppv: ptr pointer): HRESULT {.abi.} =
  if ppv.isNil: return E_POINTER
  let c = cast[ptr Completion](self)
  if riid[] == IID_IUnknown or riid[] == c.iid or riid[] == IID_IAgileObject:
    ppv[] = self
    discard completionAddRef(self)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc completionInvoke(self: pointer,
                      info, status: pointer): HRESULT {.abi.} =
  ## Runs on whichever thread finished the work. It signals and returns; every
  ## decision is made on the dispatcher's thread.
  let c = cast[ptr Completion](self)
  try:
    trigger(c.ev)
  except CatchableError:
    discard
  S_OK

var completionVtbl = CompletionVtbl(
  queryInterface: completionQuery, addRef: completionAddRef,
  release: completionRelease, invoke: completionInvoke)

proc newCompletion(iid: GUID, ev: AsyncEvent): ptr Completion =
  result = cast[ptr Completion](comAlloc(sizeof(Completion)))
  result.vtbl = completionVtbl.addr
  result.refs = 1
  result.iid = iid
  result.ev = ev

func completedSlot(layout: AsyncLayout): int =
  if layout == alPlain: 6 else: 8

func resultsSlot(layout: AsyncLayout): int =
  if layout == alPlain: 8 else: 10

# ---------------------------------------------------------- what happened

proc statusOf(op: pointer, what: string): AsyncState =
  let info = queryInterface(op, IidAsyncInfo)
  if info.isNil:
    raise newException(WinRtError, "winrt: " & what & " is not an IAsyncInfo")
  try:
    var status: int32
    vcall(info, SlotAsyncInfoStatus, FnAsyncStatus)(info, status.addr)
      .check(what & ".get_Status")
    result = AsyncState(status)
  finally:
    release(info)

proc failureOf(op: pointer, what: string): ref WinRtError =
  ## How the operation ended, as an exception to fail the Future with, or nil.
  case statusOf(op, what)
  of asCanceled:
    var e = newException(CancelledError, "winrt: " & what & " was cancelled")
    e.hr = E_ABORT
    e
  of asError:
    let info = queryInterface(op, IidAsyncInfo)
    var hr: HRESULT = E_FAIL
    if not info.isNil:
      try:
        # The failure is on the operation. The call that started it returned
        # S_OK, so this is the only place the real code lives.
        discard vcall(info, SlotAsyncInfoErrorCode, FnAsyncError)(info, hr.addr)
      finally:
        release(info)
    var e = newException(WinRtError, "winrt: " & what & " failed: " & hr.name)
    e.hr = hr
    e
  else:
    nil

# ------------------------------------------------------------- the Future

var running: seq[tuple[future: FutureBase, op: pointer]]
  ## The operation behind each Future still in flight, so `cancel` can find
  ## it. Dispatcher thread only, like everything that touches a Future.

proc forget(fut: FutureBase) =
  for i, entry in running:
    if entry.future == fut:
      running.del i
      return

proc operation[T](op: pointer, handlerIid: GUID, layout: AsyncLayout,
                  what: string, results: proc(op: pointer): T): Future[T] =
  ## The Future for `op`, completed with what `results` reads from it once
  ## the operation is done — or failed with how it ended. Takes ownership of
  ## `op`: the caller started the operation and has nothing further to do
  ## with it, and releasing in one place means a failed operation is not also
  ## a leaked one.
  ##
  ## `put_Completed` invokes the handler immediately if the work has already
  ## finished, so there is no window between asking and being told.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  let fut = newFuture[T](what)
  running.add (FutureBase(fut), op)
  let ev = newAsyncEvent()
  addEvent(ev, proc (fd: AsyncFD): bool {.gcsafe.} =
    # The dispatcher's own thread, so the Future is safe to touch here. The
    # compiler cannot see that through a closure call, hence the cast.
    {.cast(gcsafe).}:
      forget(fut)
      if not fut.finished:      # `put_Completed` itself failed otherwise
        try:
          let err = failureOf(op, what)
          if not err.isNil:
            fut.fail(err)
          else:
            when T is void:
              results(op)
              fut.complete()
            else:
              fut.complete(results(op))
        except CatchableError as e:
          fut.fail(e)
      discard release(op)
    ev.close()
    true)                     # true: finished with this event, unregister it

  let handler = newCompletion(handlerIid, ev)
  try:
    vcall(op, completedSlot(layout), FnPutHandler)(op, handler)
      .check(what & ".put_Completed")
  except CatchableError as e:
    # The handler will never be invoked, so the Future is failed here and the
    # event raised by hand for the cleanup above.
    fut.fail(e)
    trigger(ev)
  finally:
    # `put_Completed` took its own reference; the object frees itself when the
    # operation lets go of it.
    discard completionRelease(handler)
  fut

proc cancel*(fut: FutureBase): bool {.discardable.} =
  ## Ask the operation behind `fut` to stop. When it does, `fut` fails with a
  ## `CancelledError`; an operation may also finish first, or ignore the
  ## request, and then completes as it would have. Returns false if `fut` is
  ## not a WinRT operation still in flight.
  for entry in running:
    if entry.future == fut:
      let info = queryInterface(entry.op, IidAsyncInfo)
      if info.isNil: return false
      try:
        vcall(info, SlotAsyncInfoCancel, FnNoArgs)(info)
          .check("IAsyncInfo.Cancel")
      finally:
        release(info)
      return true
  false

proc reportProgress*[P](op: pointer, handlerIid: GUID,
                        handler: ProgressHandler[P], what: string) =
  ## Have a `WithProgress` operation report to `handler` as it goes. The
  ## delegate is an ordinary one, so `handler` runs on the dispatcher thread.
  ## A nil handler asks for nothing, which is the common case.
  if handler.isNil: return
  let cb =
    when P is WinRtObject:
      newDelegate[pointer, pointer](handlerIid,
        proc(info, value: pointer) = handler(borrow[P](value)))
    elif P is string:
      newDelegate[pointer, HSTRING](handlerIid,
        proc(info: pointer, value: HSTRING) = handler($value))
    else:
      newDelegate[pointer, P](handlerIid,
        proc(info: pointer, value: P) = handler(value))
  try:
    vcall(op, SlotPutProgress, FnPutHandler)(op, cb)
      .check(what & ".put_Progress")
  finally:
    release(cb)

# ------------------------------------------------------------ the results

# One per shape a result comes in. Each is `operation` with a reader for that
# shape, and is what a generated wrapper returns.

template withResults(op: pointer, iid: GUID, what: string,
                     name, body: untyped) =
  ## `GetResults` is numbered per interface, so it has to be called through
  ## the instantiation the signature declares rather than through whatever
  ## pointer happens to be at hand.
  let name = queryInterface(op, iid)
  if name.isNil:
    raise newException(WinRtError, "winrt: " & what &
      " is not the operation type its signature declares")
  try:
    body
  finally:
    release(name)

proc readObject(op: pointer, opIid: GUID, layout: AsyncLayout,
                what: string): pointer =
  ## A result that is an interface pointer, ours to release.
  withResults(op, opIid, what, iface):
    vcall(iface, resultsSlot(layout), FnResultsPtr)(iface, result.addr)
      .check(what & ".GetResults")

proc futureVoid*(op: pointer, handlerIid: GUID, layout: AsyncLayout,
                 what: string): Future[void] =
  ## An `IAsyncAction`, which produces nothing.
  operation[void](op, handlerIid, layout, what, proc(op: pointer) =
    vcall(op, resultsSlot(layout), FnNoArgs)(op)
      .check(what & ".GetResults"))

proc futureObject*[T](op: pointer, opIid, handlerIid: GUID,
                      layout: AsyncLayout, what: string): Future[T] =
  ## An `IAsyncOperation<T>` whose result is an object.
  operation[T](op, handlerIid, layout, what, proc(op: pointer): T =
    adopt[T](readObject(op, opIid, layout, what)))

proc futureString*(op: pointer, opIid, handlerIid: GUID,
                   layout: AsyncLayout, what: string): Future[string] =
  ## The same, for an operation whose result is a string.
  operation[string](op, handlerIid, layout, what, proc(op: pointer): string =
    withResults(op, opIid, what, iface):
      var h: HSTRING
      vcall(iface, resultsSlot(layout), FnResultsString)(iface, h.addr)
        .check(what & ".GetResults")
      result = takeString(h))

proc futureValue*[T](op: pointer, opIid, handlerIid: GUID,
                     layout: AsyncLayout, what: string): Future[T] =
  ## An `IAsyncOperation<T>` whose result is a value rather than an object —
  ## a number, a boolean, an enum or a struct. It comes back by value through
  ## the same `GetResults` slot, so only the signature differs.
  operation[T](op, handlerIid, layout, what, proc(op: pointer): T =
    withResults(op, opIid, what, iface):
      vcall(iface, resultsSlot(layout), FnResultsValue[T])(iface, result.addr)
        .check(what & ".GetResults"))

proc futureSeq*[E](op: pointer, opIid, handlerIid: GUID, layout: AsyncLayout,
                   what: string, collectionIid: GUID, innerIid = GUID(),
                   innerPairIid = GUID()): Future[seq[E]] =
  ## An operation producing a collection, walked once there is one: `toSeq`
  ## with the same IIDs.
  operation[seq[E]](op, handlerIid, layout, what, proc(op: pointer): seq[E] =
    let coll = readObject(op, opIid, layout, what)
    try:
      toSeq[E](coll, collectionIid, innerIid, innerPairIid)
    finally:
      release(coll))

proc futureTable*[K, V](op: pointer, opIid, handlerIid: GUID,
                        layout: AsyncLayout, what: string,
                        iterableIid, pairIid: GUID,
                        innerIid = GUID()): Future[Table[K, V]] =
  ## An operation producing a map: `toTable` with the same IIDs.
  operation[Table[K, V]](op, handlerIid, layout, what,
                         proc(op: pointer): Table[K, V] =
    let map = readObject(op, opIid, layout, what)
    try:
      toTable[K, V](map, iterableIid, pairIid, innerIid)
    finally:
      release(map))

proc futureReference*[T](op: pointer, opIid, handlerIid: GUID,
                         layout: AsyncLayout, what: string,
                         referenceIid: GUID): Future[Option[T]] =
  ## An operation producing an `IReference<T>`: a value, or nothing.
  operation[Option[T]](op, handlerIid, layout, what,
                       proc(op: pointer): Option[T] =
    let box = readObject(op, opIid, layout, what)
    try:
      readReference[T](box, referenceIid, what)
    finally:
      release(box))
