# What differs from console to console

Every console runs the same script API ([script-api.md](script-api.md)). What differs is the
processor a hook sees, the space `reader.layout` works in, and what the games tend to do.

| Console | Folder | Game ID (as `status` shows it) | Hooks | A hook's registers | Layout space |
| --- | --- | --- | --- | --- | --- |
| PlayStation | `games/ps1` | `SLPS-01234` | yes | MIPS: `zero at v0 v1 a0`…`a3 t0`…`t9 s0`…`s7 k0 k1 gp sp fp ra`, `pc` | 1280×720, the whole picture |
| PlayStation 2 | `games/ps2` | `SLPM-65051` | **no**: `reader.on_frame` only | | 1280×720, the whole picture |
| PSP | `games/psp` | `ULJM05887` | yes | MIPS, as the PlayStation's | 1280×720 (`space = {480, 272}` for the game's own pixels) |
| Dreamcast | `games/dreamcast` | `T14301M`, `HDR-0072` | **no**: `reader.on_frame` only | | 1280×720, the whole picture |
| 3DS | `games/3ds` | `0004000000088A00` | yes | ARM: `r0`…`r12 sp lr pc`, `s0`…`s31`, `d0`…`d15` | top screen 400×240, `screen = "bottom"` 320×240 |
| DS | `games/nds` | `AWIJ` (the cartridge's game code) | yes | ARM9: `r0`…`r12 sp lr pc` | each screen 256×192 |
| PS Vita | `games/vita` | `PCSG00488` | yes | ARM, as the 3DS's; the program's addresses are `reader.base` plus an offset | 960×544 |
| Switch | `games/switch` | `0100F160092D2000` (the title ID) | yes | ARM64: `x0`…`x30`, `w0`…`w30` for their low halves, `sp lr pc`; the program's addresses are `reader.base` plus an offset | 1280×720 |

`reader.build_id` names the game's build on every console but the **3DS and the DS**, where
it is nil: a script there binds itself to its build by checking a few instruction words of the
game's code (`mem.u32(address) ~= word`), as `games/3ds/` does. `tools/check.py` fails a 3DS or
DS script that uses `reader.build_id`.

All of them are little-endian: `mem.u16` and `mem.u32` read the game's numbers as they are.

## Text encodings

Most Japanese games keep their text as **Shift-JIS** (`text.sjis`), often with control codes
between the characters (a byte or two below 0x20, or a sequence the game reserves for colour,
pauses, the player's name, furigana). Newer games use UTF-8 or **UTF-16** (`text.utf16le`);
some PS1 and PS2 games and many DS games number the characters of their own font instead
(a "character table"). `python tools/agent.py find "TEXT"` tries Shift-JIS, EUC-JP, UTF-8 and
both UTF-16s. When none finds a line that is plainly on screen, the game has a font of its
own, and its script needs a character table beside it (`<ID>.charset`, read with
`reader.data("charset")`): [AGENTS.md](../AGENTS.md), step 3, says how one is made, and the
PlayStation and PS2 folders have 25 examples.

## Hints by console

- **PlayStation, PSP**: the text is usually in main RAM as Shift-JIS while it is drawn. A
  frame callback that watches the message buffer and the count of characters shown is often
  enough; a hook on the routine that draws one character gives exact positions.
- **PS2, Dreamcast**: no hooks, so everything is read from memory each frame: find the
  message buffer, a value that says how much is shown or whether the window is open, and
  where the box is.
- **3DS, DS, Vita**: games are ARM code. A hook on the function that sets a message (its
  argument a pointer to the text, often UTF-16) is the usual way; bind it to the build by
  checking a few instruction words, as the 3DS scripts do.
- **Switch**: games are ARM64 code loaded at `reader.base`. Many read memory from
  `reader.on_frame` and hook nothing (`-- reader: no hooks`); where a hook is used, the object
  is usually in `x0` and its arguments from `x1`. A game built on an engine (Unity, RE Engine,
  Artemis) keeps its text in the engine's own strings, often UTF-16.

The scripts in each folder are worked examples of these.
