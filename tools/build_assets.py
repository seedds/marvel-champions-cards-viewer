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
#
# Shuri's Vibranium 51006 and Miles' Web-Shooter 27039 are the same, and both were
# reached by an override rather than by name -- their names belong to a Core Set card
# first, so the cascade sent them to 01044 and 01008. The crops confirm the pairs:
# Vibranium 7/15 and 8/15, both (c)2025 and numbered 6, where Core's 01044 is (c)2019
# and numbered 44; Web-Shooter 14/15 and 15/15, both numbered 39.
TWO_SCANS_ARE_ONE_CARD = {
    "11001", "11006", "55015",
    "01043d", "60040a", "60040b", "60040c",
    "51006", "27039",
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
    link_editions(records)
    return records


# The resource pips a card is printed with, in the order the picker names them. Four
# runs of cards are separated by nothing else printed on them -- Wakanda Forever!,
# Jubilee's Firecracker and Flash of Light, Echo's Photographic Reflexes -- so a caption
# without these has rows a person cannot tell apart.
RESOURCE_FIELDS = (
    ("resource_physical", "physical"),
    ("resource_mental", "mental"),
    ("resource_energy", "energy"),
    ("resource_wild", "wild"),
)


def _edition_caption(record: dict) -> tuple:
    """What the picker prints under an edition's name, as a tuple, for uniqueness.

    Set (or pack, when a card is in none) and printed number separate almost every
    edition of a card. Stage separates a villain's three, and the resource pips separate
    a run like Wakanda Forever! whose members share even their printed number.
    """
    return (
        record.get("set_name") or record["pack_name"],
        record["position"],
        record.get("stage"),
        tuple(name for field, name in RESOURCE_FIELDS if record.get(field)),
    )


def link_editions(records: list[dict]) -> int:
    """Group the cards that share a name and a type, via `edition_of`.

    A name is not unique in this game and never was: an ally, a minion and a hero can
    all be called Hawkeye. What the app wants is the other way round -- a person looking
    at one Wakanda Forever! wants the other four in front of them, because choosing
    between them is the whole question a card with five printings poses.

    So the join is by **name and type**. Type is in the key because the alternative,
    name alone, puts Spider-Man's hero card in a list with seven allies and a minion,
    and Black Widow's hero card with three villains. Those share a name and are not
    editions of each other in any sense a player would recognise. Name and type gives
    206 groups over 529 cards; name alone gives 339 over 909, and 17 of those groups
    mix portrait with landscape, which the one art box cannot draw.

    What this deliberately no longer does is ask whether the printed fields agree. That
    rule -- two records are one card when every printed field matches -- is why the five
    Wakanda Forever! records were five groups of one: 01043a-d differ by resource pip
    and deck limit, and Shuri's 51005 rewords a reminder sentence. It also split Kang
    (Iron Lad) from its Expert printing on health, and both Vibraniums on deck limit.
    Every one of those is a card a person holding the other would want to see.

    Returns the number of groups found.
    """
    # A back side is not browsed in its own right, and follows whichever front claims
    # it. Grouping backs as well would pair them by their own name and produce a second,
    # redundant set of links the app would have to ignore.
    backs = {r["back_link"] for r in records if r.get("back_link")}

    groups: dict[tuple[str, str], list[dict]] = {}
    for record in records:
        if record["code"] in backs:
            continue
        groups.setdefault((record["name"], record["type_code"]), []).append(record)

    found = 0
    for group in groups.values():
        if len(group) < 2:
            continue

        # The app draws one art box for the whole group and only swaps the picture in
        # it, so a group that disagreed about its shape would need a box that changed
        # size under the finger that tapped it. Nothing in the data does today; this is
        # here so that a future data drop says so loudly rather than producing a picker
        # that jumps.
        #
        # Two-sidedness is deliberately *not* checked with it. Seven groups genuinely
        # mix it -- Ant-Man's 12001a has a back where his giant form 12001c has none,
        # and Apocalypse, Green Goblin, Collector, Wasp, Mister Sinister and The Shadow
        # King are the same -- so the flip button belongs to the chosen edition rather
        # than to the group, which is what the detail screen does with it.
        if len({r["landscape"] for r in group}) > 1:
            die(f"editions of {group[0]['name']!r} disagree on orientation: "
                f"{[r['code'] for r in group]}")

        # Release order, so the original comes first and later sets follow it.
        group.sort(key=lambda r: (r["sort_key"], r["code"]))

        # A picker row is the card's name over this caption, so two editions agreeing on
        # all of it would be two rows nothing tells apart. Four groups do: Android
        # Efficiency's three differ only by a pip inside their boost text, Ant-Man and
        # Wasp by the attack of their giant form, and two Apocalypse stages by scheme.
        # Those fall back to the code, which is at least printed on the card and is
        # unique by construction. The die() below is for a data drop that manages to
        # collide even that.
        captions = {_edition_caption(r) for r in group}
        if len(captions) != len(group):
            for record in group:
                record["edition_caption_code"] = True
            if len({r["code"] for r in group}) != len(group):
                die(f"editions of {group[0]['name']!r} share a code: "
                    f"{[r['code'] for r in group]}")

        for edition in group[1:]:
            edition["edition_of"] = group[0]["code"]
        found += 1

    return found


DECK_SIZE = 40

# The aspects a deck can be built from. Seven precons are legitimately multi-aspect --
# Adam Warlock draws on all four -- so a deck records the aspects it holds, not one.
ASPECT_CODES = ("aggression", "justice", "leadership", "protection", "pool")


def build_decks(records: list[dict], overrides: dict) -> list[dict]:
    """Each hero pack's pre-built deck: the 40 cards it plays, and what sits beside it.

    Read from marvelsdb, and not from the Tabletop Simulator save. **The save has no
    deck lists.** Its `X's Hero Deck` bag holds 15 objects for 65 of the 66 packs -- the
    hero's signature cards alone -- while the aspect and basic cards that complete a
    precon sit in shared `Justice Aspect Cards` and `Basic Aspect Cards` bags with
    nothing tying them to a hero. Reading that bag gave every deck 15 of its 40 cards.

    marvelsdb carries the deck implicitly, as printed order: a hero pack file lists the
    identity, then its signature cards, then the aspect and basic ones, and the
    encounter set is lifted out into a separate `*_encounter.json`. So the run of
    consecutive collector numbers from one identity to the next is that identity's
    precon, and the gap where the encounter set was ends the last run.

    Checked two ways. 51 of the 67 runs come to exactly 40 cards, which is the legal
    deck size and not a number a wrong rule hits 51 times; and Cable's run matches
    marvelcdb's published precon code for code and quantity for quantity. The other 16
    are in `tools/precon_overrides.json` -- a run that is neither 40 cards nor
    overridden fails the build.
    """
    by_code = {r["code"]: r for r in records}
    built = []

    for _pack_code, pack in sorted(_pack_files().items()):
        for identity, run in _identity_runs(pack, by_code):
            deck = _read_run(
                identity, run, records, by_code, overrides.get(identity["code"])
            )
            if deck is not None:
                built.append(deck)

    ids = Counter(deck["id"] for deck in built)
    if duplicates := [i for i, n in ids.items() if n > 1]:
        die(f"two decks share an id, which the app uses as a key: {duplicates}")

    if stale := sorted(set(overrides) - {d["hero"] for d in built}):
        die(
            f"tools/precon_overrides.json has {len(stale)} entr(y/ies) for identity "
            f"code(s) no deck was built for: {stale}. A code that moved upstream orphans "
            "its entry; fix or drop it rather than leaving it to do nothing."
        )
    return sorted(built, key=lambda d: by_code[d["hero"]]["sort_key"])


def _pack_files() -> dict[str, list[dict]]:
    """The player-card pack files, by pack code, each sorted into printed order.

    `*_encounter.json` is deliberately not read: the encounter set is what the gap in a
    pack's collector numbers is, and that gap is what ends a hero's run.
    """
    packs = {}
    for path in sorted((JSON_DATA / "pack").glob("*.json")):
        if path.stem.endswith("_encounter"):
            continue
        cards = json.loads(path.read_text(encoding="utf-8"))
        packs[path.stem] = sorted(cards, key=lambda c: (c["position"], c["code"]))
    return packs


def _identity_runs(
    pack: list[dict], by_code: dict[str, dict]
) -> list[tuple[dict, list[dict]]]:
    """Split a pack file into one run of consecutive positions per identity.

    A run starts at an identity and ends at the next identity or at the first gap in the
    collector numbers, whichever comes first. Two things make this less obvious than it
    sounds. An identity occupies one position with several codes -- a hero, its
    alter-ego, and sometimes a second hero form like Archangel -- so the *set* is what
    says whether a position is a new identity or another face of the current one. And
    Ironheart prints three identities at three consecutive positions in one set, which
    is why a run is keyed on the set rather than started at every hero card.
    """
    owners: dict[int, str | None] = {}
    for card in pack:
        record = by_code.get(card["code"])
        if record and record.get("type_code") in ("hero", "alter_ego"):
            owners.setdefault(card["position"], record.get("set_code"))

    starts: list[tuple[int, str | None]] = []
    for position in sorted(owners):
        if not starts or owners[position] != starts[-1][1]:
            starts.append((position, owners[position]))

    runs = []
    for index, (start, set_code) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else None
        run, previous = [], None
        for card in pack:
            if card["position"] < start or (end is not None and card["position"] >= end):
                continue
            # The gap where the encounter set was lifted out ends the run.
            if previous is not None and card["position"] - previous > 1:
                break
            previous = card["position"]
            run.append(card)

        identity = next(
            (
                by_code[c["code"]]
                for c in run
                if by_code.get(c["code"], {}).get("type_code") == "hero"
            ),
            None,
        )
        if identity is not None and set_code is not None:
            runs.append((identity, run))
    return runs


def _in_core_pool(record: dict) -> bool:
    """Whether a card is in the Core Set's shared aspect-and-basic pool at 50-93."""
    return record.get("pack_code") == "core" and 50 <= record.get("position", 0) <= 93


def _core_pool(aspect: str, records: list[dict]) -> dict[str, int]:
    """The 25 aspect and basic cards a Core Set precon adds to its 15 signature ones.

    Core is the one pack whose run cannot give a deck. It prints a *single* aspect pool
    for all five of its heroes -- 01050-01082 by aspect, then eleven basic cards -- so a
    hero's run stops at its signature cards and nothing in the data says which of the
    pool it takes, or how many.

    The box's own rule fills it: one copy of each unique card in the aspect, two of each
    non-unique, and one of each basic. That is 14 + 11, which takes all five decks to
    exactly 40, and it reproduces marvelcdb's published Spider-Man, She-Hulk and Black
    Panther precons card for card. The quantity is *not* the printed one -- Core holds
    three For Justice! and the precon plays two -- which is why this is a rule of its
    own rather than a run.
    """
    if aspect not in ASPECT_CODES:
        die(f"{aspect!r} is not an aspect; tools/precon_overrides.json names it as one")

    pool = {}
    for record in records:
        if not _in_core_pool(record):
            continue
        if record.get("faction_code") == aspect:
            pool[record["code"]] = 1 if record.get("is_unique") else 2
        elif record.get("faction_code") == "basic":
            pool[record["code"]] = 1
    return pool


def _read_run(
    identity: dict,
    run: list[dict],
    records: list[dict],
    by_code: dict[str, dict],
    override: dict | None,
) -> dict | None:
    """One identity's run of cards, split into the deck and what is set aside.

    A card in the run is set aside when it is not shuffled into the deck: a permanent
    like Wolverine's Claws, which starts in play, or a card printed into a set of its
    own beside the hero's, which is Daredevil's five senses and Hercules' labors and
    gifts. Counting those in would say a 40-card deck is 45.

    The obligation is set aside too and is *not* in the run -- it starts in the encounter
    deck, so marvelsdb prints it in the pack's `*_encounter.json`. That is why set-aside
    is completed from set membership rather than read from the run alone.
    """
    set_code = identity.get("set_code")
    slots: dict[str, int] = {}
    set_aside: dict[str, int] = {}
    excluded = set((override or {}).get("exclude", ()))

    for card in run:
        # A reprint carries `duplicate_of`, a pack and a position, and no other field of
        # its own -- `build_records` drops all 342 of them. The card it points at is the
        # one to read, and it is also the code to record: a deck holding the pack's own
        # printing of Energy is holding Energy, and the app has no record of the reprint
        # to show. Following the pointer is what makes 19 of these decks agree with
        # marvelcdb card for card.
        code = card.get("duplicate_of") or card["code"]
        record = by_code.get(code)
        if record is None or record.get("type_code") in ("hero", "alter_ego"):
            continue

        # The printed quantity is how many are in the box, which is not always how many
        # one deck may hold. Seven packs print two copies of a card whose own deck limit
        # is 1 -- Two Against the World, Unlikely Duo, Super-Soldiers -- because the
        # second copy is for the *other player* in a two-handed game. Counting both put
        # each of those decks at 41, and Winter Soldier, which has two such cards, at 42.
        quantity = min(card["quantity"], record.get("deck_limit") or card["quantity"])
        quantity = (override or {}).get("slots", {}).get(code, quantity)
        if code in excluded or not quantity:
            continue

        aside = record.get("permanent") or (
            record.get("set_code") and record["set_code"] != set_code
        )
        target = set_aside if aside else slots
        target[code] = target.get(code, 0) + quantity

    if aspect := (override or {}).get("aspect"):
        # The pool belongs to no one hero, so it is not part of anyone's run -- but
        # T'Challa is the last identity in Core and his run would otherwise spill into
        # it. Dropping it here rather than at the run keeps that fact in one place.
        slots = {c: n for c, n in slots.items() if not _in_core_pool(by_code[c])}
        slots.update(_core_pool(aspect, records))

    for code, quantity in (override or {}).get("set_aside", {}).items():
        set_aside[code] = quantity
        slots.pop(code, None)

    # back_link points forward, front to back, so a back side is a card the browse list
    # does not show in its own right and its front is already here. SP//dr is the pack
    # that needs this said of the run as well as of the set: its suit's *back* is a
    # permanent support, so the run offers it as a set-aside card in its own right.
    backs = {r["back_link"] for r in records if r.get("back_link")}
    for code in [c for c in set_aside if c in backs]:
        del set_aside[code]

    for record in records:
        if (
            record.get("set_code") == set_code
            and record["code"] not in slots
            and record["code"] not in set_aside
            and record["code"] not in backs
            and record["code"] != identity["code"]
        ):
            set_aside[record["code"]] = record.get("quantity") or 1

    total = sum(slots.values())
    if total != DECK_SIZE:
        die(
            f"the deck for {identity['name']} ({identity['code']}, set "
            f"{set_code}) reads as {total} cards, not {DECK_SIZE}. Its collector-number "
            "run is not the deck as printed; add an entry keyed on the identity code to "
            "tools/precon_overrides.json saying what the box actually holds."
        )

    aspects = sorted(
        {
            faction
            for code in slots
            if (faction := by_code[code].get("faction_code")) in ASPECT_CODES
        }
    )
    name = identity.get("set_name") or identity["name"]
    return {
        "id": f"pack:{fold_name(name)}",
        "name": name,
        "hero": identity["code"],
        "aspects": aspects,
        "slots": dict(sorted(slots.items())),
        "set_aside": dict(sorted(set_aside.items())),
    }


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
    line("editions", "editions")
    line("decks", "decks")
    line("set aside", "set_aside")
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


def load_precon_overrides() -> dict[str, dict]:
    """The decks whose printed contents their collector-number run cannot give.

    Keyed on the identity's code, which is stable where a set name is not. See the
    file's own comment for what each entry is for.
    """
    path = Path(__file__).with_name("precon_overrides.json")
    if not path.exists():
        return {}
    entries = json.loads(path.read_text(encoding="utf-8")).get("decks", {})
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

    decks = build_decks(records, load_precon_overrides())
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
    editions = {r["edition_of"] for r in records if r.get("edition_of")}
    set_aside = sum(len(deck["set_aside"]) for deck in decks)
    log(f"  cards.json  {len(records)} cards, {with_art} with art")
    log(f"  decks.json  {len(decks)} decks, {set_aside} cards set aside")

    current = {
        "marvelsdb_commit": state.get("commit"),
        "tts_date": save.get("Date"),
        "sheets": len(grids),
        "images": len(crops),
        "cards": len(records),
        "editions": len(editions),
        "decks": len(decks),
        "set_aside": set_aside,
        "unmatched": len(result.unmatched),
    }
    report_diff(read_manifest(), current)
    write_manifest(current)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
