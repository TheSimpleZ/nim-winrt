version       = "0.1.0"
author        = "Zrean Tofiq"
description   = "The Windows Runtime (WinRT) projected into Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  for t in ["tactivation", "tdelegate", "timports"]:
    exec "nim c -r --hints:off --path:src tests/" & t & ".nim"

task examples, "Build and run every example":
  for e in listFiles("examples"):
    if e.endsWith(".nim"):
      exec "nim c -r --hints:off --path:src " & e

task bindings, "Regenerate the bindings from the Windows SDK metadata":
  ## Only needed when moving to a newer SDK. The result is checked in, so
  ## nobody installing this package needs the metadata or has to run this.
  ## Set WINMD to generate against a different one.
  const default = "C:/Program Files (x86)/Windows Kits/10/UnionMetadata/" &
                  "10.0.26100.0/Windows.winmd"
  let winmd = if existsEnv("WINMD"): getEnv("WINMD") else: default
  if not fileExists(winmd):
    quit "winrt: no Windows metadata at " & winmd &
         "\n  install the Windows SDK, or set WINMD to the .winmd to read"
  exec "nim c -d:release --hints:off -o:bin/generate.exe tools/generate.nim"
  # Backslashes: `exec` goes through cmd.exe, which will not resolve a command
  # path written with forward slashes.
  exec "bin\\generate.exe \"" & winmd & "\" --split src\\winrt"
