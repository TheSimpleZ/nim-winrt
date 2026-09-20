## The shapes WinRT hands around, as Nim sees them.
##
##     nim c -r --path:src examples/shapes.nim
##
## A collection is a `seq`, a map is a `Table`, an `[out]` parameter comes
## back beside the result, and an asynchronous operation is a `Future`.

import std/[strformat, tables]
import winrt/[devices, globalization, web]

proc main() =
  # A seq of structs in, and back out.
  let path = newGeopath(@[
    BasicGeoposition(latitude: 59.33, longitude: 18.07),
    BasicGeoposition(latitude: 57.71, longitude: 11.97)])
  echo &"{path.positions.len} positions, the second at {path.positions[1].latitude}"

  # A Table in, and an operation that reports progress awaited.
  let form = newHttpFormUrlEncodedContent({"q": "nim"}.toTable)
  echo "encoded: ", waitFor form.readAsStringAsync()

  # An out-parameter beside the declared return.
  let (outcome, info) = PhoneNumberInfo.tryParse("+46 8 123 456", "SE")
  echo &"{outcome}, country code {info.countryCode}"

when isMainModule:
  main()
