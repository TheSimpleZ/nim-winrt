## Does a generated binding actually reach the Windows Runtime?
##
## Everything else in this package is declarations, and declarations compile
## whether or not they are right. This calls one, against a class Windows has
## had since Windows 8 and always has present, and checks the answer. A wrong
## IID fails `QueryInterface`; a vtable field in the wrong place calls the
## wrong function.

import std/unittest
import winrt
import winrt/abi/foundation

suite "activation":
  setup:
    discard initApartment()

  test "a class activates and a vtable field calls the right method":
    withStatics("Windows.Foundation.Uri", IUriRuntimeClassFactory, factory):
      var uri: pointer
      withHString("https://nim-lang.org/docs/manual.html", s):
        check factory.vtbl.CreateUri(factory, s, uri.addr).succeeded
      check uri != nil
      defer: release(uri)

      withIface(uri, IUriRuntimeClass, it):
        var host: HSTRING
        check it.vtbl.get_Host(it, host.addr).succeeded
        check takeString(host) == "nim-lang.org"

  test "the vtable objects have the C layout":
    # Six inherited fields, then the interface's own, one pointer each. A
    # hidden type field or a padding byte anywhere here would shift every
    # method that follows.
    check sizeof(IInspectableVtbl) == 6 * sizeof(pointer)
    check offsetOf(IUriRuntimeClassVtbl, get_AbsoluteUri) == 6 * sizeof(pointer)
    check offsetOf(IUriRuntimeClassFactoryVtbl, CreateWithRelativeUri) ==
      7 * sizeof(pointer)

  test "the runtime class name matches what was asked for":
    withStatics("Windows.Foundation.Uri", IUriRuntimeClassFactory, factory):
      var uri: pointer
      withHString("https://example.com", s):
        discard factory.vtbl.CreateUri(factory, s, uri.addr)
      defer: release(uri)
      check uri.runtimeClassName == "Windows.Foundation.Uri"

  test "an unknown class fails with REGDB_E_CLASSNOTREG, not a crash":
    let (factory, hr) = tryActivationFactory("Windows.Foundation.NotAThing")
    check factory == nil
    check hr == REGDB_E_CLASSNOTREG

  test "asking for an interface a class does not implement returns nil":
    let factory = activationFactory("Windows.Foundation.Uri",
                                    IID_IUriRuntimeClassFactory)
    defer: release(factory)
    check factory.queryInterface(guid("00000000-0000-0000-C000-000000000047")) == nil
