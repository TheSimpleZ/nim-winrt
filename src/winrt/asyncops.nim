## Waiting for WinRT asynchronous operations.
##
## A WinRT method that does anything slow does not return a result. It returns
## an `IAsyncOperation<T>` — an object carrying the state of work already in
## progress — and the result is read out of that once it finishes.
##
## Here that becomes an ordinary Nim `Future`, so the generated wrappers are
## `{.async.}` procs and compose with everything else in `std/asyncdispatch`:
##
## ```nim
## let adc = waitFor AdcController.getDefaultAsync()
## ```
##
## or `await` inside an async proc. There is deliberately no separate blocking
## spelling: `waitFor` is already that.
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
## parts on a thread Nim did not start, the better.

import std/asyncdispatch
import ./core
include ./abidef

export asyncdispatch

const
  # Not exported, and not named `IID_IAsyncInfo`: the metadata declares that
  # interface too, so `winrt/abi/foundation` has a constant of that name and
  # two in scope is an ambiguity wherever both are imported.
  IidAsyncInfo = guid"00000036-0000-0000-C000-000000000046"

  SlotAsyncInfoStatus = 7
  SlotAsyncInfoErrorCode = 8

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

  AsyncState = enum
    ## Not `AsyncStatus`: `Windows.Foundation.AsyncStatus` is a real enum in the
    ## generated bindings, and two of that name in scope is an ambiguity.
    asStarted = 0, asCompleted = 1, asCanceled = 2, asError = 3

  FnAsyncStatus = proc(self: pointer,
                       status: ptr int32): HRESULT {.abi.}
  FnAsyncError = proc(self: pointer,
                      hr: ptr HRESULT): HRESULT {.abi.}
  FnPutCompleted = proc(self: pointer,
                        handler: pointer): HRESULT {.abi.}
  FnResultsVoid = proc(self: pointer): HRESULT {.abi.}
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
    newException(WinRtError, "winrt: " & what & " was cancelled")
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

proc settled(op: pointer, handlerIid: GUID, layout: AsyncLayout,
             what: string): Future[void] =
  ## Completes when the operation does.
  ##
  ## `put_Completed` invokes the handler immediately if the work has already
  ## finished, so there is no window between asking and being told.
  let fut = newFuture[void]("winrt.settled")
  result = fut
  let ev = newAsyncEvent()
  addEvent(ev, proc (fd: AsyncFD): bool {.gcsafe.} =
    # The dispatcher's own thread, so the Future is safe to touch here.
    try:
      let err = failureOf(op, what)
      if err.isNil: fut.complete() else: fut.fail(err)
    except CatchableError as e:
      fut.fail(e)
    ev.close()
    true)                     # true: finished with this event, unregister it

  let handler = newCompletion(handlerIid, ev)
  try:
    vcall(op, completedSlot(layout), FnPutCompleted)(op, handler)
      .check(what & ".put_Completed")
  finally:
    # `put_Completed` took its own reference; the object frees itself when the
    # operation lets go of it.
    discard completionRelease(handler)

# Each of these takes ownership of `op`: the caller started the operation and
# has nothing further to do with it, and releasing in one place means a failed
# operation is not also a leaked one.

proc awaitVoid*(op: pointer, handlerIid: GUID, layout: AsyncLayout,
                what: string) {.async.} =
  ## An `IAsyncAction`, which produces nothing.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  try:
    await settled(op, handlerIid, layout, what)
    vcall(op, resultsSlot(layout), FnResultsVoid)(op)
      .check(what & ".GetResults")
  finally:
    release(op)

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

proc awaitObject*(op: pointer, opIid, handlerIid: GUID, layout: AsyncLayout,
                  what: string): Future[pointer] {.async.} =
  ## An `IAsyncOperation<T>` whose result is an interface pointer.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  try:
    await settled(op, handlerIid, layout, what)
    withResults(op, opIid, what, iface):
      vcall(iface, resultsSlot(layout), FnResultsPtr)(iface, result.addr)
        .check(what & ".GetResults")
  finally:
    release(op)

proc awaitString*(op: pointer, opIid, handlerIid: GUID, layout: AsyncLayout,
                  what: string): Future[string] {.async.} =
  ## The same, for an operation whose result is a string.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  try:
    await settled(op, handlerIid, layout, what)
    withResults(op, opIid, what, iface):
      var h: HSTRING
      vcall(iface, resultsSlot(layout), FnResultsString)(iface, h.addr)
        .check(what & ".GetResults")
      result = takeString(h)
  finally:
    release(op)

proc awaitValue*[T](op: pointer, opIid, handlerIid: GUID, layout: AsyncLayout,
                    what: string): Future[T] {.async.} =
  ## An `IAsyncOperation<T>` whose result is a value rather than an object —
  ## a number, a boolean, an enum or a struct. It comes back by value through
  ## the same `GetResults` slot, so only the signature differs.
  doAssert not op.isNil, "winrt: " & what & " returned no operation"
  try:
    await settled(op, handlerIid, layout, what)
    withResults(op, opIid, what, iface):
      vcall(iface, resultsSlot(layout), FnResultsValue[T])(iface, result.addr)
        .check(what & ".GetResults")
  finally:
    release(op)
