# General findings and workflow tips

Short, reusable techniques, traps, and shortcuts collected by contributors and agents while writing game scripts.

Keep this file scalable:
- Add only patterns that will help **future** games (never game-specific addresses or one-off notes).
- Put engine-specific formats in [engines.md](engines.md) and console-specific quirks in [consoles.md](consoles.md).
- Keep each entry to 2 to 4 lines.

## Finding text and pointers quickly

- **`text-diff` beats blind searching:** Take two snaps across a single line advance (`snap s1`, `press`, `snap s2`, `text-diff s1 s2`). In one pass it separates unwrapped text, wrapped text (with `\n`), typewriter buffers, and backlog entries.
- **Avoid stack buffers when reading per frame:** Buffers on the thread stack (often surrounded by `0xCC` padding) can shift by 4 or more bytes between lines. Instead, search the static data segment for a pointer to the heap copy of the same text, or a static `std::vector` (`begin`, `end`, `cap`) that holds the active message object.
- **Find menu-suppression flags in seconds:** Take one snap with dialogue visible and one with the in-game System Menu open, then diff the static data segment for `0 -> 1` flips. That usually narrows the candidates to 1 to 5 addresses immediately.

## Layout and Lua API gotchas

- **Leading fullwidth indents and `\n` wraps:** When a game inserts literal `\n` wrap markers and a leading fullwidth space (`　`, Shift-JIS `0x81 0x40`), strip the leading `　` from the emitted text while still advancing `x` by one cell on the first row. That keeps dictionary lookups and Anki cards clean while placing every overlay cell directly on its character.
- **Exact Lua API names:** Use `mem.cstr(addr, max)` (not `mem.cstring`) and `text.sjis(...)` / `text.utf8(...)` / `text.utf16le(...)` (not `text.decode`). Full reference: [script-api.md](script-api.md).
- **Skip `agent.py verify` save-state failures on cores without save states:** `verify` accepts `--gap` in either seconds (`1.5`) or milliseconds (`1500`), and skips save-state testing automatically on PS Vita.
