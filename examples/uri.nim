## Take a URL apart with the runtime's own parser.
##
##     nim c -r --path:src examples/uri.nim
##
## Nothing is started first and nothing is released: the runtime comes up when
## the first call reaches it, and the `Uri` drops its reference when `main`
## returns.

import std/strformat
import winrt/foundation

proc main() =
  let uri = newUri("https://nim-lang.org:443/docs/manual.html?q=1#toc")

  echo &"scheme    {uri.schemeName}"
  echo &"host      {uri.host}"
  echo &"port      {uri.port}"
  echo &"path      {uri.path}"
  echo &"query     {uri.query}"
  echo &"fragment  {uri.fragment}"
  echo &"absolute  {uri.absoluteUri}"

when isMainModule:
  main()
