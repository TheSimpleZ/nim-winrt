## Read the power state, which is only available through WinRT.
##
##     nim c -r --path:src examples/battery.nim
##
## `Windows.System.Power.PowerManager` is a *static* class: it has no
## instances, only an activation factory whose interface carries the
## properties. That is the usual shape for the small informational APIs, and
## it is why `activationFactory` rather than `activateInstance` is the call
## this library leans on.

import std/strformat
import winrt
import winrt/system

proc main() =
  discard initApartment()

  let power = activationFactory("Windows.System.Power.PowerManager",
                                IID_IPowerManagerStatics)
  defer: release(power)

  # WinRT enums cross the ABI as int32, so the generated signature says
  # `ptr int32` and the value is converted on this side. The generated enum
  # type knows its own names, which is what `$` prints.
  proc status(slot: int): int32 =
    let get = power.vcall(slot, Fn_IPowerManagerStatics_get_BatteryStatus)
    get(power, result.addr).check("PowerManager getter")

  let battery = BatteryStatus(status(Slot_IPowerManagerStatics_get_BatteryStatus))
  let supply = PowerSupplyStatus(
    status(Slot_IPowerManagerStatics_get_PowerSupplyStatus))
  let saver = EnergySaverStatus(
    status(Slot_IPowerManagerStatics_get_EnergySaverStatus))

  echo &"battery       {battery}"
  echo &"power supply  {supply}"
  echo &"energy saver  {saver}"

  if battery != BatteryStatus_NotPresent:
    var percent: int32
    let get = power.vcall(Slot_IPowerManagerStatics_get_RemainingChargePercent,
                          Fn_IPowerManagerStatics_get_RemainingChargePercent)
    get(power, percent.addr).check("PowerManager.get_RemainingChargePercent")
    echo &"charge        {percent}%"

when isMainModule:
  main()
