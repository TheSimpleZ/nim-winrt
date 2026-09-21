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
import ./[com, objects, values, collections, delegate]
import ./abi/[types, generic, foundation]
include ./abidef

export asyncdispatch

type
  CancelledError* = object of WinRtError
    ## What a Future fails with when the operation behind it was cancelled,
    ## by `cancel` or by Windows. Its `hr` is `E_ABORT`.

  AsyncState = enum
    ## Not `AsyncStatus`: `Windows.Foundation.AsyncStatus` is a real enum in the
    ## generated bindings, and two of that name in scope is an ambiguity.
    asStarted = 0, asCompleted = 1, asCanceled = 2, asError = 3

# ------------------------------------------------------- the completion

type
  CompletionVtbl {.pure.} = object of IUnknownVtbl
    invoke: proc(self: pointer, info: pointer, status: AsyncStatus): HRESULT {.abi.}

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

proc completionInvoke(self: pointer, info: pointer,
                      status: AsyncStatus): HRESULT {.abi.} =
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

# ---------------------------------------------------------- what happened

proc statusOf(op: pointer, what: string): AsyncState =
  let info = queryInterface[IAsyncInfoVtbl](op)
  var status: AsyncStatus
  info.vtbl.get_Status(info.raw, status.addr).check(what & ".get_Status")
  AsyncState(ord(status))

proc failureOf(op: pointer, what: string): ref WinRtError =
  ## How the operation ended, as an exception to fail the Future with, or nil.
  case statusOf(op, what)
  of asCanceled:
    var e = newException(CancelledError, "winrt: " & what & " was cancelled")
    e.hr = E_ABORT
    e
  of asError:
    # The failure is on the operation. The call that started it returned
    # S_OK, so this is the only place the real code lives.
    let info = queryInterface[IAsyncInfoVtbl](op)
    var hr: HRESULT = E_FAIL
    discard info.vtbl.get_ErrorCode(info.raw, hr.addr)
    var e = newException(WinRtError, "winrt: " & what & " failed: " & hr.name)
    e.hr = hr
    e
  else:
    nil

# ----------------------------------------------------------- the shapes

# The four operation interfaces share one story and differ in two ways: whether
# there is a result, and whether there is progress. Which delegate completes
# one, and which reports its progress, is the `when` below. What it produces
# is not asked here: the caller of `future` names that type, since a generic
# whose signature expands a template reports an injected symbol wherever it
# is instantiated.

template CompletedHandler(Operation: typedesc): typedesc =
  ## The delegate an operation's `put_Completed` takes.
  when Operation is IAsyncActionVtbl: AsyncActionCompletedHandlerVtbl
  elif Operation is IAsyncOperationVtbl:
    AsyncOperationCompletedHandlerVtbl[Operation.TResult]
  elif Operation is IAsyncActionWithProgressVtbl:
    AsyncActionWithProgressCompletedHandlerVtbl[Operation.TProgress]
  else:
    AsyncOperationWithProgressCompletedHandlerVtbl[Operation.TResult,
                                                   Operation.TProgress]

template ProgressHandler(Operation: typedesc): typedesc =
  ## The delegate a `WithProgress` operation's `put_Progress` takes.
  when Operation is IAsyncActionWithProgressVtbl:
    AsyncActionProgressHandlerVtbl[Operation.TProgress]
  else:
    AsyncOperationProgressHandlerVtbl[Operation.TResult, Operation.TProgress]

# ------------------------------------------------------------- the Future

var running: seq[tuple[future: FutureBase, op: pointer]]
  ## The operation behind each Future still in flight, so `cancel` can find
  ## it. Dispatcher thread only, like everything that touches a Future.

proc forget(fut: FutureBase) =
  for i, entry in running:
    if entry.future == fut:
      running.del i
      return

proc results[AsyncOp, R](it: Interface[AsyncOp], what: string): R =
  ## `GetResults`, read as the Nim type `R` it produces.
  when R is void:
    (it.vtbl.GetResults)(it.raw).check(what & ".GetResults")
  else:
    var v: Abi(AsyncOp.TResult)
    (it.vtbl.GetResults)(it.raw, v.addr).check(what & ".GetResults")
    readValue[AsyncOp.TResult, R, Abi(AsyncOp.TResult)](v)

proc future*[AsyncOp, R](op: pointer, what: string): Future[R] =
  ## The Future for the operation `op`, an `AsyncOp` — `IAsyncOperationVtbl[T]`
  ## and the other three — completed with the `R` it produces once it is
  ## done, or failed with how it ended. Takes ownership of `op`: the caller
  ## started the operation and has nothing further to do with it, and
  ## releasing in one place means a failed operation is not also a leaked one.
  ##
  ## `put_Completed` invokes the handler immediately if the work has already
  ## finished, so there is no window between asking and being told.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  let fut = newFuture[R](what)
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
            let it = queryInterface[AsyncOp](op)
            when R is void:
              results[AsyncOp, R](it, what)
              fut.complete()
            else:
              fut.complete(results[AsyncOp, R](it, what))
        except CatchableError as e:
          fut.fail(e)
      discard release(op)
    ev.close()
    true)                     # true: finished with this event, unregister it

  let handler = newCompletion(iid(CompletedHandler(AsyncOp)), ev)
  try:
    let it = queryInterface[AsyncOp](op)
    (it.vtbl.put_Completed)(it.raw, handler).check(what & ".put_Completed")
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

proc future*[AsyncOp, R, P](op: pointer, what: string,
                            progress: proc(value: P)): Future[R] =
  ## The same, for a `WithProgress` operation, with `progress` told each `P`
  ## the operation reports along the way — on the dispatcher thread, like any
  ## handler. A nil `progress` asks for nothing.
  result = future[AsyncOp, R](op, what)
  if progress.isNil: return
  let cb = newDelegate(ProgressHandler(AsyncOp),
    proc(info: pointer, value: Abi(AsyncOp.TProgress)) =
      progress(borrowValue[AsyncOp.TProgress, P,
                           Abi(AsyncOp.TProgress)](value)))
  let it = queryInterface[AsyncOp](op)
  (it.vtbl.put_Progress)(it.raw, cb.raw).check(what & ".put_Progress")

proc cancel*(fut: FutureBase): bool {.discardable.} =
  ## Ask the operation behind `fut` to stop. When it does, `fut` fails with a
  ## `CancelledError`; an operation may also finish first, or ignore the
  ## request, and then completes as it would have. Returns false if `fut` is
  ## not a WinRT operation still in flight.
  for entry in running:
    if entry.future == fut:
      let info = queryInterface[IAsyncInfoVtbl](entry.op)
      info.vtbl.Cancel(info.raw).check("IAsyncInfo.Cancel")
      return true
  false
