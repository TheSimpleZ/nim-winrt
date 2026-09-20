## The Windows Runtime from Nim.
##
## `import winrt` brings the runtime: objects and their lifetimes, strings,
## failures, async operations as Futures, delegates, and `implement` for an
## object of your own. The API itself is one import per namespace group —
## `import winrt/storage` for `Windows.Storage.*` — and a program needs
## nothing else: the runtime starts itself the first time it is reached for.
##
## ```nim
## import winrt/system
##
## echo PowerManager.batteryStatus            # Idle
## echo PowerManager.remainingChargePercent   # 87
## ```
##
## Underneath is a second layer, `winrt/abi/...`: every interface as its
## vtable, every enum and struct with its exact layout, for code that has to
## work at the level of the COM ABI itself.

import winrt/[com, runtime, objects, signatures, values, collections, asyncops,
              delegate, implement]

export com, runtime, objects, signatures, values, collections, asyncops,
       delegate, implement
