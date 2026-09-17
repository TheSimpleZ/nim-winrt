## Does a generated binding actually reach the Windows Runtime?
##
## Everything else in this package is declarations, and declarations compile
## whether or not they are right. This calls one, against a class Windows has
## had since Windows 8 and always has present, and checks the answer. A wrong
## IID fails `QueryInterface`; a wrong slot number calls the wrong function.

import std/unittest
import winrt
import winrt/foundation

suite "activation":
  setup:
    discard initApartment()

  test "a class activates and a vtable slot returns the right answer":
    let factory = activationFactory("Windows.Foundation.Uri",
                                    IID_IUriRuntimeClassFactory)
    check factory != nil
    defer: release(factory)

    var uri: pointer
    withHString("https://nim-lang.org/docs/manual.html", s):
      let create = factory.vcall(Slot_IUriRuntimeClassFactory_CreateUri,
                                 Fn_IUriRuntimeClassFactory_CreateUri)
      check create(factory, s, uri.addr).succeeded
    check uri != nil
    defer: release(uri)

    var host: HSTRING
    let getHost = uri.vcall(Slot_IUriRuntimeClass_get_Host,
                            Fn_IUriRuntimeClass_get_Host)
    check getHost(uri, host.addr).succeeded
    check $host == "nim-lang.org"
    discard windowsDeleteString(host)

  test "the runtime class name matches what was asked for":
    let factory = activationFactory("Windows.Foundation.Uri",
                                    IID_IUriRuntimeClassFactory)
    defer: release(factory)
    var uri: pointer
    withHString("https://example.com", s):
      let create = factory.vcall(Slot_IUriRuntimeClassFactory_CreateUri,
                                 Fn_IUriRuntimeClassFactory_CreateUri)
      discard create(factory, s, uri.addr)
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
