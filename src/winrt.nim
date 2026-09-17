## winrt — the Windows Runtime, projected into Nim.
##
## WinRT is how Windows exposes most of what it has gained since Windows 8:
## Bluetooth, gamepads, the camera, notifications, geolocation, app packaging,
## media playback. Every one of those is a COM interface described by metadata
## that ships with the SDK, and every language gets at them the same way — by
## generating bindings from that metadata. This package is the generated Nim
## side of it, already generated.
##
## Importing `winrt` alone gives the runtime itself — strings, GUIDs, apartment
## setup, activation, delegates — and none of the bindings. Those live one
## module per namespace group, and each re-exports this one, so importing
## `winrt/gaming` is enough on its own.
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
## A module costs what it contains rather than what the package holds, and
## nothing you do not call reaches the binary.
##
## ## Calling a method
##
## Each interface contributes its IID, one `Slot_*` constant per method giving
## that method's index in the vtable, and one `Fn_*` type giving its ABI
## signature. A call is getting a pointer to the interface that declares the
## method, then reading that slot out of its table:
##
## ```nim
## import winrt, winrt/gaming
##
## initApartment()
## let factory = activationFactory("Windows.Gaming.Input.Gamepad",
##                                 IID_IGamepadStatics)
## defer: release(factory)
##
## var gamepads: pointer   # an IVectorView<Gamepad>
## let getGamepads = factory.vcall(Slot_IGamepadStatics_get_Gamepads,
##                                 Fn_IGamepadStatics_get_Gamepads)
## getGamepads(factory, gamepads.addr).check("Gamepad.get_Gamepads")
## release(gamepads)
## ```
##
## Every WinRT method returns `HRESULT`, and its declared return type becomes a
## trailing out-parameter — so `get_Gamepads() -> IVectorView<Gamepad>` takes a
## `ptr pointer`. Slots are numbered *per interface*, so `vcall` has to be given
## the pointer that interface was obtained as; see `vcall`.
##
## This is deliberately the ABI and not a friendly API: it is what a friendly
## API is built on, and what makes one possible without hand-writing thousands
## of declarations. `winui3 <https://github.com/TheSimpleZ/winui3-nim>`_ is an
## example of the layer above.
##
## The README has a worked example and `examples/` has four more;
## `docs/internals.md` describes how the bindings are produced.

import winrt/core
import winrt/delegate

export core
export delegate
