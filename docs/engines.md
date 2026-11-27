# Common game engines

Before searching memory from scratch, check whether the game shares an engine with a title already in `games/`. Games on the same engine usually share text encoding, control codes, speaker-name storage, and layout behaviour, even across different consoles. Remember: never copy addresses from another build; use the reference scripts only to understand the data layout and decoding logic.

## KID / 5pb. / MAGES. (Infinity, Science Adventure)

- **Reference scripts:** `games/ps1/memories-off/SLPS-02296.lua`, `games/ps2/never7/SLPS-25256.lua`, `games/ps2/ever17/SLPM-65421.lua`, `games/ps2/remember-11/SLPM-65550.lua`, `games/psp/steins-gate/ULJM05887.lua`, `games/psp/chaos-head-love-chu-chu/ULJM05821.lua`, `games/psp/dunamis15/ULJM06119.lua`, `games/switch/steins-gate/0100F160092D2000.lua`
- **Typical encoding:** Shift-JIS on PS1/PS2/PSP; UTF-8 or custom glyph-index streams on newer MAGES. Switch ports.
- **What to look for:** A fixed dialogue buffer or script pointer plus a visible-character counter and a window-open flag. Older KID titles use `%N` / `%P` / `%K` or `0x01`-prefixed control codes for line breaks, pauses, and ruby (`[base/ruby]` or `%R`). Speakers are often stored in a separate small buffer or prefixed with `「` / `【Name】`.

## Prototype / Visual Arts (RealLive, Siglus, LucaSystem)

- **Reference scripts:** `games/ps2/kanon/SLPS-20121.lua`, `games/ps2/clannad/SLPM-66302.lua`, `games/psp/flowers/ULJM06390.lua`, `games/psp/grisaia-no-kajitsu/ULJM06232.lua`, `games/switch/aiyoku-no-eustia/01001CC017BB2000.lua`
- **Typical encoding:** Shift-JIS or UTF-16LE (LucaSystem / Prototype Switch ports frequently use UTF-16LE).
- **What to look for:** A single current-line buffer updated as each line begins, often accompanied by a backlog ring buffer. Look for embedded ruby and colour escape sequences (`$`-prefixed or `$[...$/...$]` on LucaSystem).

## Chunsoft / Spike Chunsoft (Sound Novels, Danganronpa, Zero Escape)

- **Reference scripts:** `games/ps1/kamaitachi-no-yoru/SLPS-01794.lua`, `games/ps1/otogirisou/SLPS-01645.lua`, `games/nds/nine-hours-nine-persons-nine-doors/BSKJ.lua`, `games/psp/428-shibuya/ULJS00219.lua`, `games/psp/danganronpa/NPJH50372.lua`, `games/switch/danganronpa-v3/01001AB0140F2000.lua`, `games/switch/the-hundred-line/0100D9D021782000.lua`
- **Typical encoding:** Shift-JIS on PS1/DS/PSP; UTF-8 or UTF-16LE on Vita/Switch.
- **What to look for:** Danganronpa titles separate the active dialogue buffer from speaker IDs (a small integer indexing a character-name table) and use `<CLT N>` colour tags that should be stripped. Sound novels often keep a full-page text buffer; track the page/cursor index so only newly revealed text is emitted.

## Atlus (Shin Megami Tensei, Persona)

- **Reference scripts:** `games/ps2/shin-megami-tensei-nocturne/SLPM-65462.lua`, `games/ps2/digital-devil-saga/SLPM-65597.lua`, `games/ps2/persona-3/SLPM-66445.lua`, `games/ps2/persona-4/SLPM-66978.lua`, `games/3ds/shin-megami-tensei-iv/0004000000088A00.lua`
- **Typical encoding:** Custom `.charset` tables on PS2 (`F2`/`F1` control opcodes, 16-bit glyph indices) or UTF-8/Shift-JIS on 3DS.
- **What to look for:** Message boxes use Atlus BMD/BF bytecode with `0xF1`/`0xF2` control tags (line breaks, wait-for-input, speaker ID, player-name substitution). Check `games/ps2/persona-4/` and `games/ps2/shin-megami-tensei-nocturne/` for how Atlus control opcodes and `.charset` files are decoded.

## Capcom (Ace Attorney / MT Framework / RE Engine)

- **Reference scripts:** `games/3ds/layton-vs-ace-attorney/0004000000078B00.lua`, `games/3ds/phoenix-wright-ace-attorney-trilogy/0004000000108800.lua`, `games/switch/phoenix-wright-ace-attorney-trilogy/0100CB000A142000.lua`, `games/switch/apollo-justice-trilogy/010020D01B890000.lua`, `games/switch/great-ace-attorney-chronicles/0100D7F00FB1A000.lua`
- **Typical encoding:** UTF-16LE on 3DS and Switch.
- **What to look for:** A fixed 2- or 3-line display buffer populated character by character, plus a speaker ID and message-box visibility flag. Because dialogue types out incrementally, wait for the line to stabilize (or hook the message-start function) rather than emitting partial strings every frame.

## Falcom (Trails / Kiseki, Tokyo Xanadu)

- **Reference scripts:** `games/psp/sora-no-kiseki-fc/ULJM05170.lua`, `games/vita/sora-no-kiseki-fc/PCSG00488.lua`, `games/switch/tokyo-xanadu/010080C01AA22000.lua`
- **Typical encoding:** Shift-JIS on PSP; UTF-8 on Vita/Switch.
- **What to look for:** Dialogue buffers with `#N` / `#C` / `#0W` control sequences (speed, colour, portrait, voice ID) and a separate speaker-name field. Strip `#` tags before emitting.

## Square / Square Enix (Final Fantasy, Dragon Quest, Star Ocean)

- **Reference scripts:** `games/ps1/final-fantasy-vii/SLPS-00700.lua`, `games/ps1/final-fantasy-ix/SLPS-02000.lua`, `games/ps2/final-fantasy-x/SLPS-25088.lua`, `games/ps2/dragon-quest-v/SLPM-65555.lua`, `games/switch/dragon-quest-iii-hd-2d/01003E601E324000.lua`, `games/switch/star-ocean-2r/010065301A2E0000.lua`
- **Typical encoding:** Custom `.charset` tables on PS1/PS2; UTF-16LE or UTF-8 on Switch (Unreal Engine / Unity).
- **What to look for:** Classic PS1/PS2 titles map characters through a custom font table; modern Switch remakes typically run on Unity (IL2CPP) or Unreal Engine with standard UTF-16LE `FString` / `System.String` objects.

## Unity / IL2CPP (Modern Switch and Vita titles)

- **Reference scripts:** `games/switch/mahou-shoujo-no-majo-saiban/0100D20026E02000.lua`, `games/switch/star-ocean-2r/010065301A2E0000.lua`, `games/switch/super-mario-rpg/0100BC0018138000.lua`
- **Typical encoding:** UTF-16LE (`System.String` has length at `+0x10` and UTF-16LE characters starting at `+0x14` on 64-bit Switch, or `+0x08`/`+0x0C` on 32-bit Vita).
- **What to look for:** Check `python tools/agent.py hooks` first — 0xDC00's Agent scripts already cover a large number of Unity Switch/Vita games via TextMeshPro (`TMP_Text::set_text`) or Naninovel/Utage hooks. Strip Unity rich-text tags (`<color=...>`, `</color>`, `<size=...>`, `<ruby=...>`) before emitting.
