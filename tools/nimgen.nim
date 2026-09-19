## Spelling metadata names as Nim source.
##
## Both generators emit Nim from the same metadata and so face the same naming
## problems: identifiers that are Nim keywords, names carrying characters Nim
## does not allow, and — the one that actually bites — Nim's identifier
## equality, which ignores underscores and case after the first character. The
## rules live here once so the two cannot answer them differently.

import std/[strutils, strformat]

const nimKeywords = [
  "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct",
  "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
  "for", "from", "func", "if", "import", "in", "include", "interface", "is",
  "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
  "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "result",
  "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using",
  "var", "when", "while", "xor"]

func sanitize*(name: string): string =
  ## A metadata name as a Nim identifier.
  ##
  ## Nim identifiers cannot contain `.` or start with a digit, `.ctor` turns up
  ## as a method name on delegates, and metadata contains names like
  ## `XamlChangeId._Reserved` that would otherwise produce a doubled underscore
  ## — which Nim rejects outright. Both ends are stripped because these names
  ## are concatenated onto a type name, where a leading underscore would double
  ## the separator.
  var s = name.multiReplace(("`", "_"), (".", "_"))
  for ch in s:
    if ch == '_' and result.len > 0 and result[^1] == '_': continue
    result.add ch
  result = result.strip(chars = {'_'})
  if result.len == 0 or result[0] in {'0' .. '9'}:
    result = "n" & result

func shortName*(full: string): string =
  ## `Windows.Foundation.Uri` -> `Uri`, sanitized.
  let dot = full.rfind('.')
  sanitize(if dot >= 0: full[dot + 1 .. ^1] else: full)

func lowerFirst*(s: string): string =
  ## Struct fields and properties are PascalCase in metadata. Nim compares
  ## identifiers case-insensitively *except* for the first character, so `Left`
  ## and `left` really are different names and the choice has to be deliberate.
  if s.len == 0: s else: toLowerAscii(s[0]) & s[1 .. ^1]

func escapeIdent*(s: string): string =
  ## `Duration.Type` is a real field name in the metadata and `type` is a Nim
  ## keyword; backticks are how Nim spells one anyway.
  if s.toLowerAscii in nimKeywords: "`" & s & "`" else: s

func nimIdent*(name: string): string =
  ## How Nim itself will see this identifier, for use as a table key.
  ##
  ## Nim compares identifiers with underscores removed and every character
  ## after the first folded to lower case. `Windows.UI.Text.ITextRange` really
  ## does declare both `get_Text` and `GetText`, and prefixed with `Slot_` those
  ## are one identifier to the compiler — the leading `S` is the only character
  ## whose case counts. A table keyed on the raw spelling sees no clash and
  ## emits a redefinition, so key on this instead.
  ##
  ## Pass the identifier as it will actually be written, prefix and all: the
  ## fragment `GetText` and the fragment `get_Text` differ in the character
  ## that is case-sensitive, and `Slot_GetText` and `Slot_get_Text` do not.
  for ch in name:
    if ch == '_': continue
    result.add (if result.len == 0: ch else: ch.toLowerAscii)

proc guidLiteral*(iid: string): string =
  ## A braced IID as the expression that builds it: `guid"..."`, parsed at
  ## compile time, which reads the way a GUID is written everywhere else.
  let text = iid.strip(chars = {'{', '}'})
  doAssert text.len == 36, "bad IID: " & iid
  "guid" & '"' & text & '"'

proc fill*(head: string, items: seq[string], tail = "", width = 80): string =
  ## `head`, then `items` joined by ", ", then `tail` — folded at `width`
  ## with continuation lines aligned under the first item, the way a Nim
  ## call or signature is usually wrapped by hand.
  var line = head
  let pad = ' '.repeat(head.len)
  for i, item in items:
    let piece = item & (if i < items.high: "," else: "")
    if line.len > head.len and line.len + 1 + piece.len > width:
      result.add line & "\n"
      line = pad & piece
    else:
      if line.len > head.len: line.add " "
      line.add piece
  result.add line & tail

proc topGroup*(ns: string): string =
  ## `Windows.Devices.Enumeration.Pnp` -> `Windows.Devices`.
  ##
  ## The split is by the second segment, not by full namespace. 342 namespaces
  ## would be 342 files for no gain — a namespace is a naming convention, not a
  ## unit anyone imports — while 18 groups line up with how the documentation
  ## is organised and how an app actually reaches for things.
  let parts = ns.split('.')
  if parts.len >= 2: parts[0] & "." & parts[1] else: ns

proc moduleName*(group: string): string =
  ## `Windows.ApplicationModel` -> `applicationmodel`.
  group.split('.')[^1].toLowerAscii
