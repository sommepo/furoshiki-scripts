#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check the scripts folder before a pull request is merged (CI runs it on every pull request).

    python tools/check.py            # every script
    python tools/check.py --lua luac # also compile each script with that Lua 5.4 compiler

What it holds a script to (README.md, "Rules for a script"):
- it is games/<console>/<game>/<ID>.lua: the console one of CONSOLES, the game's folder its
  name in lower case with hyphens (silent-hill-2, steins-gate), the ID the game's own as
  Furoshiki shows it (capitals, digits and hyphens), and no ID in two folders;
- it begins with its `-- reader: title`, `reads` and `version` lines;
- it is UTF-8 and smaller than 256 KB;
- nothing else is in a game's folder but the names dictionary (names-*.zip), a notes page
  (README.md) and data files a script asks for with reader.data(), each under 256 KB; a
  character table (<ID>.charset) is UTF-8 text: the game's codes and the characters they stand
  for, never the font's pictures.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONSOLES = {"ps1", "ps2", "psp", "dreamcast", "3ds", "nds", "vita", "switch"}
NAME = re.compile(r"^((?=[A-Z-]*[0-9])[A-Z0-9][A-Z0-9-]{3,15}|[A-Z]{4})\.lua$")
HEADER = re.compile(r"^--\s*reader:\s*(\S+)\s+(.*?)\s*$")
DATA = re.compile(r"""reader\.data\(\s*["']([A-Za-z0-9_.-]+)["']\s*\)""")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# A reader.layout call that gives a layout (not only `nil`, which takes one away).
LAYOUT = re.compile(r"reader\.layout\(\s*[^,()]+,(?!\s*nil\s*\))")
NO_LAYOUT = re.compile(r"^--\s*reader:\s*no layout\b", re.M)
API = re.compile(r"^--\s*reader:\s*api\s+(\d+)", re.M)
CALLBACK = re.compile(r"reader\.(?:on_frame|hook)\s*\(")
WRITES = re.compile(r"mem\.w(?:8|16|32|64)\s*\(")
LOCAL_FUNCTION = re.compile(r"\blocal\s+function\s+([A-Za-z_]\w*)")


def code_of(source):
    """The script without its comments, so that a word in a comment counts for nothing."""
    source = re.sub(r"--\[(=*)\[.*?\]\1\]", "", source, flags=re.S)
    return re.sub(r"--[^\n]*", "", source)


# Consoles whose core gives no reader.build_id (it is nil): their scripts check instruction words.
NO_BUILD_ID = {"3ds", "nds"}


def reading_problems(source, console):
    """What makes a script read nothing, or promise what it does not do: each one fails."""
    code = code_of(source)
    out = []
    if console in NO_BUILD_ID and "reader.build_id" in code:
        out.append("uses reader.build_id, which is nil on this console, so the script would never "
                   "load: check a few instruction words of the game's code instead (docs/consoles.md)")
    if "reader.emit" not in code:
        out.append("never reports any text (reader.emit): it would read nothing in the game")
    if not CALLBACK.search(code):
        out.append("registers no reader.on_frame or reader.hook, so nothing of it runs while the game plays")
    if "reader.action" in code:
        api = API.search(source)
        if not api or int(api.group(1)) < 3:
            out.append("uses reader.action without a `-- reader: api 3` line")
        if not WRITES.search(code):
            out.append("offers reader.action but never changes the game (mem.w8/w16/w32/w64): an action "
                       "must do what its label says, so leave it out until it does")
    return out


def reading_warnings(source):
    code = code_of(source)
    out = []
    unused = [name for name in LOCAL_FUNCTION.findall(code) if len(re.findall(rf"\b{name}\b", code)) < 2]
    if unused:
        out.append(f"defines functions it never calls ({', '.join(unused)}): finish them or take them out")
    if "error(" not in code:
        out.append("has no build check (an error(...) when the game is not the build it was written "
                   "for: reader.build_id, or instruction words on the 3DS and DS)")
    return out


def names_problem(zip_path, ids):
    """A names dictionary must be for a game of its folder (its index.json's furoshikiScope)."""
    try:
        with zipfile.ZipFile(zip_path) as archive:
            scope = json.loads(archive.read("index.json")).get("furoshikiScope", [])
    except (zipfile.BadZipFile, KeyError, ValueError) as error:
        return f"not a names dictionary that can be read ({error})"
    if not set(scope) & ids:
        return (f"is for {', '.join(scope) or 'no game'}, not for a script of this folder "
                f"({', '.join(sorted(ids))}): leave it out, the maintainer makes it after the merge")
    return None
LIMIT = 256 * 1024


def header(source):
    said = {}
    for raw in source.splitlines():
        line = raw.strip()
        if not line:
            continue
        if not line.startswith("--"):
            break
        match = HEADER.match(line)
        if match:
            said.setdefault(match.group(1), match.group(2))
    return said


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua", help="a Lua 5.4 compiler (luac) to check each script's syntax")
    args = parser.parse_args()
    luac = shutil.which(args.lua) if args.lua else None
    if args.lua and not luac:
        print(f"no {args.lua}", file=sys.stderr)
        return 2
    problems = []
    warnings = []
    scripts = 0
    seen = {}
    for console in sorted((ROOT / "games").iterdir()):
        if not console.is_dir():
            problems.append(f"games/{console.name}: only console folders belong in games/")
            continue
        if console.name not in CONSOLES:
            problems.append(f"games/{console.name}: not a console ({', '.join(sorted(CONSOLES))})")
            continue
        for game in sorted(console.iterdir()):
            here = f"games/{console.name}/{game.name}"
            if game.name == "README.md":
                continue  # the console's list of games, made by tools/build-lists.py
            if not game.is_dir():
                problems.append(f"{here}: a script goes in its game's folder, games/{console.name}/<game>/")
                continue
            if not SLUG.match(game.name):
                problems.append(f"{here}: name the folder after the game in lower case with hyphens")
            wanted = set()
            for path in sorted(game.glob("*.lua")):
                where = f"{here}/{path.name}"
                if not NAME.match(path.name):
                    problems.append(f"{where}: name it after the game's ID, e.g. ULJM05887.lua")
                    continue
                game_id = path.name[:-4]
                if game_id in seen:
                    problems.append(f"{where}: {game_id} is in {seen[game_id]} too")
                seen[game_id] = here
                data = path.read_bytes()
                if len(data) > LIMIT:
                    problems.append(f"{where}: larger than 256 KB")
                try:
                    source = data.decode("utf-8")
                except UnicodeDecodeError:
                    problems.append(f"{where}: not UTF-8")
                    continue
                said = header(source)
                for key in ("title", "reads", "version"):
                    if not said.get(key):
                        problems.append(f"{where}: no `-- reader: {key} ...` line among its first comments")
                if not LAYOUT.search(source) and not NO_LAYOUT.search(source):
                    warnings.append((where, "never says where its text is on screen (reader.layout), so the "
                                     "words cannot be pointed at on the game's picture; give a layout, or "
                                     "say why there is none in a `-- reader: no layout <why>` line"))
                problems.extend(f"{where}: {problem}" for problem in reading_problems(source, console.name))
                warnings.extend((where, warning) for warning in reading_warnings(source))
                wanted.update(f"{game_id}.{name}" for name in DATA.findall(source))
                scripts += 1
                if luac:
                    run = subprocess.run([luac, "-p", str(path)], capture_output=True, text=True)
                    if run.returncode != 0:
                        problems.append(f"{where}: {run.stderr.strip()}")
            if not any(game.glob("*.lua")):
                problems.append(f"{here}: no script in it")
            for path in sorted(game.iterdir()):
                name = path.name
                where = f"{here}/{name}"
                if path.is_dir():
                    problems.append(f"{where}: no folders inside a game's folder")
                elif re.match(r"^names-[a-z0-9-]+\.zip$", name):
                    problem = names_problem(path, {p.stem for p in game.glob("*.lua")})
                    if problem:
                        problems.append(f"{where}: {problem}")
                elif name.endswith(".lua") or name == "README.md":
                    continue
                elif name not in wanted:
                    problems.append(f"{where}: no script here asks for it (reader.data)")
                elif path.stat().st_size > LIMIT:
                    problems.append(f"{where}: larger than 256 KB")
                elif name.endswith(".charset"):
                    try:
                        path.read_bytes().decode("utf-8")
                    except UnicodeDecodeError:
                        problems.append(f"{where}: a character table is UTF-8 text")
    for problem in problems:
        print(problem)
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    for where, warning in warnings:
        # On GitHub the warning shows on the pull request's page, beside the file.
        print(f"::warning file={where}::{warning}" if annotate else f"warning: {where}: {warning}")
    print(f"{scripts} scripts, {len(problems)} problem(s), {len(warnings)} warning(s)", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
