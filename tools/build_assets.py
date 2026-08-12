#!/usr/bin/env python3
"""Build assets/cards.json, assets/decks.json and assets/CardImages/ from two inputs.

The inputs are a marvelsdb-json-data checkout, which is authoritative for every fact
about a card but carries no art, and a Tabletop Simulator save of the community's
high-resolution scans, which is authoritative for art but records no card codes. The
join between them is the interesting part of this script and lives in match_cards().

Everything here is re-runnable. Steam's sheet URLs are content-addressed hashes, so a
sheet whose contents change arrives as a new URL and a sheet that has not changed is
already in the cache. That is what makes an update after a new hero pack cost a handful
of megabytes rather than the four gigabytes the first run costs.

Data quirks are settled here rather than in the app. If a widget needs a special case
for a particular card, the special case belongs in this file instead.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
JSON_DATA = Path(
    os.environ.get("MC_JSON_DATA", Path.home() / "Documents" / "marvelsdb-json-data")
)
TTS_SAVE = Path(os.environ.get("MC_TTS_SAVE", ROOT / "2665262903.json"))

ASSETS = ROOT / "assets"
IMAGES = ASSETS / "CardImages"

# Not build/: that belongs to Flutter, and `flutter clean` deletes it. The sheet cache
# under here is 9.2 GB and four hours of downloading, which a routine clean would take
# with it.
BUILD = ROOT / ".cache"
CACHE_DIR = Path(os.environ.get("MC_CACHE_DIR", BUILD / "sheets"))

QUALITY = 80
METHOD = 4

# Steam rejects HEAD outright and drops most parallel GETs: measured, three of eight
# concurrent requests succeeded while sequential requests never failed. So downloads
# are serial and a Range probe stands in for the HEAD that does not work.
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
FETCH_RETRIES = 6
FETCH_BACKOFF = 4.0
FETCH_TIMEOUT = 300

# A card object in a TTS save is one of these two. Everything else in the tree is a bag,
# a deck, a token or table furniture.
CARD_NAMES = ("Card", "CardCustom")

# Cards printed sideways. marvelsdb does not record orientation, so the TTS
# SidewaysCard flag is the only source for it, and the app needs it to size a row.
LANDSCAPE_TYPES = {
    "main_scheme",
    "side_scheme",
    "player_side_scheme",
    "environment",
}


def log(msg: str = "") -> None:
    print(msg, flush=True)


def die(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# Input loading
# ---------------------------------------------------------------------------


def git_state(repo: Path) -> dict:
    """Report the checked-out commit, and whether origin is ahead.

    Read-only on purpose. Pulling would mutate a repository outside this project and
    would fail in confusing ways when it has local changes, so staleness is reported
    and the pull is left to the operator.
    """

    def run(*args: str) -> str | None:
        try:
            out = subprocess.run(
                ["git", "-C", str(repo), *args],
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        return out.stdout.strip() if out.returncode == 0 else None

    commit = run("rev-parse", "--short", "HEAD")
    if commit is None:
        return {"commit": None}

    state = {
        "commit": commit,
        "date": run("log", "-1", "--format=%ad", "--date=short"),
        "subject": run("log", "-1", "--format=%s"),
    }

    behind = run("rev-list", "--count", "HEAD..origin/master")
    if behind and behind.isdigit() and int(behind) > 0:
        state["behind"] = int(behind)
    return state


def load_reference() -> dict:
    """Load the small lookup tables: packs, sets, factions, types."""
    ref = {}
    for name in ("packs", "sets", "factions", "types", "packtypes", "settypes"):
        path = JSON_DATA / f"{name}.json"
        if not path.exists():
            die(f"{path} is missing; is MC_JSON_DATA pointing at marvelsdb-json-data?")
        ref[name] = json.loads(path.read_text(encoding="utf-8"))
    return ref


def load_pack_cards() -> list[dict]:
    """Every card record across pack/*.json, in a stable order."""
    pack_dir = JSON_DATA / "pack"
    if not pack_dir.is_dir():
        die(f"{pack_dir} is missing; is MC_JSON_DATA pointing at marvelsdb-json-data?")

    cards: list[dict] = []
    for path in sorted(pack_dir.glob("*.json")):
        cards.extend(json.loads(path.read_text(encoding="utf-8")))
    if not cards:
        die(f"no cards found under {pack_dir}")
    return cards


def load_save() -> dict:
    if not TTS_SAVE.exists():
        die(f"{TTS_SAVE} is missing; set MC_TTS_SAVE to the Tabletop Simulator save")
    return json.loads(TTS_SAVE.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Walking the Tabletop Simulator save
# ---------------------------------------------------------------------------


@dataclass
class TTSCard:
    """One card object in the save, with the sheet cell its art comes from."""

    nickname: str
    path: tuple[str, ...]
    card_id: int
    sideways: bool
    face_url: str
    back_url: str
    unique_back: bool
    num_width: int
    num_height: int
    index: int
    ordinal: int = 0
    private_back: bool = False

    @property
    def key(self) -> str:
        """The identity used by the override map.

        Deliberately not the sheet cell. A re-scan gives a sheet a new content-addressed
        URL, which would orphan every override keyed on a cell; a rename orphans one
        entry instead, and the script reports those.

        The ordinal separates cards a bag holds several of under one name, which is how
        a villain's three stages are stored. Distinct copies of one card share an
        ordinal, so an ordinary three-of does not turn into three override entries.
        """
        suffix = f" #{self.ordinal}" if self.ordinal else ""
        return f"{self.nickname}@{' / '.join(self.path)}{suffix}"

    @property
    def face_cell(self) -> tuple[str, int]:
        return (self.face_url, self.index)

    @property
    def back_cell(self) -> tuple[str, int] | None:
        """The cell holding the other side, when the card has one.

        UniqueBack means BackURL is a second sheet laid out like the first, so the back
        of this card sits at the same index.

        A false UniqueBack does *not* mean there is no back art. It means so for the
        eight sheets that are a deck's shared card back, and not at all for the 132
        1x1 sheets each of which is one card's own scanned back with the flag simply
        wrong -- The Break-In! 01097b among them. `private_back` tells the two apart;
        see `_mark_private_backs`.
        """
        if self.unique_back or self.private_back:
            return (self.back_url, self.index)
        return None


def walk_save(save: dict) -> list[TTSCard]:
    """Collect every card object, descending into containers and states.

    States hold alternate faces of a card (a transformed villain, a flipped hero) and
    are keyed by a number rather than held in a list, so they need walking separately.
    """
    found: list[TTSCard] = []

    def visit(objects: list[dict], path: tuple[str, ...]) -> None:
        for obj in objects:
            nickname = (obj.get("Nickname") or "").strip()

            if obj.get("Name") in CARD_NAMES:
                found.append(_read_card(obj, nickname, path))

            children = obj.get("ContainedObjects") or []
            if children:
                visit(children, path + (nickname or obj.get("Name", "?"),))

            for state_key, state in (obj.get("States") or {}).items():
                visit([state], path + (nickname or "?", f"state{state_key}"))

    visit(save.get("ObjectStates") or [], ())
    _number_duplicates(found)
    _mark_private_backs(found)
    return found


def _mark_private_backs(cards: list[TTSCard]) -> None:
    """Find the BackURLs that are one card's own back rather than a deck's card back.

    `UniqueBack` is the flag for this and it is wrong for 132 sheets, which is why every
    main scheme's second stage and every alter-ego's portrait were missing. Reading it
    alone leaves them out; ignoring it entirely crops a deck's card back thousands of
    times over.

    What separates them is arithmetic over the whole save, not anything on one object:

        distinct face cells sharing a BackURL     sheets
                                            1        132   one card's own back
                                          3-6          5   a small deck's shared back
                                    161-1,023          8   the real card backs

    Nothing lands between 6 and 161, so the rule is the low end of that gap: a 1x1 sheet
    reached by exactly one face cell. Both halves matter -- the four aspect trackers are
    1x1 and their "back" is their own face sheet again, and the five 2x2 and 3x2 sheets
    in the 3-6 band are shared backs for a handful of Civil War and Hero for Hire cards.
    """
    faces_per_back: dict[str, set[tuple[str, int]]] = defaultdict(set)
    for card in cards:
        if not card.unique_back:
            faces_per_back[card.back_url].add(card.face_cell)

    for card in cards:
        card.private_back = (
            not card.unique_back
            and (card.num_width, card.num_height) == (1, 1)
            and len(faces_per_back[card.back_url]) == 1
        )


def _number_duplicates(cards: list[TTSCard]) -> None:
    """Give each distinct card sharing a name within one bag its own ordinal.

    A deck holding three copies of one card and a deck holding a villain's three stages
    look alike until the art is consulted: the copies all point at one sheet cell and
    the stages at three. So cells are numbered, in the order the save lists them, and
    copies of a cell share its number.
    """
    grouped: dict[tuple[tuple[str, ...], str], list[TTSCard]] = defaultdict(list)
    for card in cards:
        grouped[(card.path, card.nickname)].append(card)

    for group in grouped.values():
        order: dict[tuple[str, int], int] = {}
        for card in group:
            ordinal = order.setdefault(card.face_cell, len(order) + 1)
            # A single distinct card needs no ordinal, which keeps the common case
            # readable and its override entries stable.
            card.ordinal = ordinal
        if len(order) < 2:
            for card in group:
                card.ordinal = 0


def _read_card(obj: dict, nickname: str, path: tuple[str, ...]) -> TTSCard:
    decks = obj.get("CustomDeck") or {}
    if len(decks) != 1:
        die(
            f"card {nickname!r} at {'/'.join(path)} has {len(decks)} CustomDeck entries; "
            "this script assumes exactly one"
        )

    # The sheet is read from CustomDeck rather than by slicing CardID. They disagree for
    # 473 of the 4,838 objects in the current save, and CustomDeck is the one TTS uses.
    (_key, sheet), = decks.items()
    card_id = int(obj["CardID"])
    index = card_id % 100

    width = int(sheet["NumWidth"])
    height = int(sheet["NumHeight"])
    if not 0 <= index < width * height:
        die(f"card {nickname!r} index {index} is outside its {width}x{height} sheet")

    return TTSCard(
        nickname=nickname,
        path=path,
        card_id=card_id,
        sideways=bool(obj.get("SidewaysCard")),
        face_url=sheet["FaceURL"],
        back_url=sheet["BackURL"],
        unique_back=bool(sheet.get("UniqueBack")),
        num_width=width,
        num_height=height,
        index=index,
    )


def sheet_grids(cards: list[TTSCard]) -> dict[str, tuple[int, int]]:
    """Map every sheet URL that carries card art to its grid.

    A sheet used as a plain card back is skipped: it holds one image repeated for a
    whole deck, and cropping it would produce thousands of identical files.
    """
    grids: dict[str, tuple[int, int]] = {}

    def record(url: str, grid: tuple[int, int], card: TTSCard) -> None:
        seen = grids.setdefault(url, grid)
        if seen != grid:
            die(f"sheet {url} is described as both {seen} and {grid} (at {card.key})")

    for card in cards:
        grid = (card.num_width, card.num_height)
        record(card.face_url, grid, card)
        if card.back_cell is not None:
            record(card.back_url, grid, card)

    return grids


# ---------------------------------------------------------------------------
# Matching TTS card objects to marvelsdb card codes
# ---------------------------------------------------------------------------

# Names drift between the scans and the database: curly quotes against straight ones,
# "and" against "&", and a handful of outright misspellings in the save. Folding to
# bare alphanumerics absorbs the punctuation; the misspellings need the override map.
_AND = re.compile(r"\s*&\s*")
_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def fold_name(raw: str) -> str:
    text = unicodedata.normalize("NFKD", raw or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = _AND.sub(" and ", text.lower())
    return _NON_ALNUM.sub("", text)


@dataclass
class MatchResult:
    resolved: dict[str, str] = field(default_factory=dict)  # override key -> code
    ignored: set[str] = field(default_factory=set)  # keys deliberately not cards
    unmatched: list[dict] = field(default_factory=list)
    stats: Counter = field(default_factory=Counter)
    stale_overrides: list[str] = field(default_factory=list)


def match_cards(
    tts_cards: list[TTSCard], mdb_cards: list[dict], ref: dict, overrides: dict
) -> MatchResult:
    """Resolve every TTS card object to a marvelsdb code.

    Three stages, tried in order. A unique name match settles most of the collection.
    Where a name is shared -- and hundreds are, because an ally, a minion and a hero can
    all be called Hawkeye -- the containing bag names the set or the pack, and structural
    facts narrow it further. What survives both needs a human, and gets one via the
    override map rather than a guess.
    """
    result = MatchResult()

    named = [c for c in mdb_cards if c.get("name")]
    by_name: dict[str, list[dict]] = defaultdict(list)
    for card in named:
        by_name[fold_name(card["name"])].append(card)

    set_names = {s["code"]: s["name"] for s in ref["sets"]}
    pack_names = {p["code"]: p["name"] for p in ref["packs"]}

    # One entry per distinct override key rather than per object: the same card in the
    # same bag appears once per physical copy, and they all resolve identically.
    seen: dict[str, TTSCard] = {}
    for card in tts_cards:
        seen.setdefault(card.key, card)

    stages = _stage_matches(tts_cards, by_name, overrides)

    for key, card in seen.items():
        if key in overrides:
            code = overrides[key]
            if code is None:
                result.ignored.add(key)
                result.stats["ignored"] += 1
            else:
                result.resolved[key] = code
                result.stats["override"] += 1
            continue

        candidates = by_name.get(fold_name(card.nickname), [])
        if len(candidates) == 1:
            result.resolved[key] = candidates[0]["code"]
            result.stats["by name"] += 1
            continue

        if not candidates:
            candidates = _by_near_name(card, by_name, set_names, pack_names)
            if len(candidates) == 1:
                result.resolved[key] = candidates[0]["code"]
                result.stats["by near name"] += 1
                continue

        if candidates:
            narrowed = _narrow(candidates, card, set_names, pack_names)
            if len(narrowed) == 1:
                result.resolved[key] = narrowed[0]["code"]
                result.stats["by context"] += 1
                continue

            sides = _one_card_many_codes(narrowed or candidates)
            if sides is not None:
                result.resolved[key] = sides
                result.stats["by front side"] += 1
                continue

            if key in stages:
                result.resolved[key] = stages[key]
                result.stats["by stage"] += 1
                continue

            candidates = narrowed or candidates

        result.unmatched.append(
            {
                "key": key,
                "nickname": card.nickname,
                "bag": " / ".join(card.path),
                "sideways": card.sideways,
                "two_sided": card.unique_back,
                "candidates": [
                    {
                        "code": c["code"],
                        "name": c.get("name"),
                        "type": c.get("type_code"),
                        "pack": pack_names.get(c.get("pack_code"), c.get("pack_code")),
                        "set": set_names.get(c.get("set_code")),
                    }
                    for c in candidates
                ],
            }
        )
        result.stats["unmatched"] += 1

    result.stale_overrides = sorted(set(overrides) - set(seen))
    return result


def _stage_matches(
    tts_cards: list[TTSCard],
    by_name: dict[str, list[dict]],
    overrides: dict,
) -> dict[str, str]:
    """Resolve a run of same-named cards by their order in the deck.

    Several kinds of card come as a numbered run sharing one name: a villain's stages,
    a campaign's leaders, the five Hypnotic Gaze attachments, a scenario's main schemes.
    The name alone cannot say which is which, but the deck holds them in printed order
    and TTS lists a deck top-down, so the nth distinct scan is the nth printed card.

    Applied only when the deck holds exactly as many distinct scans as there are printed
    cards. A deck with some of them says nothing reliable about which, and is left for
    the override map.
    """
    in_bag: dict[tuple[str, ...], list[TTSCard]] = defaultdict(list)
    for card in tts_cards:
        in_bag[card.path].append(card)

    resolved: dict[str, str] = {}
    for cards in in_bag.values():
        grouped: dict[str, list[TTSCard]] = defaultdict(list)
        for card in cards:
            grouped[card.nickname].append(card)

        for nickname, copies in grouped.items():
            # One entry per distinct card, in the order the save lists them. Duplicates
            # of one card share an ordinal and must not consume a place in the run.
            distinct: dict[str, TTSCard] = {}
            for card in copies:
                distinct.setdefault(card.key, card)
            if len(distinct) < 2:
                continue
            if any(key in overrides for key in distinct):
                continue

            run = _printed_run(by_name.get(fold_name(nickname), []), len(distinct))
            if run is None:
                continue

            for card, record in zip(distinct.values(), run):
                resolved[card.key] = record["code"]

    return resolved


def _printed_run(candidates: list[dict], wanted: int) -> list[dict] | None:
    """The one set of `wanted` same-named cards that a deck could be holding.

    Candidates are grouped by the set they were printed in, because a name reused in a
    later expansion is a different card rather than another step in this run. Exactly
    one group of the right size means the deck is holding that group; anything else is
    ambiguous and belongs in the override map.
    """
    by_set: dict[str | None, list[dict]] = defaultdict(list)
    for card in candidates:
        by_set[card.get("set_code")].append(card)

    runs = [
        sorted(group, key=lambda c: c["code"])
        for group in by_set.values()
        # A run is one kind of card printed several times over. A name shared by an ally
        # and a hero is a collision, not a run, and its ordering means nothing.
        if len(group) == wanted and len({c.get("type_code") for c in group}) == 1
    ]
    return runs[0] if len(runs) == 1 else None


def _one_card_many_codes(candidates: list[dict]) -> str | None:
    """Collapse a two-sided card's pair of codes to its front.

    A linked pair -- 11007a with back_link 11007b -- is one card printed on two sides,
    and a scan of it is a scan of its front. That is the only shape a lettered run
    collapses on.

    A lettered run with *no* links does not collapse, however much it looks like one
    card in several artworks. 01043a-d, Wakanda Forever!, is the case that proves it:
    four codes, one name, one type, no links -- and four physically different cards,
    which a Black Panther deck holds all of at once because they differ by resource
    pip. Collapsing them sent all four, plus Shuri's separate 51005, to 01043a, and
    since every one of them then wrote the same filename the last crop won and the
    other four were left wearing its art. Every run this branch ever collapsed turned
    out to be that: pips on Wakanda Forever!, Firecracker, Flash of Light, Plasmoid
    Energy and Photographic Reflexes; differing text on Android Efficiency. Not one
    was a card printed twice.
    """
    if len(candidates) != 2:
        return None
    stems = {c["code"][:5] for c in candidates}
    if len(stems) != 1:
        return None
    if not all(len(c["code"]) == 6 for c in candidates):
        return None

    first = min(candidates, key=lambda c: c["code"])
    others = {c["code"] for c in candidates} - {first["code"]}

    return first["code"] if first.get("back_link") in others else None


def _by_near_name(
    card: TTSCard,
    by_name: dict[str, list[dict]],
    set_names: dict[str, str],
    pack_names: dict[str, str],
) -> list[dict]:
    """Recover cards the save misspells, without inventing matches.

    The scans carry a scattering of typos -- Missle Launcher, Fanatacism, Petulent Pig,
    a capital I standing in for the l in Ultron -- and a few deliberate rewordings. A
    close name is only trusted when the card also sits in the bag for its own set or
    pack, so a typo cannot pull in a similarly named card from elsewhere in the game.
    """
    needle = fold_name(card.nickname)
    if len(needle) < 6:
        return []

    context = fold_name(" ".join(card.path))
    close: list[dict] = []
    for folded, cards in by_name.items():
        if abs(len(folded) - len(needle)) > 2 or _edits_within(needle, folded, 2) is False:
            continue
        for candidate in cards:
            set_name = set_names.get(candidate.get("set_code") or "\0")
            pack_name = pack_names.get(candidate.get("pack_code") or "\0")
            in_context = (set_name and fold_name(set_name) in context) or (
                pack_name and fold_name(pack_name) in context
            )
            if in_context:
                close.append(candidate)

    # Distinct printings of one card are one answer, not an ambiguity.
    unique = {c["code"]: c for c in close}
    return list(unique.values())


# A card belongs to a player if its faction is an aspect or the hero's own. Encounter
# and campaign cards belong to the game. marvelsdb spells this as the faction code.
_ENCOUNTER_FACTIONS = {"encounter", "campaign"}

# Words in a bag name that say which side of the table its cards sit on.
_PLAYER_BAGS = ("hero deck", "hero set", "aspect", "market", "invocation", "identity")
_ENCOUNTER_BAGS = (
    "encounter",
    "nemesis",
    "villain",
    "modular",
    "main scheme",
    "obligation",
    "set-aside",
    "setup",
)


# Bags whose name states the type of card they hold. Ordered longest-first so
# "Player Side Schemes" is not matched as "Side Schemes".
_BAG_TYPES: tuple[tuple[str, frozenset[str]], ...] = (
    ("player side scheme", frozenset({"player_side_scheme"})),
    ("main scheme", frozenset({"main_scheme"})),
    ("side scheme", frozenset({"side_scheme"})),
    ("environment", frozenset({"environment"})),
    ("obligation", frozenset({"obligation"})),
    ("attachment", frozenset({"attachment"})),
    ("treacher", frozenset({"treachery"})),
    ("upgrade", frozenset({"upgrade"})),
    ("support", frozenset({"support"})),
    ("resource", frozenset({"resource"})),
    ("minion", frozenset({"minion"})),
    ("event", frozenset({"event"})),
    ("all", frozenset({"ally"})),
    # A villain bag holds the villain's own stages, and often a main scheme with them.
    ("villain", frozenset({"villain", "main_scheme"})),
)


def _bag_type(path: tuple[str, ...]) -> frozenset[str] | None:
    for name in reversed(path):
        lowered = name.lower()
        for word, types in _BAG_TYPES:
            if word in lowered:
                return types
    return None


# The aspects a bag can be named after. Deadpool's aspect is printed 'Pool and folds to
# "pool", which is also a substring of nothing else, so a plain search is safe.
_ASPECTS = ("aggression", "justice", "leadership", "protection", "basic", "pool")


_OWNER_BAG = re.compile(
    r"^(?P<who>.+?)(?:'s|')?\s+(?:hero pack|scenario pack|hero deck|hero set|nemesis set)$",
    re.IGNORECASE,
)


def _bag_owner(path: tuple[str, ...]) -> str | None:
    """The character a bag is named for, folded. Outermost first: the pack owns the set."""
    for name in path:
        match = _OWNER_BAG.match(name.strip())
        if match:
            return fold_name(match.group("who"))
    return None


def _bag_aspect(path: tuple[str, ...]) -> str | None:
    for name in reversed(path):
        lowered = name.lower()
        for aspect in _ASPECTS:
            if aspect in lowered:
                return aspect
    return None


def _is_player_card(card: dict) -> bool:
    return (card.get("faction_code") or "encounter") not in _ENCOUNTER_FACTIONS


def _bag_role(path: tuple[str, ...]) -> bool | None:
    """True if the innermost bag holds player cards, False if encounter, None if unclear.

    Read innermost-first: a nemesis set inside a hero pack is encounter cards, and the
    hero pack around it must not overrule that.
    """
    for name in reversed(path):
        lowered = name.lower()
        if any(word in lowered for word in _ENCOUNTER_BAGS):
            return False
        if any(word in lowered for word in _PLAYER_BAGS):
            return True
    return None


def _edits_within(a: str, b: str, limit: int) -> bool:
    """Bounded Levenshtein: is a within `limit` edits of b?"""
    if abs(len(a) - len(b)) > limit:
        return False
    previous = list(range(len(b) + 1))
    for i, ch_a in enumerate(a, 1):
        current = [i]
        for j, ch_b in enumerate(b, 1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (ch_a != ch_b),
                )
            )
        if min(current) > limit:
            return False
        previous = current
    return previous[-1] <= limit


def _narrow(
    candidates: list[dict],
    card: TTSCard,
    set_names: dict[str, str],
    pack_names: dict[str, str],
) -> list[dict]:
    """Apply every signal that can only narrow, never invent, a match."""
    context = fold_name(" ".join(card.path))

    # A card scanned with its own back is two-sided, so it is the front of a linked pair.
    # This is what separates the hero Hawkeye from the four allies and minions of that
    # name, and it settles most of the hero and alter-ego cards on its own.
    if card.unique_back:
        two_sided = [c for c in candidates if c.get("back_link")]
        if two_sided:
            candidates = two_sided

    # Orientation. marvelsdb does not record it, but a schemes-and-environments card is
    # printed sideways and a character card is not.
    oriented = [
        c for c in candidates if (c.get("type_code") in LANDSCAPE_TYPES) == card.sideways
    ]
    if oriented:
        candidates = oriented

    if len(candidates) == 1:
        return candidates

    # What the bag is for. A hero deck holds cards a player owns, an encounter or villain
    # deck holds cards the game plays against them, and no card is ever both. This is
    # what tells Captain Marvel's own Energy Absorption from the treachery of that name
    # printed later in a villain set.
    role = _bag_role(card.path)
    if role is not None:
        by_role = [c for c in candidates if _is_player_card(c) == role]
        if by_role:
            candidates = by_role

    if len(candidates) == 1:
        return candidates

    # Some bags name the card type outright -- "Basic Aspect Allies", "Kang Main Scheme"
    # -- which separates the ally Groot from the hero of the same name.
    wanted = _bag_type(card.path)
    if wanted:
        by_type = [c for c in candidates if c.get("type_code") in wanted]
        if by_type:
            candidates = by_type

    if len(candidates) == 1:
        return candidates

    # An aspect bag holds only that aspect's cards, which separates the several allies
    # named Spider-Man across the four aspects and Basic.
    aspect = _bag_aspect(card.path)
    if aspect:
        by_aspect = [c for c in candidates if c.get("faction_code") == aspect]
        if by_aspect:
            candidates = by_aspect

    if len(candidates) == 1:
        return candidates

    # A hero pack's own bag names the hero, and the sets inside it are that hero's. This
    # is what tells Spider-Man's nemesis Vulture from the Vulture printed in a later
    # villain set, given both are minions sitting in a bag called a nemesis set.
    owner = _bag_owner(card.path)
    if owner:
        owned = [
            c
            for c in candidates
            if c.get("set_code") and owner in fold_name(set_names.get(c["set_code"], "\0"))
        ]
        if len(owned) == 1:
            return owned
        if owned:
            candidates = owned

    # The bag is usually named after the set the cards were printed in, and failing that
    # after the pack. Both are checked longest-first so "Standard III" is not shadowed by
    # "Standard".
    for lookup, attr in ((set_names, "set_code"), (pack_names, "pack_code")):
        matched = [
            c
            for c in candidates
            if c.get(attr) and fold_name(lookup.get(c[attr], "\0")) in context
        ]
        if len(matched) == 1:
            return matched
        if matched:
            candidates = matched

    return candidates


# ---------------------------------------------------------------------------
# Fetching sheets
# ---------------------------------------------------------------------------


def sheet_path(url: str) -> Path:
    """Where a sheet is cached.

    Steam's URLs are content-addressed, so hashing the URL is as good as hashing the
    bytes: a sheet whose contents change arrives under a new URL and lands in a new
    file, and one that has not changed is already here.
    """
    return CACHE_DIR / f"{hashlib.sha1(url.encode()).hexdigest()}.bin"


def fetch_sheets(urls: list[str], *, dry_run: bool = False) -> tuple[int, int]:
    """Download whatever is not already cached. Returns (fetched, bytes)."""
    missing = [u for u in urls if not sheet_path(u).exists()]
    if not missing:
        return (0, 0)

    if dry_run:
        log(f"  would fetch {len(missing)} sheet(s)")
        return (len(missing), 0)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    total = 0
    for i, url in enumerate(missing, 1):
        size = _fetch_one(url)
        total += size
        log(f"  [{i}/{len(missing)}] {size / 1e6:6.1f} MB  {url[-24:]}")
    return (len(missing), total)


def _fetch_one(url: str) -> int:
    """Fetch one sheet to the cache, atomically.

    Serial by design. Steam drops most concurrent requests -- three of eight succeeded
    when measured -- while sequential ones never failed, so parallelism here buys
    retries rather than speed.
    """
    destination = sheet_path(url)
    temp = destination.with_suffix(".part")

    for attempt in range(1, FETCH_RETRIES + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            # The timeout is per socket read, not for the whole transfer, but the
            # largest sheets are 60 MB and have taken three minutes end to end. A
            # generous value costs nothing on the sheets that are quick.
            with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT) as response:
                if response.status != 200:
                    raise urllib.error.HTTPError(
                        url, response.status, "unexpected status", response.headers, None
                    )
                declared = response.headers.get("Content-Length")
                with temp.open("wb") as out:
                    shutil.copyfileobj(response, out, 1 << 20)

            size = temp.stat().st_size
            if size < 1024:
                raise OSError(f"suspiciously small response ({size} bytes)")

            # Steam closes a connection early often enough that a short read is a
            # routine event on a run this size. Left unchecked it writes a truncated
            # PNG that the cache then treats as good, and the failure surfaces hours
            # later in the cropping stage instead of here, where it can be retried.
            if declared is not None and size != int(declared):
                raise OSError(f"short read: got {size} of {declared} bytes")

            temp.replace(destination)
            return size

        except Exception as exc:  # noqa: BLE001 - retried, then reported
            temp.unlink(missing_ok=True)
            if attempt == FETCH_RETRIES:
                die(f"could not fetch {url}: {exc}")
            # Steam drops a connection mid-stream every few hundred sheets, which on a
            # multi-gigabyte first run is a certainty rather than a possibility. Backing
            # off further each time turns it into a pause instead of a failed build.
            log(f"      retry {attempt}/{FETCH_RETRIES - 1} after {exc}")
            time.sleep(FETCH_BACKOFF * attempt)

    return 0


# ---------------------------------------------------------------------------
# Cropping
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Crop:
    """One card image to cut out of one sheet."""

    url: str
    index: int
    width: int
    height: int
    filename: str
    rotate: bool = False


def plan_crops(
    tts_cards: list[TTSCard],
    codes: dict[str, str],
    grids: dict[str, tuple[int, int]],
    two_sided: set[str],
) -> tuple[list[Crop], dict[str, dict[str, str | bool]]]:
    """Decide which cell becomes which file.

    Returns the crops to make and, for each card code, the front and back filenames
    plus whether the card is printed sideways. A card appears in the save once per
    physical copy and often in several bags, so cells are deduplicated here; the same
    cell always holds the same card, which is checked rather than assumed.

    [two_sided] is every code marvelsdb gives a second side, and is what a back scan is
    checked against: a scan of a back belonging to a card upstream calls one-sided is
    one of the two halves disagreeing, and the build stops rather than guess which.
    """
    crops: dict[str, Crop] = {}
    images: dict[str, dict[str, str | bool]] = {}
    claimed: dict[tuple[str, int], str] = {}
    names: dict[str, dict[tuple[str, int], TTSCard]] = {}

    for card in tts_cards:
        code = codes.get(card.key)
        if code is None:
            continue

        owner = claimed.setdefault(card.face_cell, code)
        if owner != code:
            die(
                f"sheet cell {card.face_cell[1]} of {card.face_cell[0][-24:]} is claimed "
                f"by both {owner} and {code} (at {card.key})"
            )

        # A code reached from two different cells means two pictures are competing for
        # one filename, and the last write wins. The loser is not left blank -- it is
        # left showing the winner's art, which nothing downstream can detect. Copies of
        # one card share a cell and are fine; distinct cells are two cards.
        seen = names.setdefault(code, {})
        seen.setdefault(card.face_cell, card)

        sides = images.setdefault(code, {})
        sides["front_image"] = _add_crop(
            crops, card.face_cell, grids, f"{code}.webp", card.sideways
        )
        # marvelsdb does not record orientation and type_code does not imply it -- four
        # attachments and a handful of others are printed sideways, one side scheme is
        # not. The save's flag is the only source, so it is carried to the app, which
        # needs it to size a grid cell before the image has decoded.
        sides["landscape"] = card.sideways

        back = card.back_cell
        if back is not None and code not in BACK_SCAN_IS_NOT_A_CARD:
            sides["back_image"] = _add_crop(
                crops, back, grids, f"{code}b.webp", card.sideways
            )

    _check_backs_have_a_side(images, two_sided)
    _check_one_card_per_code(names)
    return (sorted(crops.values(), key=lambda c: c.filename), images)


# Scans whose back sheet is not a second face of the card. Both are single cards in the
# save carrying a back of their own, where marvelsdb gives them no second side at all --
# 03024 Avengers Tower, a support in the Tower Defense setup, and 42001c Archangel, the
# oversized alternate hero form. Cropping the back would write a file no record reads.
#
# The list is deliberately short and checked: `_check_backs_have_a_side` fails the build
# on any *other* code whose back is scanned but which upstream calls one-sided, because
# that is either a new case to look at or a scan matched to the wrong card.
BACK_SCAN_IS_NOT_A_CARD = {"03024", "42001c"}


def _check_backs_have_a_side(
    images: dict[str, dict[str, str | bool]], two_sided: set[str]
) -> None:
    """Fail when a back is cropped for a card marvelsdb says has only one side.

    The two halves of the pipeline disagreeing is the interesting case, not a nuisance:
    either the save has scanned a side upstream does not know about, or the scan has
    been matched to the wrong card and its back is about to be written under a code
    that will never read it. Both want eyes, and neither should ship quietly.
    """
    orphans = sorted(
        code
        for code, sides in images.items()
        if "back_image" in sides and code not in two_sided
    )
    if orphans:
        die(
            f"{len(orphans)} card(s) have a scanned back but no second side in "
            f"marvelsdb: {', '.join(orphans)}. Either the scan is matched to the wrong "
            "card, or the back is not a card face -- add it to BACK_SCAN_IS_NOT_A_CARD "
            "with the reason if you have looked at it and it is the latter."
        )


# Codes that genuinely have two scans, verified by looking at them. Kang's standard and
# Expert printings differ only in the hit points printed on them, and Seduced was
# printed in two sets; each pair is one card, so either cell is a correct answer.
#
# The rest are cards a deck holds two copies of, scanned twice because the save holds a
# cell per physical copy. Wakanda Forever! 01043d is quantity 2 and its two scans are
# numbered 6/15 and 7/15, both printed 43D; Echo's Photographic Reflexes 60040a-c are
# quantity 2 apiece. Either cell of such a pair is the same card.
TWO_SCANS_ARE_ONE_CARD = {
    "11001", "11006", "55015",
    "01043d", "60040a", "60040b", "60040c",
}


def _check_one_card_per_code(claims: dict[str, dict[tuple[str, int], TTSCard]]) -> None:
    """Fail when a hand-pinned scan lands on a code another scan already fills.

    819 codes are legitimately reached from several cells -- reprints, and cards printed
    in more than one artwork -- so competing cells alone say nothing. What is suspect is
    an *override* competing: a human pinned a scan to a code that a different cell also
    fills, which is how two cards end up sharing one filename. The last crop written
    wins and the loser is left wearing the winner's picture, which no later stage can
    see. Both Spider-Man hero bags and the Ant-Man and Wasp hero forms failed this way.
    """
    overrides = load_overrides()
    for code, by_cell in sorted(claims.items()):
        if len(by_cell) < 2 or code in TWO_SCANS_ARE_ONE_CARD:
            continue
        cards = [c for c in by_cell.values() if c.key in overrides]
        if not cards:
            continue
        die(
            f"code {code} is pinned to a scan by tools/card_overrides.json but is also "
            "filled from another sheet cell, so one card would overwrite the other's "
            "art: "
            + "; ".join(
                f"{c.nickname!r} at {' / '.join(c.path)}" for c in by_cell.values()
            )
            + f". Give each its own code, or add {code} to TWO_SCANS_ARE_ONE_CARD if "
            "they really are one card."
        )


def _add_crop(
    crops: dict[str, Crop],
    cell: tuple[str, int],
    grids: dict[str, tuple[int, int]],
    filename: str,
    rotate: bool = False,
) -> str:
    url, index = cell
    width, height = grids[url]
    crops[filename] = Crop(url, index, width, height, filename, rotate)
    return filename


def read_previous_crops() -> dict[str, tuple[str, str]]:
    """What the last run cut each file from, as filename -> (sheet url, cell index)."""
    path = BUILD / "crops.csv"
    if not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as handle:
        return {
            row["filename"]: (row["sheet"], row["index"])
            for row in csv.DictReader(handle)
        }


def crop_images(crops: list[Crop], *, force: bool) -> tuple[int, int]:
    """Cut every planned crop that is not already on disk. Returns (written, skipped)."""
    IMAGES.mkdir(parents=True, exist_ok=True)

    previous = read_previous_crops()

    pending = []
    skipped = 0
    for crop in crops:
        target = IMAGES / crop.filename
        source = sheet_path(crop.url)
        # Mtime alone is not enough. A card whose match changes keeps its filename and
        # gains a new source cell, and the file already on disk is newer than the sheet
        # it now comes from -- so a timestamp test calls the stale art fresh and the
        # card silently keeps a picture of a different card. Provenance settles it.
        same_source = previous.get(crop.filename) == (crop.url, str(crop.index))
        fresh = (
            target.exists()
            and source.exists()
            and same_source
            and target.stat().st_mtime >= source.stat().st_mtime
        )
        if fresh and not force:
            skipped += 1
        else:
            pending.append(crop)

    if not pending:
        return (0, skipped)

    # Grouped by sheet so each one is opened and decoded once rather than per cell.
    by_sheet: dict[str, list[Crop]] = defaultdict(list)
    for crop in pending:
        by_sheet[crop.url].append(crop)

    written = 0
    with ProcessPoolExecutor() as pool:
        batches = list(by_sheet.items())
        for i, count in enumerate(pool.map(_crop_sheet, batches), 1):
            written += count
            if i % 25 == 0 or i == len(batches):
                log(f"  cropped {i}/{len(batches)} sheets, {written} images")

    return (written, skipped)


def _crop_sheet(batch: tuple[str, list[Crop]]) -> int:
    url, crops = batch
    path = sheet_path(url)

    with Image.open(path) as sheet:
        sheet.load()
        full_width, full_height = sheet.size
        grid_w, grid_h = crops[0].width, crops[0].height
        cell_w = full_width / grid_w
        cell_h = full_height / grid_h

        for crop in crops:
            col = crop.index % grid_w
            row = crop.index // grid_w
            box = (
                round(col * cell_w),
                round(row * cell_h),
                round((col + 1) * cell_w),
                round((row + 1) * cell_h),
            )
            cell = sheet.crop(box)
            # A sideways card is stored upright in the sheet, so that every cell in a
            # grid is the same shape, and TTS turns it when it is dealt. The app has no
            # equivalent, and a scheme should not arrive on its side.
            if crop.rotate:
                cell = cell.transpose(Image.Transpose.ROTATE_90)
            target = IMAGES / crop.filename
            temp = target.with_suffix(".part")
            cell.save(temp, "WEBP", quality=QUALITY, method=METHOD)
            temp.replace(target)

    return len(crops)


# ---------------------------------------------------------------------------
# Building the card records
# ---------------------------------------------------------------------------

# Fields carried through from marvelsdb untouched. Everything the app shows comes from
# here; anything not listed is either pipeline-internal or unused by the app.
CARRIED = (
    "code", "name", "subname", "text", "flavor", "traits", "type_code", "faction_code",
    "pack_code", "set_code", "card_set_code", "position", "set_position", "quantity",
    "cost", "cost_star", "cost_per_hero", "attack", "attack_star", "attack_cost",
    "thwart", "thwart_star", "thwart_cost", "defense", "defense_star", "recover",
    "recover_star", "scheme", "scheme_star", "scheme_acceleration", "scheme_crisis",
    "scheme_hazard", "scheme_amplify", "boost", "boost_star", "health", "health_star",
    "health_per_hero", "health_per_group", "base_threat", "base_threat_fixed",
    "base_threat_per_group", "threat", "threat_fixed", "threat_star", "threat_per_group",
    "escalation_threat", "escalation_threat_fixed", "escalation_threat_star",
    "hand_size", "stage", "deck_limit", "is_unique", "permanent", "hidden",
    "double_sided", "back_link", "back_name", "back_text", "back_flavor",
    "resource_physical", "resource_mental", "resource_energy", "resource_wild",
    "illustrator", "errata", "restrictions", "deck_options", "deck_requirements",
)


def build_records(
    mdb_cards: list[dict], ref: dict, images: dict[str, dict[str, str | bool]]
) -> list[dict]:
    """Turn marvelsdb records into what the app reads.

    Adds five fields the app needs and upstream does not carry: the two image
    filenames, whether the card is printed sideways, a sort key giving release order,
    and resolved pack and set names so no screen has to hold a lookup table.
    """
    packs = {p["code"]: p for p in ref["packs"]}
    set_names = {s["code"]: s["name"] for s in ref["sets"]}

    # The other side of a card, whichever way its back_link runs. A two-sided card is two
    # records and one scan, so the half that was not scanned takes its picture from the
    # other half's back image -- and which half that is does not follow from the link's
    # direction. back_link points front to back, and the save usually scanned the front,
    # so a back looks forwards along it; but Green Goblin 02001-02003 were scanned from
    # the Norman Osborn side, which is the *target* of the link, so those three look
    # backwards along it. Reading one direction only leaves the other three artless.
    other_side: dict[str, str] = {}
    for card in mdb_cards:
        if link := card.get("back_link"):
            other_side[card["code"]] = link
            other_side[link] = card["code"]

    records = []
    for card in mdb_cards:
        # The nameless records are reprint pointers -- a code, a pack, a position and a
        # duplicate_of -- not cards. The card they point at is already in the list.
        if not card.get("name"):
            continue

        record = {k: card[k] for k in CARRIED if k in card}

        pack = packs.get(card.get("pack_code"), {})
        record["pack_name"] = pack.get("name")
        if card.get("set_code"):
            record["set_name"] = set_names.get(card["set_code"])

        # Release order: which pack, then where in it. Pack position rather than date,
        # because several packs share a release date.
        record["sort_key"] = [pack.get("position", 0), card.get("position", 0)]

        record.update(images.get(card["code"], {}))

        # A two-sided card is two records upstream, and one scan here: the object that
        # carries its own back holds both faces. So the half that was not scanned takes
        # its picture from the other half's back image, rather than having none. This is
        # what gives every alter-ego its portrait, the hero having been scanned with it.
        if "front_image" not in record:
            scanned = other_side.get(card["code"])
            if back := images.get(scanned, {}).get("back_image"):
                record["front_image"] = back
                # Both faces of one physical card share its orientation.
                record["landscape"] = images[scanned]["landscape"]

        # The 58 cards with no scan have no orientation to read, so type stands in.
        # It is a good rule and not a perfect one -- a handful of scanned attachments and
        # allies are printed sideways against type -- but for a card with no picture,
        # orientation only decides the shape of a placeholder.
        if "landscape" not in record:
            record["landscape"] = card.get("type_code") in LANDSCAPE_TYPES

        records.append(record)

    records.sort(key=lambda r: (r["sort_key"], r["code"]))
    link_printings(records)
    return records


# Fields that may differ between two printings of one card. Everything else printed on
# the card has to match, or they are not the same card.
#
# `quantity` is how many copies a pack holds, not an identity -- Goblin Glider is 1 in
# Mutagen Formula and 2 in Goblin Gimmicks. `errata` is recorded against whichever
# printing the ruling named, so I've Been Waiting For This! carries it on 07041 alone.
# `illustrator` and `flavor` differ because differing art is the whole point.
#
# What is deliberately *not* here: `deck_limit`, which is the only thing separating
# Vibranium 01044 (3) from Shuri's 51006 (2), and `stage`, without which Master Mold I,
# II and III collapse into one card.
PRINTING_IGNORED = frozenset({
    "code", "pack_code", "pack_name", "position", "set_position", "set_code",
    "set_name", "front_image", "back_image", "back_link", "sort_key",
    "illustrator", "flavor", "card_set_code", "quantity", "errata",
})


def link_printings(records: list[dict]) -> int:
    """Point every reprint of a card at the first printing of it, via `variant_of`.

    Upstream has a `duplicate_of` field, but it is only ever on the nameless pointer
    records `build_records` drops, and it never covers this case: a card reprinted into
    a second encounter set gets a wholly new code and no pointer at all. Hydra Mercenary
    is three codes across Rhino, Black Widow Nemesis and Winter Soldier Nemesis, and
    nothing in the data joins them.

    So the join is by what is printed on the card: two cards are one card when every
    printed field agrees. See PRINTING_IGNORED for the handful that may differ.

    Nothing about *where* the cards sit enters into it. An earlier version also required
    the printings to be in different encounter sets, which sounds right -- a reprint
    goes into a new set -- and is not, because a card can be printed several times into
    one set. Civil War prints Superhero Registration Act at 63, 96, 121 and 122; the
    Enchantress set holds five Hypnotic Gaze at 7 to 11, whose five scans are
    byte-identical. Requiring different sets admitted the first of those, because a
    fifth printing happens to sit in Synthezoid Smackdown, and refused the second. The
    same card, treated two ways, on an accident of set naming.

    Near-misses this correctly refuses, none of which needed that clause: Kang (Iron
    Lad) 11003 and its Expert printing 11036 share a name and text but not health;
    Vibranium 01044 has a deck limit of 3 where Shuri's 51006 has 2; Master Mold I, II
    and III differ by stage; and the Wakanda Forever! run 01043a-d differ by resource
    pip, which is four cards a deck draws between rather than one card printed four
    times.

    Returns the number of groups found.
    """
    # A back side is not browsed in its own right, and follows whichever front claims
    # it. Grouping backs as well would pair them by their own text and produce a second,
    # redundant set of links the app would have to ignore.
    backs = {r["back_link"] for r in records if r.get("back_link")}

    groups: dict[str, list[dict]] = {}
    for record in records:
        if record["code"] in backs:
            continue
        key = json.dumps(
            {k: v for k, v in sorted(record.items()) if k not in PRINTING_IGNORED},
            sort_keys=True,
            ensure_ascii=False,
        )
        groups.setdefault(key, []).append(record)

    found = 0
    for group in groups.values():
        if len(group) < 2:
            continue

        # A picker row is the card's name over its set and printed number, so two
        # printings agreeing on both would be two rows nothing tells apart. The pack is
        # deliberately not in this key even though it is in the record: it is not on the
        # row, so it cannot separate one. Nothing in the data collides; this says so if
        # that changes.
        stamps = {(r.get("set_name") or r["pack_name"], r["position"]) for r in group}
        if len(stamps) != len(group):
            die(f"printings of {group[0]['name']!r} share a set and printed number, so "
                f"the picker would show identical rows: {[r['code'] for r in group]}")

        # The app draws one art box for the whole group and only swaps the picture in
        # it, so a group that disagreed about its shape or about having a second side
        # would need a box that changed size under the finger that tapped it. Nothing in
        # the data does today; this is here so that a future data drop says so loudly
        # rather than producing a picker that jumps.
        if len({r["landscape"] for r in group}) > 1:
            die(f"printings of {group[0]['name']!r} disagree on orientation: "
                f"{[r['code'] for r in group]}")
        if len({bool(r.get("back_link") or r.get("double_sided")) for r in group}) > 1:
            die(f"printings of {group[0]['name']!r} disagree on two-sidedness: "
                f"{[r['code'] for r in group]}")

        # Release order, so the original comes first and later sets follow it.
        group.sort(key=lambda r: (r["sort_key"], r["code"]))
        for reprint in group[1:]:
            reprint["variant_of"] = group[0]["code"]
        found += 1

    return found


def build_decks(
    tts_cards: list[TTSCard], codes: dict[str, str], records: list[dict]
) -> list[dict]:
    """The pre-built deck that ships in each hero pack.

    The save has already done the grouping: a hero pack bag holds a hero deck and a
    nemesis set, each a deck object with one entry per physical copy.

    Four things about the save make a naive reading wrong, and each is settled here
    rather than in the app -- see the notes on the fixes below.
    """
    by_code = {r["code"]: r for r in records}
    # back_link points forward, front to back. A deck listing a back side is listing a
    # card that is not browsed in its own right, so it is folded onto its front.
    fronts = {r["back_link"]: r["code"] for r in records if r.get("back_link")}

    decks: dict[tuple[str, ...], Counter] = defaultdict(Counter)
    for card in tts_cards:
        if len(card.path) < 2:
            continue
        bag = card.path[-1].lower()
        if "hero deck" not in bag and "hero set" not in bag:
            continue
        code = codes.get(card.key)
        if code:
            # 01040b T'Challa is the back of 01040a Black Panther, and the only such
            # slot; without this the deck screen would hold a card the browse list
            # deliberately does not show.
            decks[card.path][fronts.get(code, code)] += 1

    heroes = _deck_heroes(tts_cards, codes, by_code, fronts)

    # The same pack can appear at two paths. Daredevil and Echo sit both loose and
    # inside a "Daredevil and Echo Patch Bag", which counted every copy twice and made
    # both decks read as 30 cards. Identical listings collapse; listings that actually
    # differ are two different decks and are kept apart below.
    by_pack: dict[str, list[tuple[tuple[str, ...], Counter]]] = defaultdict(list)
    for path, slots in sorted(decks.items()):
        by_pack[path[-2]].append((path, slots))

    built = []
    for pack, listings in sorted(by_pack.items()):
        distinct: list[tuple[tuple[str, ...], Counter]] = []
        for path, slots in listings:
            if not any(slots == seen for _, seen in distinct):
                distinct.append((path, slots))

        for path, slots in distinct:
            candidates = list(
                dict.fromkeys(heroes.get(path[:-1], []) + heroes.get(path, []))
            )
            if not candidates:
                die(
                    f"the deck at {' / '.join(path)} has no hero or alter-ego card in "
                    "its pack bag; build_decks cannot say whose deck it is"
                )
            hero = _choose_hero(candidates, slots, by_code)

            # Two decks can share a pack name: the Core Set's Black Panther deck and
            # Shuri's rebuild are both "Black Panther Hero Pack". A set is named for
            # the identity it was printed for -- "Black Panther" and "Black Panther
            # (Shuri)" -- so it separates them where the pack name does not.
            name = by_code[hero].get("set_name") or pack
            deck_id = f"pack:{fold_name(name)}"

            built.append(
                {
                    "id": deck_id,
                    "name": name,
                    "hero": hero,
                    "slots": dict(sorted(slots.items())),
                }
            )

    ids = Counter(deck["id"] for deck in built)
    if duplicates := [i for i, n in ids.items() if n > 1]:
        die(f"two decks share an id, which the app uses as a key: {duplicates}")
    return sorted(built, key=lambda d: by_code[d["hero"]]["sort_key"])


def _deck_heroes(
    tts_cards: list[TTSCard],
    codes: dict[str, str],
    by_code: dict[str, dict],
    fronts: dict[str, str],
) -> dict[tuple[str, ...], list[str]]:
    """The hero or alter-ego card sitting beside each hero deck, by pack bag path.

    No deck contains its own identity: the save keeps it loose in the pack bag next to
    the deck, so a deck read on its own has nothing to show for itself.

    Two things stop this being "the loose card in the bag". Ten packs hold a second
    loose card beside the identity -- Vision's Intangible, Rogue's Touched, Wolverine's
    Claws -- so the type has to be checked rather than the count. And SP//dr's identity
    is one level down, in an "SP//dr's Identity Cards" deck, so a bag with nothing
    loose is searched one level deeper.
    """
    found: dict[tuple[str, ...], list[str]] = defaultdict(list)

    for card in tts_cards:
        code = codes.get(card.key)
        if not code or by_code.get(code, {}).get("type_code") not in (
            "hero",
            "alter_ego",
        ):
            continue
        # A hero and their alter-ego are two sides of one card, so both scans name the
        # same identity. Folded onto the front, they stop looking like two candidates
        # tied with each other.
        code = fronts.get(code, code)
        # Loose in the bag, or one level inside it -- which is where SP//dr's identity
        # lives. Deeper than that is a nemesis or aspect bag, whose heroes are somebody
        # else's. The candidates are narrowed per deck by _choose_hero.
        for bag in (card.path, card.path[:-1] if len(card.path) > 1 else None):
            if bag is not None and code not in found[bag]:
                found[bag].append(code)
    return found


def _choose_hero(candidates: list[str], slots: Counter, by_code: dict[str, dict]) -> str:
    """Which of a bag's identity cards belongs to this deck.

    A bag can offer several. Both Black Panther hero packs are called "Black Panther
    Hero Pack" -- one Core Set, one Shuri's rebuild -- so the save gives no path that
    tells them apart and their contents pool under one key. Looking one level into a
    bag adds more: a hero deck legitimately holds *other* heroes as allies, so Echo's
    bag offers Daredevil.

    The deck's own cards settle it. A pre-built deck is mostly the set it was printed
    in, so the identity whose set the deck draws most from is the identity whose deck
    it is. Ties and misses fail the build rather than guessing.
    """
    sets = Counter(by_code[code].get("set_name") for code in slots if code in by_code)

    # Most sets number their identity first, so where two identities come from one set
    # -- SP//dr's suit and Peni Parker are two cards, not two sides of one -- the lower
    # position is the one the set is named for.
    ranked = sorted(
        (
            (
                -sets.get(by_code[code].get("set_name"), 0),
                by_code[code].get("position", 0),
                code,
            )
            for code in candidates
        )
    )
    matched, _, code = ranked[0]
    if matched == 0:
        die(
            f"none of the identity cards {candidates} shares a set with the deck's own "
            f"cards ({dict(sets)}); cannot say whose deck this is"
        )
    if len(ranked) > 1 and ranked[1][:2] == ranked[0][:2]:
        die(
            f"identity cards {candidates} are equally plausible for a deck of "
            f"{dict(sets)}; cannot say whose deck this is"
        )
    return code


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


REVIEW = BUILD / "review"


def crop_for_review(
    result: MatchResult, tts_cards: list[TTSCard], grids: dict[str, tuple[int, int]]
) -> None:
    """Cut out the unmatched scans so they can be looked at.

    An unmatched scan is a picture of a card, and the fastest way to say which card it
    is, is to see it. These land in .cache/review/ rather than assets/, because they are
    not part of the app and may well turn out not to be cards at all.
    """
    wanted = {entry["key"] for entry in result.unmatched}
    by_key = {c.key: c for c in tts_cards if c.key in wanted}

    REVIEW.mkdir(parents=True, exist_ok=True)
    global IMAGES  # noqa: PLW0603 - _crop_sheet writes relative to this
    original, IMAGES = IMAGES, REVIEW
    try:
        crops: dict[str, Crop] = {}
        for entry in result.unmatched:
            card = by_key.get(entry["key"])
            if card is None:
                continue
            name = f"{_safe(entry['key'])}.webp"
            _add_crop(crops, card.face_cell, grids, name)
            entry["image"] = f".cache/review/{name}"
        crop_images(sorted(crops.values(), key=lambda c: c.filename), force=False)
    finally:
        IMAGES = original

    write_unmatched(result)
    log(f"  wrote {len(crops)} image(s) to .cache/review/ for review")


def _safe(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", text)[:120]


def write_unmatched(result: MatchResult) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    path = BUILD / "unmatched.json"
    path.write_text(
        json.dumps(
            {
                "help": (
                    "Add each key to the 'overrides' object in tools/card_overrides.json, "
                    "mapping it to the right card code, or to null if it is not a "
                    "marvelsdb card. Re-run the script; sheets and crops are cached."
                ),
                "count": len(result.unmatched),
                "unmatched": result.unmatched,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    log(f"  wrote {path.relative_to(ROOT)}")


def write_crop_report(crops: list[Crop]) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    with (BUILD / "crops.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["filename", "sheet", "index", "grid"])
        for crop in crops:
            writer.writerow(
                [crop.filename, crop.url, crop.index, f"{crop.width}x{crop.height}"]
            )


def read_manifest() -> dict:
    path = BUILD / "manifest.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def write_manifest(manifest: dict) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
    )


def report_diff(previous: dict, current: dict) -> None:
    """Print what this run changed, against the last one."""

    def line(label: str, key: str) -> None:
        before, after = previous.get(key), current.get(key)
        if before is None or before == after:
            log(f"  {label:<11} {after}")
        else:
            log(f"  {label:<11} {before} -> {after}")

    log("")
    log("summary")
    line("marvelsdb", "marvelsdb_commit")
    line("TTS save", "tts_date")
    line("sheets", "sheets")
    line("crops", "images")
    line("cards", "cards")
    line("printings", "printings")
    line("decks", "decks")
    line("unmatched", "unmatched")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--force", action="store_true", help="re-crop every image, ignoring the cache"
    )
    parser.add_argument(
        "--skip-images",
        action="store_true",
        help="rebuild the JSON only, touching neither the network nor the crops",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would change and exit without fetching or writing",
    )
    return parser.parse_args()


def load_overrides() -> dict[str, str | None]:
    path = Path(__file__).with_name("card_overrides.json")
    if not path.exists():
        return {}
    entries = json.loads(path.read_text(encoding="utf-8")).get("overrides", {})
    # Keys starting with an underscore are notes explaining the entries around them.
    # JSON has no comments and these decisions need the room.
    return {k: v for k, v in entries.items() if not k.startswith("_")}


def main() -> int:
    args = parse_args()

    log("reading inputs")
    state = git_state(JSON_DATA)
    if state.get("behind"):
        log(
            f"  warning: marvelsdb-json-data is {state['behind']} commit(s) behind "
            "origin/master; pull it if you want the newest cards"
        )
    log(f"  marvelsdb-json-data  {state.get('commit')} ({state.get('date')})")

    save = load_save()
    log(f"  {TTS_SAVE.name}  {save.get('SaveName')!r} ({save.get('Date')})")

    mdb_cards = load_pack_cards()
    ref = load_reference()
    tts_cards = walk_save(save)
    grids = sheet_grids(tts_cards)
    log(f"  {len(mdb_cards)} card records, {len(tts_cards)} scans, {len(grids)} sheets")

    log("")
    log("matching scans to cards")
    overrides = load_overrides()
    result = match_cards(tts_cards, mdb_cards, ref, overrides)
    for label, count in sorted(result.stats.items(), key=lambda kv: -kv[1]):
        log(f"  {label:<14} {count}")

    if result.stale_overrides:
        log(
            f"  warning: {len(result.stale_overrides)} override(s) match nothing in the "
            "save; the card was probably renamed or removed"
        )
        for key in result.stale_overrides[:10]:
            log(f"      {key}")

    if result.unmatched:
        write_unmatched(result)

    # Both directions, and the one card that carries both faces on a single record.
    two_sided = {c["code"] for c in mdb_cards if c.get("double_sided")}
    two_sided |= {c["back_link"] for c in mdb_cards if c.get("back_link")}
    two_sided |= {c["code"] for c in mdb_cards if c.get("back_link")}

    crops, images = plan_crops(tts_cards, result.resolved, grids, two_sided)

    if args.dry_run:
        needed = [u for u in {c.url for c in crops} if not sheet_path(u).exists()]
        log("")
        log("dry run")
        log(f"  {len(crops)} crops planned, {len(needed)} sheet(s) to fetch")
        if result.unmatched:
            log(f"  {len(result.unmatched)} unmatched; see .cache/unmatched.json")
        return 0

    if not args.skip_images:
        log("")
        log("fetching sheets")
        # Every art sheet, not only the ones a matched card needs. An unmatched scan
        # cannot be judged without looking at it, and resolving one later should not
        # send us back to the network.
        fetched, size = fetch_sheets(sorted(grids))
        log(f"  {fetched} fetched, {size / 1e6:.0f} MB")

        log("")
        log("cropping")
        written, skipped = crop_images(crops, force=args.force)
        log(f"  {written} written, {skipped} already current")
        write_crop_report(crops)

        if result.unmatched:
            crop_for_review(result, tts_cards, grids)

    if result.unmatched:
        die(
            f"{len(result.unmatched)} scan(s) could not be matched to a card. "
            "See .cache/unmatched.json, then add entries to tools/card_overrides.json."
        )

    log("")
    log("writing assets")
    ASSETS.mkdir(parents=True, exist_ok=True)

    records = build_records(mdb_cards, ref, images)
    (ASSETS / "cards.json").write_text(
        json.dumps(records, separators=(",", ":"), ensure_ascii=False), encoding="utf-8"
    )

    decks = build_decks(tts_cards, result.resolved, records)
    (ASSETS / "decks.json").write_text(
        json.dumps(decks, indent=1, sort_keys=True, ensure_ascii=False), encoding="utf-8"
    )

    if not args.skip_images:
        missing = [
            name
            for record in records
            for key in ("front_image", "back_image")
            if (name := record.get(key)) and not (IMAGES / name).exists()
        ]
        if missing:
            die(f"{len(missing)} referenced image(s) are not on disk, e.g. {missing[:3]}")

        planned = {crop.filename for crop in crops}
        for stray in IMAGES.glob("*.webp"):
            if stray.name not in planned:
                stray.unlink()

    with_art = sum(1 for r in records if r.get("front_image"))
    printings = {r["variant_of"] for r in records if r.get("variant_of")}
    log(f"  cards.json  {len(records)} cards, {with_art} with art")
    log(f"  decks.json  {len(decks)} decks")

    current = {
        "marvelsdb_commit": state.get("commit"),
        "tts_date": save.get("Date"),
        "sheets": len(grids),
        "images": len(crops),
        "cards": len(records),
        "printings": len(printings),
        "decks": len(decks),
        "unmatched": len(result.unmatched),
    }
    report_diff(read_manifest(), current)
    write_manifest(current)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
