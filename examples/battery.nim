## Read the power state, which is only available through WinRT.
##
##     nim c -r --path:src examples/battery.nim

import winrt
import winrt/system

proc main() =
  discard initApartment()

  let power = activationFactory("Windows.System.Power.PowerManager",
                                IID_IPowerManagerStatics)
  defer: release(power)

  var battery: BatteryStatus
  power.vcall(Slot_IPowerManagerStatics_get_BatteryStatus,
              Fn_IPowerManagerStatics_get_BatteryStatus)(power, battery.addr)
    .check("PowerManager.get_BatteryStatus")

  var charge: int32
  power.vcall(Slot_IPowerManagerStatics_get_RemainingChargePercent,
              Fn_IPowerManagerStatics_get_RemainingChargePercent)(power, charge.addr)
    .check("PowerManager.get_RemainingChargePercent")

  echo "battery ", battery, ", ", charge, "% charged"

when isMainModule:
  main()
