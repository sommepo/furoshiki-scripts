# Furoshiki Scripts

Community game scripts for [Furoshiki](https://github.com/sommepo/furoshiki). Each script is a
single Lua file for one Japanese release that reads on-screen text directly from emulator memory,
enabling instant dictionary lookups over the game itself.

Furoshiki downloads and installs scripts from this repository automatically (Settings › Consoles ›
*Game scripts*) without needing an app update. Anyone can contribute support for a new game via a
pull request.

## Repository layout

Scripts are organized by console, with one folder per game named after it. Each script file is
named after the game's title/disc ID:

```
games/
  ps1/        PlayStation      kamaitachi-no-yoru/SLPS-01794.lua
  ps2/        PlayStation 2    silent-hill-2/SLPM-65051.lua
  psp/        PSP              steins-gate/ULJM05887.lua
  dreamcast/  Dreamcast        sakura-taisen/HDR-0072.lua
  3ds/        3DS              shin-megami-tensei-iv/0004000000088A00.lua
  nds/        DS               wish-room/AWIJ.lua
  vita/       PS Vita          sora-no-kiseki-fc/PCSG00488.lua
  switch/     Switch           steins-gate/0100F160092D2000.lua
```

The Switch's scripts are for builds of Furoshiki that have a Switch core. The published
releases have none.

To find a game, open its console's folder, or press `t` on GitHub and type part of its name.
A game with several discs or releases keeps all its scripts in its one folder, beside its
character name dictionary (`names-*.zip`, generated from VNDB data).

`scripts/` is what Furoshiki downloads: every console's scripts side by side with the list it
fetches (`index.json`). CI makes it from `games/` after every merge, so it is never edited by hand.

### Installing a script manually

Drop a `.lua` file into Furoshiki's local scripts folder, then launch the game (or choose *Reload
game script* from the Game menu):

| Platform | Scripts folder |
| --- | --- |
| Windows | `%LOCALAPPDATA%\Furoshiki\program\reader\profiles` |
| Linux | `~/.local/share/Furoshiki/program/reader/profiles` |
| Android | `Android/data/io.github.sommepo.furoshiki/files/reader/profiles` |

Local scripts take precedence over downloaded ones, so you can test or share an unmerged script
just by sending the `.lua` file.

### Trying a script before it's merged

Anyone can play a script from an open pull request with the Furoshiki they already have.
Nothing needs to be built or changed.

1. Open the pull request's **Files changed** tab. For each file in the game's folder, open the
   file's **⋯** menu, choose **View file**, then **Raw**, and save it.
2. Put the files in the scripts folder above, all side by side. The folder is flat: it does not
   have this repository's `games/<console>/<game>/` folders. Create it if it doesn't exist.

   ```
   profiles/
     SLPM-55281.lua          the script, named after the game's ID
     SLPM-55281.charset      its character table, if it has one
     names-clock-zero.zip    a names dictionary, if there is one
   ```

3. Start the game in Furoshiki. If it is already running, choose *Reload game script* from the
   Game menu.
4. Play a few scenes and say on the pull request what you saw: lines read or missed, speakers,
   choices, whether the popup opens on the word you point at, and which version of the game
   you have.

To go back, delete the files. Furoshiki then uses the downloaded or built-in script again.

On Android most file managers can't open `Android/data`. Copy the files over a USB cable
from a computer, with `adb push FILE /sdcard/Android/data/io.github.sommepo.furoshiki/files/reader/profiles/`,
or with a file manager that has been given access to that folder.

## Adding a game

Scripts are designed to be written with a coding agent (Claude Code, Codex, Gemini CLI, etc.) on
Windows, Linux, or macOS.

**Requirements:** Furoshiki 0.3.2+, Python 3.9+, a coding agent, and your own dump of the Japanese
release.

1. Clone this repository and start your agent inside it. You don't need a fork to write or play
   a script.
2. Tell the agent which game to add along with the paths to your dump and Furoshiki — for example:
   *"Add support for Steins;Gate on PSP. The game is at `D:\Games\PSP\steins-gate.iso` and
   Furoshiki is in `C:\Furoshiki`."*
3. The agent follows [AGENTS.md](AGENTS.md): it launches the game in Furoshiki, locates the text in
   memory, writes the Lua script, tests it in the running game, and reports what it verified.
4. Play through a few scenes yourself to check it (the agent saves the script directly into your
   local scripts folder).
5. To share it, have the agent open a pull request. Only the maintainer can push to this
   repository, so GitHub needs a copy of it under your account (a fork) to send the pull request
   from. The agent makes the fork for you if you don't have one. Once the pull request is merged,
   everyone can install the script from inside Furoshiki.

Under the hood, the agent drives Furoshiki via `tools/agent.py`, a zero-dependency Python CLI
(`python tools/agent.py --help`). On first run it can fetch 0xDC00's Agent scripts and LunaHook's
emulator tables locally with `python tools/agent.py fetch-hooks` (stored in `.agent/hooks/`, ignored
by Git) so `python tools/agent.py hooks` checks existing hook references before searching memory.

> **Custom fonts:** Games that number the characters of a font of their own instead of using
> Shift-JIS or Unicode need a character table beside their script (`<ID>.charset`): a text file
> saying which character each of the game's codes stands for. It holds no font pictures or game
> text, so it is published here with the script, and the agent makes one when the game needs it.

## Script guidelines

- **One file per game ID:** Multi-disc or multi-release titles get one `.lua` file per ID.
- **Metadata & build check:** Start with `-- reader: title`, `reads`, and `version` headers (see
  [docs/script-api.md](docs/script-api.md)) and verify the game build before reading memory.
- **Logic only:** Scripts may contain memory addresses and decoding logic only — no game text,
  images, or font data.
- **Clean checks:** `python tools/check.py` must report 0 problems (also enforced by CI on every
  PR).
- **Attribution:** When adapting hook addresses or decoding logic from an upstream project (such as
  Agent or LunaHook), credit the upstream project and the original script author (`@author`) in the
  script's header comments.

## Credits

This repository and Furoshiki's hook workflow build on the reverse-engineering work of the wider
Japanese game-reading community:

- **[0xDC00's Agent scripts](https://github.com/0xDC00/scripts)** and its individual script authors,
  whose Frida-based emulator hooks provide hook addresses and decoding references across PSP, PS2,
  PS Vita, 3DS, and Switch titles.
- **[LunaTranslator / LunaHook](https://github.com/HIllya51/LunaTranslator)** (by HIllya51 and
  contributors), whose emulator hook tables cover a wide range of Japanese console games.
- **Every contributor and script author** listed in the individual script headers and git history
  of this repository.

## Docs

- [AGENTS.md](AGENTS.md) — end-to-end guide for agents going from a game dump to a pull request.
- [docs/script-api.md](docs/script-api.md) — Lua script API reference.
- [docs/consoles.md](docs/consoles.md) — per-console CPU, coordinate space, and text encoding
  notes.

## Licence

Scripts and tools are licensed under the GNU General Public License v3 or later
([COPYING](COPYING)), matching Furoshiki. Character name dictionaries are licensed under the Open
Database License from VNDB ([NAMES-LICENSE](NAMES-LICENSE)).
