## An object of your own that Windows calls: an `IBuffer` over Nim bytes.
##
## Windows reads a buffer through two interfaces — `IBuffer` for the length
## and capacity, and the COM-side `IBufferByteAccess` for the bytes
## themselves — so the object implements both, and `QueryInterface` leads
## from one to the other. The bytes live in a Nim object that is `GC_ref`ed
## while Windows holds the buffer, and let go of by `dispose` once it does not.
##
## Build and run:
##   nim c -r --path:../src buffer.nim

import winrt/[storage, security]
include winrt/abidef          # the `abi` calling convention for the methods

# `IBufferByteAccess` is in no metadata, so it is declared here the way the
# generated ABI declares an interface: the IID beside the vtable, which is
# where `implement` reads it from.
const IID_IBufferByteAccess = guid"905A0FEF-BC53-11DF-8C49-001E4FC686DA"

type
  Bytes = ref object
    data: seq[byte]
  IBufferByteAccessVtbl = object of IUnknownVtbl
    Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.}

proc bytesOf(self: pointer): Bytes =
  ## The state behind `self`, from a method of either interface.
  cast[Bytes](stateOf(self))

proc newBuffer(bytes: Bytes): IBuffer =
  ## Hand `bytes` to Windows as a buffer, for as long as Windows keeps it.
  GC_ref(bytes)
  adopt[IBuffer](implement(
    IBufferVtbl(
      get_Capacity: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
        value[] = uint32(bytesOf(self).data.len)
        S_OK,
      get_Length: proc(self: pointer, value: ptr uint32): HRESULT {.abi.} =
        value[] = uint32(bytesOf(self).data.len)
        S_OK,
      put_Length: proc(self: pointer, length: uint32): HRESULT {.abi.} =
        bytesOf(self).data.setLen(length)
        S_OK),
    IBufferByteAccessVtbl(
      Buffer: proc(self: pointer, value: ptr ptr byte): HRESULT {.abi.} =
        value[] = bytesOf(self).data[0].addr
        S_OK),
    state = cast[pointer](bytes),
    dispose = proc(state: pointer) {.nimcall, raises: [].} =
      GC_unref(cast[Bytes](state))))

proc main() =
  let bytes = Bytes(data: @[byte 'h'.ord, 'i'.ord, '!'.ord])
  let buffer = newBuffer(bytes)

  # Windows queries the second interface off the first and reads through both.
  echo "as base64: ", CryptographicBuffer.encodeToBase64String(buffer)
  echo "length as Windows sees it: ", buffer.length
  echo "and back: ", CryptographicBuffer.convertBinaryToString(
    BinaryStringEncoding.Utf8, CryptographicBuffer.decodeFromBase64String(
      CryptographicBuffer.encodeToBase64String(buffer)))

when isMainModule:
  main()
