## Today's date, in whatever calendar and language Windows is set to.
##
##     nim c -r --path:src examples/calendar.nim
##
## This is the third activation shape, and the one that shows `queryInterface`:
## `Windows.Globalization.Calendar` has a default constructor, so
## `activateInstance` creates one — but what comes back is an `IInspectable`,
## and a slot number only means something against a *named* interface. Asking
## the object for `ICalendar` is what makes `Slot_ICalendar_*` legal to use on
## it.

import std/strformat
import winrt
import winrt/globalization

proc text(obj: pointer, slot: int): string =
  ## Call an `-> HSTRING` getter and take ownership of the result. All of the
  ## string getters here have the same ABI shape, so one signature does.
  var h: HSTRING
  let get = obj.vcall(slot, Fn_ICalendar_YearAsString)
  get(obj, h.addr).check("Calendar getter")
  result = $h
  discard windowsDeleteString(h)

proc number(obj: pointer, slot: int): int32 =
  let get = obj.vcall(slot, Fn_ICalendar_get_Year)
  get(obj, result.addr).check("Calendar getter")

proc main() =
  discard initApartment()

  let inspectable = activateInstance("Windows.Globalization.Calendar")
  defer: release(inspectable)

  # Slots are numbered per interface. Counting into the table of an interface
  # the object did not hand you finds whatever sits at that index in some other
  # table — a wrong call, not an error — so narrow first.
  let cal = inspectable.queryInterface(IID_ICalendar)
  doAssert cal != nil, "Calendar does not implement ICalendar"
  defer: release(cal)

  let setToNow = cal.vcall(Slot_ICalendar_SetToNow, Fn_ICalendar_SetToNow)
  setToNow(cal).check("Calendar.SetToNow")

  echo &"calendar   {cal.text(Slot_ICalendar_GetCalendarSystem)}"
  echo &"era        {cal.text(Slot_ICalendar_EraAsString)}"
  echo &"date       {cal.text(Slot_ICalendar_DayOfWeekAsSoloString)}, " &
       &"{cal.text(Slot_ICalendar_DayAsString)} " &
       &"{cal.text(Slot_ICalendar_MonthAsSoloString)} " &
       &"{cal.text(Slot_ICalendar_YearAsString)}"
  echo &"day        {cal.number(Slot_ICalendar_get_Day)} of " &
       &"{cal.number(Slot_ICalendar_get_NumberOfDaysInThisMonth)}"

  # The same object, asked for a second interface. `GetTimeZone` is slot 6 of
  # ITimeZoneOnCalendar's table; slot 6 of ICalendar's is `Clone`. Calling one
  # through the other's pointer would not fail — it would call `Clone`.
  let zone = cal.queryInterface(IID_ITimeZoneOnCalendar)
  doAssert zone != nil, "Calendar does not implement ITimeZoneOnCalendar"
  defer: release(zone)

  var h: HSTRING
  let getTimeZone = zone.vcall(Slot_ITimeZoneOnCalendar_GetTimeZone,
                               Fn_ITimeZoneOnCalendar_GetTimeZone)
  getTimeZone(zone, h.addr).check("Calendar.GetTimeZone")
  echo &"time zone  {h}"
  discard windowsDeleteString(h)

when isMainModule:
  main()
