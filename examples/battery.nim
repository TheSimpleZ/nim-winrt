## Read the power state, which is only available through WinRT.
##
##     nim c -r --path:src examples/battery.nim

import winrt
import winrt/system

proc main() =
  discard initApartment()

  echo "battery      ", PowerManager.batteryStatus
  echo "power supply ", PowerManager.powerSupplyStatus
  echo "energy saver ", PowerManager.energySaverStatus

  if PowerManager.batteryStatus != BatteryStatus.NotPresent:
    echo "charge       ", PowerManager.remainingChargePercent, "%"

when isMainModule:
  main()
