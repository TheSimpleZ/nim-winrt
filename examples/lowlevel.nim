## The layer underneath: a WinRT call by hand, through the ABI module.
##
##     nim c -r --path:src examples/lowlevel.nim
##
## This is what the generated API compiles into. Every call is the same steps:
## an interface pointer from the activation factory, the method as a field of
## that interface's vtable, a narrowing to the interface that declares the next
## method, and an out HSTRING that is yours to free.

import winrt
import winrt/abi/foundation

proc main() =
  discard initApartment()

  # 1. An interface pointer, from the activation factory. `factory` is a
  #    `ptr Iface[IUriRuntimeClassFactoryVtbl]`, so only that interface's
  #    methods can be called on it.
  withStatics("Windows.Foundation.Uri", IUriRuntimeClassFactory, factory):

    # 2. The method, as a field of the vtable. Every method returns an
    #    HRESULT, and its declared return is a trailing out-parameter.
    var uri: pointer
    withHString("https://nim-lang.org/docs/manual.html", s):
      check factory.vtbl.CreateUri(factory, s, uri.addr), "Uri.CreateUri"
    defer: release(uri)

    # 3. Narrow to the interface that declares the method you want. Methods
    #    are numbered per interface, so this is not optional.
    withIface(uri, IUriRuntimeClass, it):

      # 4. An out HSTRING is yours to free; `takeString` converts and frees it.
      var h: HSTRING
      check it.vtbl.get_Host(it, h.addr), "Uri.get_Host"
      echo "host: ", takeString(h)

when isMainModule:
  main()
