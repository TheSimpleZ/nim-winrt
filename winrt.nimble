version       = "0.1.0"
author        = "Zrean Tofiq"
description   = "The Windows Runtime (WinRT) projected into Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  exec "nim c -r --hints:off --path:src tests/tactivation.nim"

task bindings, "Regenerate the bindings from the Windows SDK metadata":
  ## Only needed when moving to a newer SDK. The result is checked in, so
  ## nobody installing this package has to have the metadata or run this.
  exec "nim c -d:release --hints:off -o:bin/generate.exe tools/generate.nim"
  exec "./bin/generate.exe " &
       "\"C:/Program Files (x86)/Windows Kits/10/UnionMetadata/10.0.26100.0/Windows.winmd\" " &
       "--split src/winrt"
