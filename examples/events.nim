## Subscribe to a Windows event.
##
##     nim c -r --path:src examples/events.nim
##
## `PowerManager` is a static class, so its events hang off the type the same
## way its properties do. Subscribing hands back a token, and that token is
## what unsubscribes — the delegate frees itself once the event source lets go.

import std/strformat
import winrt/system

proc main() =
  var fired = 0
  let token = PowerManager.onEnergySaverStatusChanged(
    proc(sender: WinRtObject, args: WinRtObject) = fired.inc)
  echo &"subscribed, token {token.value}"

  # Nothing will change the power state during a short run, so this shows the
  # subscription working rather than waiting for one.
  echo &"energy saver is {PowerManager.energySaverStatus}, handler ran {fired} times"

  PowerManager.removeEnergySaverStatusChanged(token)
  echo "unsubscribed"

when isMainModule:
  main()
