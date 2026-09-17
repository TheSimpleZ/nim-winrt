version       = "0.3.0"
author        = "Zrean Tofiq"
description   = "The Windows Runtime (WinRT) projected into Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

const Namespaces = {
  "foundation": "Windows.Foundation",
  "ai": "Windows.AI",
  "applicationmodel": "Windows.ApplicationModel",
  "data": "Windows.Data",
  "devices": "Windows.Devices",
  "gaming": "Windows.Gaming",
  "globalization": "Windows.Globalization",
  "graphics": "Windows.Graphics",
  "management": "Windows.Management",
  "media": "Windows.Media",
  "networking": "Windows.Networking",
  "perception": "Windows.Perception",
  "security": "Windows.Security",
  "services": "Windows.Services",
  "storage": "Windows.Storage",
  "system": "Windows.System",
  "ui": "Windows.UI",
  "web": "Windows.Web",
}

task test, "Run the test suite":
  for t in ["tactivation", "tdelegate", "timports", "tapi"]:
    exec "nim c -r --hints:off --path:src tests/" & t & ".nim"

task examples, "Build and run every example":
  for e in listFiles("examples"):
    if e.endsWith(".nim"):
      exec "nim c -r --hints:off --path:src " & e

task bindings, "Regenerate the bindings from the Windows SDK metadata":
  ## Only needed when moving to a newer SDK. The result is checked in, so
  ## nobody installing this package needs the metadata or has to run this.
  ## Set WINMD to generate against a different one.
  ##
  ## Two passes over the same metadata, in this order: the ABI layer names the
  ## slots and signatures, and the API layer is written against it.
  const default = "C:/Program Files (x86)/Windows Kits/10/UnionMetadata/" &
                  "10.0.26100.0/Windows.winmd"
  let winmd = if existsEnv("WINMD"): getEnv("WINMD") else: default
  if not fileExists(winmd):
    quit "winrt: no Windows metadata at " & winmd &
         "\n  install the Windows SDK, or set WINMD to the .winmd to read"

  exec "nim c -d:release --hints:off -o:bin/generate.exe tools/generate.nim"
  exec "nim c -d:release --hints:off -o:bin/wrappers.exe tools/wrappers.nim"
  # Doubled backslash: `exec` goes through cmd.exe, which will not resolve a
  # command path written with forward slashes.
  exec "bin\\generate.exe \"" & winmd & "\" --split src/winrt/abi ../core"
  for (m, ns) in Namespaces:
    exec "bin\\wrappers.exe \"" & winmd & "\" " & ns &
         " src/winrt/" & m & ".nim ./core ./abi/" & m
