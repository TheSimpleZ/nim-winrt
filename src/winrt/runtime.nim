## The Windows Runtime on a thread: started when first needed, and the
## activation factories every class is reached through.
##
## There is nothing to call before using WinRT. The first time a thread
## activates a class or asks for a factory, the runtime is initialised for it,
## multithreaded, which is what a program that is not a UI framework wants.
## A UI framework wants the single-threaded model instead, and says so by
## calling `initRuntime(singleThreaded)` itself, before anything else.

import std/[os, strformat]
import ./com
include ./abidef

# ------------------------------------------------------------ this thread

type ThreadingModel* = enum
  ## The two values `RoInitialize` takes, in its own order.
  singleThreaded = 0
    ## Objects made on this thread are called on this thread, which XAML
    ## and most UI frameworks require — and which means this thread has to
    ## pump COM messages for a call from elsewhere to arrive.
  multiThreaded = 1
    ## Any thread may call any object and the runtime marshals nothing, so a
    ## callback arrives on a thread of its choosing. The default, and what a
    ## service, a tool or a test wants.

var runtimeReady {.threadvar.}: bool

proc initRuntime*(model = multiThreaded) =
  ## Start the runtime on this thread with the given threading model.
  ##
  ## Called for you, multithreaded, the first time this thread needs the
  ## runtime; call it yourself first only to choose `singleThreaded`. Calling
  ## it again is harmless, and a thread the host already set up is left as it
  ## is: the runtime answers `RPC_E_CHANGED_MODE` for a different model and
  ## `S_FALSE` for the same one, and neither is a failure here.
  let hr = roInitialize(int32(model))
  if hr.failed and hr != RPC_E_CHANGED_MODE:
    hr.check("RoInitialize")
  runtimeReady = true

proc ensureRuntime*() {.inline.} =
  ## What every entry into the runtime calls first.
  if not runtimeReady: initRuntime()

# ------------------------------------------------------ while it is alive

var runtimeAlive = true

proc endRuntime*() =
  ## Record that the hosting runtime has shut down and its objects are gone.
  ##
  ## Nothing in this package calls this: an application that only makes WinRT
  ## calls never has a runtime torn out from under it. A framework built on top
  ## does — a XAML projection calls this once `Application.Start` returns —
  ## after which a `Release` would reach through a vtable that has been freed.
  runtimeAlive = false

proc releaseIfLive*(obj: pointer) {.raises: [].} =
  ## Release, unless the runtime has already gone.
  ##
  ## Object wrappers release in their destructors, and a wrapper captured by an
  ## event handler's closure outlives the message loop: the closure sits in a
  ## module-level table that Nim destroys at *process* exit, by which time the
  ## framework has torn itself down. Releasing then corrupts the heap —
  ## `STATUS_HEAP_CORRUPTION`, raised after the program has otherwise finished
  ## successfully, which is about as hard to attribute as a fault gets.
  ##
  ## Skipping the release leaks, but only during the handful of microseconds
  ## between the runtime ending and the process ending, so nothing can observe
  ## it. That is the right trade against writing into freed memory.
  if runtimeAlive: release(obj)

proc addRefIfLive*(obj: pointer) {.raises: [].} =
  ## The counterpart of `releaseIfLive`, for the same reason: a wrapper copied
  ## while the runtime is being torn down must not touch the object either.
  if runtimeAlive: addRef(obj)

# --------------------------------------------------------------- activation

var activationHint*: proc(classId: string): string {.nimcall, gcsafe.} = nil
  ## Called when a class cannot be activated, to add whatever the caller knows
  ## about why.
  ##
  ## `REGDB_E_CLASSNOTREG` sends people looking for a typo in the class id, and
  ## the class id is almost never the problem — Windows simply has nowhere to
  ## look. *Where* it should have looked depends on which runtime the class
  ## belongs to, and this module deliberately does not know: inbox Windows
  ## classes are always present, while a class from the Windows App SDK needs
  ## that SDK deployed. A package projecting one of those assigns this and says
  ## the useful thing. Left unset, the error is still accurate, just general.

proc defaultHint(classId: string): string =
  let exe = getAppFilename()
  let manifest = exe & ".manifest"
  "\n\nwinrt: " & classId & " could not be activated. Windows found no\n" &
    "registration for it, which means either the class belongs to a runtime\n" &
    "that is not deployed with this executable, or the executable has no\n" &
    "manifest naming it.\n\n" &
    "  executable: " & exe & "\n" &
    "  manifest:   " & manifest &
    (if fileExists(manifest): "  (present)" else: "  (MISSING)") & "\n\n" &
    "Note that Windows caches the activation context by executable path and\n" &
    "timestamp, including the result when no manifest was found, so\n" &
    "adding one afterwards changes nothing until the executable is rebuilt.\n"

proc activationFactory*(classId: string, iid = IID_IActivationFactory): pointer =
  ## A class's activation factory, narrowed to `iid`. Ours to release.
  ##
  ## This is where a deployment problem shows up, as `REGDB_E_CLASSNOTREG`:
  ## the class id is real, but nothing in the process knows where to find it.
  ## See `activationHint`.
  ensureRuntime()
  var id = iid
  let name = toWinRtString(classId)
  let hr = roGetActivationFactory(name.handle, id.addr, result.addr)
  if hr == REGDB_E_CLASSNOTREG:
    var e = newException(WinRtError,
      &"RoGetActivationFactory({classId}) failed: {hr.name}" &
      (if activationHint.isNil: defaultHint(classId)
       else: activationHint(classId)))
    e.hr = hr
    raise e
  hr.check(&"RoGetActivationFactory({classId})")

proc tryActivationFactory*(classId: string, iid = IID_IActivationFactory):
    tuple[factory: pointer, hr: HRESULT] =
  ## Non-raising variant, for probing whether a class is reachable at all.
  ensureRuntime()
  var id = iid
  let name = toWinRtString(classId)
  result.hr = roGetActivationFactory(name.handle, id.addr, result.factory.addr)

proc statics*[V](classId: string): Interface[V] =
  ## The interface `V` of a class's activation factory: where a static
  ## member, a factory method or a constructor with arguments lives. combase
  ## caches factories, so this costs a lookup and an AddRef.
  Interface[V](owner: InterfaceOwner(raw: activationFactory(classId, iid(V))))

proc activate*(classId: string, iid: GUID): pointer =
  ## A new instance of a class that has a parameterless constructor, narrowed
  ## to `iid`. Ours to release.
  ##
  ## Plenty of classes have no such constructor — anything static, and
  ## anything meant to be derived from, answers `E_NOTIMPL` here — and are
  ## constructed through their factory instead.
  ensureRuntime()
  let name = toWinRtString(classId)
  var obj: pointer
  roActivateInstance(name.handle, obj.addr).check(&"RoActivateInstance({classId})")
  result = queryInterface(obj, iid)
  release(obj)
  if result.isNil:
    raise newException(WinRtError, "winrt: " & classId &
      " does not implement the expected interface")

proc compose*[F](classId: string, iid: GUID): pointer =
  ## A new instance of a composable class — one designed to be derived from,
  ## which refuses `RoActivateInstance` — through its factory `F`'s
  ## `CreateInstance(outer, inner, value)`. Passing a nil `outer` says we are
  ## not deriving from it; the `inner` handed back is a reference that is not
  ## ours to keep.
  let factory = statics[F](classId)
  var inner, instance: pointer
  # Parenthesised: in a generic, `x.f(...)` looks for a routine `f`, and a
  # generated module may declare one of that name. This is the field.
  (factory.vtbl.CreateInstance)(factory.raw, nil, inner.addr, instance.addr)
    .check(classId & ".CreateInstance")
  if not inner.isNil and inner != instance:
    release(inner)
  result = queryInterface(instance, iid)
  release(instance)
  if result.isNil:
    raise newException(WinRtError, "winrt: " & classId &
      " does not implement the expected interface")
