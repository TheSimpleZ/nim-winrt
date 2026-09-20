## Ask Windows what today is, in the user's own calendar and language.
##
##     nim c -r --path:src examples/calendar.nim
##
## `Calendar` is an ordinary class: constructed with no arguments, and read
## through properties.

import std/strformat
import winrt/globalization

proc main() =
  let cal = newCalendar()
  cal.setToNow()

  echo &"calendar  {cal.getCalendarSystem}"
  echo &"date      {cal.yearAsString}-{cal.monthAsNumericString}-{cal.dayAsString}"
  echo &"time      {cal.hourAsPaddedString(2)}:{cal.minuteAsPaddedString(2)}"
  echo &"day       {cal.dayOfWeekAsString}"
  echo &"era       {cal.eraAsString}"

when isMainModule:
  main()
