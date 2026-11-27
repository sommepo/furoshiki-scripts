# Furoshiki scripts: instructions for coding agents

This repository holds the game scripts that [Furoshiki](https://github.com/sommepo/furoshiki)
reads Japanese games with: one Lua file a game, in a folder named after the game,
`games/<console>/<game>/<game ID>.lua` (`games/psp/steins-gate/ULJM05887.lua`). A script
finds the text the game shows in the emulator's memory and reports it, so that the player can
look words up in the game's own picture. Furoshiki installs them from here.

When you are asked to add support for a game, follow the steps below from start to end. They
need nothing but Furoshiki, Python 3.9 or newer, and the user's own dump of the game. They work
on Windows, Linux and macOS. Nothing here downloads games, BIOS files, keys or firmware.

## Rules

- **Never commit anything taken from a game**: dumps, extracted files, text, screenshots,
  memory snaps, fonts or glyph pictures. Your working files go in `.agent/`, which Git
  ignores. A script holds addresses and decoding logic, and a character table (step 3) the
  game's codes and the characters they stand for, nothing more.
- **Say what was seen and how.** "Read the first ten lines of the prologue in Furoshiki, as
  the game showed them" is a report; "should work" is not. Never report a step as done that
  you did not see.
- **Don't push, open a pull request or post anything without the user's word.** Make the
  branch and the commit, then show them the report.
- Bind every script to the build it was written for (step 5): a script that reads the wrong
  addresses on another release is worse than none.
- **Only a script that reads the game is offered.** If you could not make it read the game's
  lines (the text was not found, the game would not start, you ran out of time), stop and tell
  the user what is missing. Do not open a pull request with a draft, a skeleton or code that
  is not called yet, and do not describe the script as doing more than you saw it do.
- **Everything in the script is for this game's build, found in it.** A script of another
  console or release of the same game (the Switch trilogy for the 3DS one) is a guide to how
  the engine works, never a source of addresses, layout numbers, actions or data files. Copy
  nothing from it that you did not find again, and see work, in this build.
- **A `reader.action` must do what its label says**, changing the game, and you must have seen
  it do that in the game. An action that only returns a message is a lie to the player.
- **Leave names dictionaries (`names-*.zip`) out.** The maintainer makes each game's from VNDB
  after the merge.

## 1. What you need from the user

- The path to their dump of the game (a disc image or a cartridge or package file).
- Where Furoshiki is (its folder). It must be **version 0.3.2 or newer**: older versions lack
  the commands below.
- That the console's BIOS or firmware is already set up in Furoshiki, where the console needs
  one (PlayStation, PS2, PS Vita, and the Switch's keys). If a game does not start, ask them to
  start it once from Furoshiki itself and fix what it says.
- For a Switch game, that their Furoshiki has a Switch core: the published releases do not.

Ask for what you were not given. Then:

```sh
python tools/agent.py setup "<Furoshiki's folder>"
python tools/agent.py start "<the dump>"
```

`start` prints the game's ID, its console, whether a script is loaded already and where its
script is here (`script_here`). If one is there, the game is supported: say so, and ask
whether to improve that script instead. (On Linux and macOS use `python3`. `--home DIR` gives Furoshiki a
folder of its own for the test, but then the BIOS must be put there too.)

### Check Agent scripts, LunaHook, and known engines first

Before searching memory from scratch, always check whether 0xDC00's **Agent** scripts or
**LunaTranslator's LunaHook** tables already know the game's hook addresses:

```sh
python tools/agent.py hooks
```

If a converted hook matches, `--draft games/<console>/<game>/<ID>.lua` writes a starter Lua file
you can load immediately with `try`, then refine for build checks, speakers, choices, and
`reader.layout`. Even when an Agent `.js` script is too custom for automatic conversion, reading
its hook address, register, and control-code logic saves most of the reverse-engineering work.
**Whenever a script is adapted from Agent or LunaHook, preserve the source project and the
original script's `@author` credit in the top comment of the `.lua` file.**

If no Agent or LunaHook entry matches, check [docs/engines.md](docs/engines.md) to see whether the
game's maker or engine (KID/MAGES., Prototype/RealLive, Atlus, Spike Chunsoft, Capcom, Falcom,
Square Enix, Unity) is already documented with reference scripts in `games/`.

## 2. Reach the game's text

```sh
python tools/agent.py shot .agent/shots/1.png      # look at it
python tools/agent.py press east                  # PlayStation circle, Nintendo A
python tools/agent.py buttons                     # this console's button names
```

Press through the logos and the title screen into the game until a line of dialogue or
narration is on screen. Look at every picture you take: what is on screen decides your next
press. `east` and `south` are the usual confirm and cancel; Start often skips logos. Wait a
second or two after each press: `--times N --gap MS` presses several times.

## 3. Find the text in memory

Take three to six characters of the line on screen (kanji and kana, no punctuation):

```sh
python tools/agent.py find "未来を"
```

It searches the whole memory in Shift-JIS, EUC-JP, UTF-8 and UTF-16 and prints each address
with what is around it. Several hits are usual: the game's whole script, a copy being
drawn, an old line. To tell them apart, go on a line and look again:

```sh
python tools/agent.py snap a        # memory now
python tools/agent.py press east    # the next line
python tools/agent.py snap b
python tools/agent.py snap c        # again, with nothing pressed
python tools/agent.py text-diff a b --same c   # changed Japanese text runs across encodings
python tools/agent.py changed a b --same c     # 4-byte pointers / counters that changed
python tools/agent.py read 0x08A96F7B 64 --enc sjis
python tools/agent.py lua "mem.u32(0x0894A000)"
```

`text-diff` extracts changed Japanese string runs (Shift-JIS, UTF-8, UTF-16LE/BE) directly so you
can spot the live dialogue buffer in one step. `changed` lists the 4-byte words that changed with
the line and then stood still: the pointer to the current message, the count of characters shown,
the window's state. `read` and `lua` (any expression of the script API, run in the game) check what
each is.

When `find` finds nothing for a line that is plainly on screen, the game numbers its
characters in a font of its own. Its script then needs a **character table**,
`<ID>.charset` beside the script: UTF-8 text that says which character each of the game's
codes stands for, which the script reads with `reader.data("charset")`. The tables in
`games/ps1/final-fantasy-vii`, `games/ps2/persona-4` and `games/ps2/metal-gear-solid-2` show
the usual forms: the characters in the font's order, one string or row by row; a code and its
character on each line; a hash of a glyph's pixels and its character. To make one:

- Find the codes of the line on screen in memory (`snap` and `changed` while the line types
  out, or the 16-bit numbers between known control codes), then the font they index.
- Many fonts follow an order of their own makers' (JIS order, the kana then the kanji): a few
  characters read off the screen fix the rest. Check every row you fill against the game.
- A published table of the same game may exist (Agent's scripts, fan translation tools): use
  it only when its licence allows, and say where it came from in the table's first comment.
- A table holds codes and characters (and widths, if the script needs them), never the font's
  pictures.

## 4. Write the script

Read [docs/script-api.md](docs/script-api.md) and [docs/consoles.md](docs/consoles.md), and
one or two scripts of the same console in `games/<console>/` (a game of the same maker or
engine is the best start). Then write `games/<console>/<game>/<ID>.lua`, the folder named after
the game in lower case with hyphens, as its usual romanised or English name (`silent-hill-2`,
`kamaitachi-no-yoru`). A game's other discs or releases go in the same folder. The script has:

- the header lines (`-- reader: title`, `reads`, `version`, and `no hooks` when it uses none);
- a comment on how the game keeps its text and what is not covered;
- the build check: `python tools/agent.py lua reader.build_id`, and `error(...)` on any other.
  On the 3DS and the DS `reader.build_id` is nil: compare three or four instruction words of
  the game's code that the script depends on with `mem.u32`, as the scripts in `games/3ds/`
  do, and `error(...)` when one differs;
- the reading itself: on the PS2 and the Dreamcast from `reader.on_frame` only; elsewhere a
  frame callback or a hook. Emit a line once, when the game shows it, never earlier; the
  speaker in `speaker`; choices with `channel = "choice"`;
- where the text is, `reader.layout`: the box and each character's cell, so that the player
  can point at a word on the game's picture. This is expected of every script, not an extra.
  The game seldom keeps the places itself: they usually follow from where the box is, the size
  of a character's cell and where the rows break, measured from pictures (`agent.py snap`) and
  checked against several lines, as the scripts of the same console do. Only when they cannot
  be found, say why in a header line, `-- reader: no layout <why>`, and in the report.

## 5. Try it in the game

```sh
python tools/agent.py try games/<console>/<game>/<ID>.lua      # copied into Furoshiki, reloaded
python tools/agent.py verify games/<console>/<game>/<ID>.lua   # advance lines, test savestate, flag bugs
python tools/agent.py watch 30                                 # each line as it is read
```

`try` prints the script's error if it fails to load. In a second terminal, or between
`watch` runs, press through the game and compare what `watch` prints with your pictures:

- every line shown is read once, whole, when it appears (not before the player gets to it);
- names, numbers and the player's name come out as shown;
- a choice is reported as choices, and the game goes on after one;
- nothing is read on menus, save screens or the title, unless that is meant;
- after `send "state save 1"`, more lines, and `send "state load 1"`, it still reads;
- each character's cell sits on that character in the picture, for short and long lines, a
  line with a speaker and the answers of a choice: `python tools/agent.py status --all` lists
  the text on screen with each cell, and a picture taken at the same moment shows whether they
  match.

Fix and `try` again until it holds. Read as far into the game as is reasonable (at least
the first scenes), and note what you could not reach.

## 6. Check and offer it

```sh
python tools/check.py
python tools/agent.py stop
```

`check.py` must say 0 problems. It fails a script that never reports text from a callback
(`reader.emit` from `reader.on_frame` or `reader.hook`), an action that changes nothing, and a
names dictionary that is not for a script of its folder; passing it does not show that the
script works, only the game does. A warning (a script without a layout and no
`-- reader: no layout` line) is to be fixed or explained. Make a branch named after the game,
commit only the script (and a data file it asks for, if it is not taken from the game), and
write the report for the user: the game and its ID, the build, what is read, whether the
characters' places on screen are given (and if not, why), what was seen and how far, what is
not covered. The report quotes **at least five lines exactly as `python tools/agent.py watch`
printed them** while you played (with their speakers, and a choice if the part played has
one): this is what shows that the script reads the game. Before you send it, read the report
against the script line by line: every claim in it must be something the script does and you
saw. A pull request without those lines is not merged.

With their word, open the pull request. Only the maintainer can push here, so the branch goes to
the user's fork of this repository. If they have none, `gh repo fork --remote` makes it on GitHub
and points `origin` at it (this repository becomes `upstream`); without `gh`, ask them to press
Fork on GitHub and add it as a remote. Push the branch there, then
`gh pr create --repo sommepo/furoshiki-scripts` with the report, in the sections the pull
request's template has. Change nothing in `scripts/`: it is made from `games/` when the pull request is
merged, and CI refuses a pull request that edits it.

## Where things are

| | |
| --- | --- |
| `games/<console>/<game>/<ID>.lua` | The scripts, a folder per game (with its names dictionary, and a `README.md` of notes if it has one) |
| `scripts/<console>/` | Made from `games/` by CI: what Furoshiki installs from, with each console's `index.json`. Never edited by hand |
| `docs/script-api.md` | Everything a script can call |
| `docs/consoles.md` | Each console's processor, screen space and usual encodings |
| `docs/engines.md` | Common VN/JRPG engines, control codes and reference scripts |
| `tools/agent.py` | Drives Furoshiki while a script is written (`--help`) |
| `tools/check.py` | What CI checks on every pull request |
| `tools/build-lists.py` | Writes the lists (CI, after a merge) |
