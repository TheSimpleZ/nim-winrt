## The layer underneath: a WinRT call by hand, through the ABI module.
##
##     nim c -r --path:src examples/lowlevel.nim
##
## This is what the generated API compiles into. Every call is the same steps:
## an interface pointer from the activation factory, the method by name, a
## narrowing to the interface that declares the next method, and an out
## HSTRING that is yours to free.

import winrt
import winrt/abi/foundation

proc main() =
  discard initApartment()

  # 1. An interface pointer, from the activation factory.
  withStatics("Windows.Foundation.Uri", IUriRuntimeClassFactory, factory):

    # 2. The method, by name. `call` finds its slot and its signature from
    #    that name and checks the HRESULT. The declared return is a trailing
    #    out-parameter.
    var uri: pointer
    withHString("https://nim-lang.org/docs/manual.html", s):
      factory.call(IUriRuntimeClassFactory_CreateUri, s, uri.addr)
    defer: release(uri)

    # 3. Narrow to the interface that declares the method you want. Slots are
    #    numbered per interface, so this is not optional.
    withIface(uri, IUriRuntimeClass, it):

      # 4. An out HSTRING is yours to free; `takeString` converts and frees it.
      var h: HSTRING
      it.call(IUriRuntimeClass_get_Host, h.addr)
      echo "host: ", takeString(h)

when isMainModule:
  main()
