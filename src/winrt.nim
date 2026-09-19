## winrt — the Windows Runtime, projected into Nim.
##
## WinRT is how Windows exposes most of what it has gained since Windows 8:
## Bluetooth, gamepads, the camera, notifications, geolocation, media playback,
## app packaging. Every one of those is a COM interface described by metadata
## that ships with the SDK, and every language reaches them the same way — by
## generating bindings from that metadata. This is the generated Nim side of
## it, already generated.
##
## ```nim
## import winrt, winrt/system
##
## discard initApartment()
## echo PowerManager.batteryStatus          # Idle
## echo PowerManager.remainingChargePercent
## ```
##
## ## Two layers
##
## Each namespace is two modules, the way `winui3` and every other WinRT
## projection are built:
##
## * `winrt/gaming` — classes, properties, methods and events as ordinary Nim.
##   Objects are one pointer wide and reference-counted by the compiler, so
##   nothing is released by hand; strings are Nim strings.
## * `winrt/abi/gaming` — the vtable underneath: an IID per interface and an
##   object per interface whose fields are its methods. This is what the layer
##   above compiles into, and what you implement against when Windows is to
##   call an object of yours — see `winrt/implement`.
##
## Importing the first gives you the second as well, so there is no cost to
## reaching down when you need to.
##
## ## Import what you use
##
## A module costs what it contains rather than what the package holds:
##
## | module | namespace |
## | --- | --- |
## | `winrt/foundation` | `Windows.Foundation.*` |
## | `winrt/ai` | `Windows.AI.*` |
## | `winrt/applicationmodel` | `Windows.ApplicationModel.*` |
## | `winrt/data` | `Windows.Data.*` |
## | `winrt/devices` | `Windows.Devices.*` |
## | `winrt/gaming` | `Windows.Gaming.*` |
## | `winrt/globalization` | `Windows.Globalization.*` |
## | `winrt/graphics` | `Windows.Graphics.*` |
## | `winrt/management` | `Windows.Management.*` |
## | `winrt/media` | `Windows.Media.*` |
## | `winrt/networking` | `Windows.Networking.*` |
## | `winrt/perception` | `Windows.Perception.*` |
## | `winrt/security` | `Windows.Security.*` |
## | `winrt/services` | `Windows.Services.*` |
## | `winrt/storage` | `Windows.Storage.*` |
## | `winrt/system` | `Windows.System.*` |
## | `winrt/ui` | `Windows.UI.*` |
## | `winrt/web` | `Windows.Web.*` |
##
## Importing `winrt` alone gives the runtime itself — apartment setup, strings,
## GUIDs, activation, delegates — and none of the bindings.
##
## ## The shapes a class comes in
##
## ```nim
## let cal = newCalendar()                  # constructible with no arguments
## let uri = Uri.createUri("https://...")   # built through a factory
## echo PowerManager.batteryStatus          # static: no instances at all
## ```
##
## Which one applies is in the metadata, not a convention: a class whose
## `ActivatableAttribute` names a factory interface will refuse
## `RoActivateInstance`, and a static class implements nothing and has no
## instance to hold.

import winrt/[core, delegate, implement]

export core, delegate, implement
