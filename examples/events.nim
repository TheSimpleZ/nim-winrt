## Subscribe to a Windows event.
##
##     nim c -r --path:src examples/events.nim
##
## `PowerManager` is a static class, so its events hang off the type the same
## way its properties do. Subscribing hands back a token, and that token is
## what unsubscribes — the delegate frees itself once the event source lets go.
##
## The IID of the handler is a computed one: `EventHandler<Object>` is a
## parameterised delegate, and WinRT derives its IID by hashing a signature
## string rather than declaring it anywhere. That happens during generation, so
## there is nothing to work out here.

import std/strformat
import winrt
import winrt/system

proc main() =
  discard initApartment()

  var fired = 0
  let token = PowerManager.onEnergySaverStatusChanged(
    proc(sender, args: pointer) = fired.inc)
  echo &"subscribed, token {token.value}"

  # Nothing will change the power state during a short run, so this shows the
  # subscription working rather than waiting for one.
  echo &"energy saver is {PowerManager.energySaverStatus}, handler ran {fired} times"

  PowerManager.removeEnergySaverStatusChanged(token)
  echo "unsubscribed"

when isMainModule:
  main()
