## Take a URL apart with the runtime's own parser.
##
##     nim c -r --path:src examples/uri.nim
##
## `Windows.Foundation.Uri` has no parameterless constructor — the metadata
## points at a factory interface instead — so it is built through the factory
## method the class declares.

import std/strformat
import winrt
import winrt/foundation

proc main() =
  discard initApartment()

  let uri = Uri.createUri("https://nim-lang.org:443/docs/manual.html?q=1#toc")

  echo &"scheme    {uri.schemeName}"
  echo &"host      {uri.host}"
  echo &"port      {uri.port}"
  echo &"path      {uri.path}"
  echo &"query     {uri.query}"
  echo &"fragment  {uri.fragment}"
  echo &"absolute  {uri.absoluteUri}"

when isMainModule:
  main()
