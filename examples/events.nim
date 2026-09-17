## Subscribe to a WinRT event.
##
##     nim c -r --path:src examples/events.nim
##
## An event is a pair of methods — `add_X(handler) -> token` and
## `remove_X(token)` — and the handler is a COM object the runtime calls back
## into. `newEventDelegate` builds one around a Nim closure.
##
## The awkward part is the handler's IID. Most WinRT events take a
## *parameterised* delegate, `EventHandler<T>` or `TypedEventHandler<S, A>`,
## and those have no GUID in any metadata file: the runtime derives one by
## hashing a signature string. `tools/piidcheck.nim` prints both the string and
## the resulting IID for every instantiation the SDK actually uses, which is
## where the constant below came from.
##
## Nothing here waits for the event to fire — the energy-saver state does not
## change to order. What it proves is that Windows accepted the delegate:
## `add_` QueryInterfaces it for exactly this IID first, so a wrong vtable or a
## wrong IID fails right there rather than at some later callback.

import std/strformat
import winrt
import winrt/system

# Windows.Foundation.EventHandler<Object>, from
#   pinterface({9de1c535-6ae1-11e0-84e1-18a905bcc53f};cinterface(IInspectable))
let IID_EventHandler_Object = guid("C50898F6-C536-5F47-8583-8B2C2438A13B")

proc main() =
  discard initApartment()

  let power = activationFactory("Windows.System.Power.PowerManager",
                                IID_IPowerManagerStatics)
  defer: release(power)

  var fired = 0
  let handler = newEventDelegate(IID_EventHandler_Object,
    proc(sender, args: pointer) = fired.inc)

  var token: EventRegistrationToken
  let add = power.vcall(Slot_IPowerManagerStatics_add_EnergySaverStatusChanged,
                        Fn_IPowerManagerStatics_add_EnergySaverStatusChanged)
  add(power, handler, token.addr).check("PowerManager.add_EnergySaverStatusChanged")

  # The event source took its own reference, so ours goes back now; the
  # delegate frees itself when the subscription ends.
  release(handler)
  echo &"subscribed, token {token.value}"

  let remove = power.vcall(
    Slot_IPowerManagerStatics_remove_EnergySaverStatusChanged,
    Fn_IPowerManagerStatics_remove_EnergySaverStatusChanged)
  remove(power, token).check("PowerManager.remove_EnergySaverStatusChanged")
  echo &"unsubscribed; handler ran {fired} times"

when isMainModule:
  main()
