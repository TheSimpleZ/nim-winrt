## Take a URL apart with the Windows Runtime's own URI parser.
##
##     nim c -r --path:src examples/uri.nim
##
## `Windows.Foundation.Uri` has shipped in every Windows since 8, so this runs
## anywhere with no deployment, no manifest and no permissions — which makes it
## the smallest complete example of the whole calling convention.

import std/strformat
import winrt
import winrt/foundation

proc main() =
  discard initApartment()

  # A class with no default constructor is built through its factory. The IID
  # picks which interface of the factory you get back, and so which methods
  # the slot numbers below refer to.
  let factory = activationFactory("Windows.Foundation.Uri",
                                  IID_IUriRuntimeClassFactory)
  defer: release(factory)

  # Strings cross the ABI as HSTRING, which the runtime owns. `withHString`
  # creates one and deletes it again however the block exits.
  var uri: pointer
  withHString("https://nim-lang.org/docs/manual.html?q=1#procedures", s):
    let createUri = factory.vcall(Slot_IUriRuntimeClassFactory_CreateUri,
                                  Fn_IUriRuntimeClassFactory_CreateUri)
    createUri(factory, s, uri.addr).check("Uri.CreateUri")
  defer: release(uri)

  # `uri` is an IUriRuntimeClass — the class's default interface, which is what
  # the factory hands back — so its slots can be called directly.
  proc field(slot: int): string =
    ## Every one of these getters has the same ABI shape: an out-parameter
    ## taking an HSTRING that becomes the caller's to delete.
    var h: HSTRING
    let get = uri.vcall(slot, Fn_IUriRuntimeClass_get_Host)
    get(uri, h.addr).check("Uri getter")
    result = $h
    discard windowsDeleteString(h)

  echo &"scheme    {field(Slot_IUriRuntimeClass_get_SchemeName)}"
  echo &"host      {field(Slot_IUriRuntimeClass_get_Host)}"
  echo &"path      {field(Slot_IUriRuntimeClass_get_Path)}"
  echo &"query     {field(Slot_IUriRuntimeClass_get_Query)}"
  echo &"fragment  {field(Slot_IUriRuntimeClass_get_Fragment)}"

  var port: int32
  let getPort = uri.vcall(Slot_IUriRuntimeClass_get_Port,
                          Fn_IUriRuntimeClass_get_Port)
  getPort(uri, port.addr).check("Uri.get_Port")
  echo &"port      {port}"

when isMainModule:
  main()
