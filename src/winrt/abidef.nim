## The two calling contracts at the WinRT boundary.
##
## `include`d rather than imported, because a user pragma does not cross a
## module boundary in Nim — the standard library does the same thing with
## `std/system/inclrtl`. Every module that declares something callable from
## outside Nim includes this, so the contract is written once.

# `abi` — what a WinRT vtable slot is: a C function, called the Windows way,
# that neither raises a Nim exception nor touches Nim's heap.
#
# All three matter. `stdcall` is the ABI. `raises: []` is what lets `release`
# be called from a `=destroy` hook — a destructor may not raise, and without
# this Nim assumes anything reached through a function pointer might. `gcsafe`
# says the call cannot touch GC memory, which is true of a C function and which
# threaded code needs to know.
{.pragma: abi, stdcall, raises: [], gcsafe.}

# `callback` — what *we* hand to the runtime: a Nim proc the runtime calls.
#
# `raises: []` holds because every such proc catches everything before
# returning; a Nim exception unwinding into C is undefined. `gcsafe` is
# deliberately absent: these touch Nim globals, and claiming otherwise would be
# a lie the compiler cannot check for us. A callback that really is invoked
# from a foreign thread has to avoid the GC by construction — see `Completion`
# in `asyncops.nim`, which is why that one is hand-rolled.
{.pragma: callback, stdcall, raises: [].}
