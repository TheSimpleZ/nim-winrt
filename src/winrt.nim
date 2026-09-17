## winrt — the Windows Runtime, projected into Nim.
##
## WinRT is how Windows exposes most of what it has gained since Windows 8:
## Bluetooth, gamepads, the camera, notifications, geolocation, app packaging,
## media playback. Every one of those is a COM interface described by metadata
## that ships with the SDK, and every language gets at them the same way — by
## generating bindings from that metadata. This package is the generated Nim
## side of it, already generated.
##
## ```nim
## import winrt, winrt/gaming
##
## initApartment()
## let factory = activationFactory("Windows.Gaming.Input.Gamepad",
##                                 IID_IGamepadStatics)
## ```
##
## ## Import what you use
##
## The bindings are one module per namespace group, and a module costs what it
## contains rather than what the package holds:
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
## Importing `winrt` alone gives the runtime itself — strings, GUIDs, apartment
## setup, activation, delegates — and none of the bindings.
##
## ## What a binding looks like
##
## Each interface contributes its IID, one `Slot_*` constant per method giving
## that method's index in the vtable, and one `Fn_*` type giving its signature.
## Calling a method is reading the slot out of the table and calling it:
##
## ```nim
## let fn = cast[Fn_IGamepadStatics_get_Gamepads](
##   vtbl(factory)[Slot_IGamepadStatics_get_Gamepads])
## ```
##
## This is deliberately the ABI and not a friendly API: it is what a friendly
## API is built on, and what makes one possible without hand-writing thousands
## of declarations. `winui3` is an example of the layer above.

import winrt/core
import winrt/delegate

export core
export delegate
