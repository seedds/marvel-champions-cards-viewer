# Marvel Champions Cards Viewer

An offline card reference for *Marvel Champions: The Card Game*. Every card and every
scan ships inside the app — it never reaches the network to show you a card.

Three tabs: a browser over all 3,632 cards with search and filters, the 67 pre-built
hero pack decks, and a theme setting. A card's detail screen swipes to its neighbours,
flips a two-sided card, and picks between the printings of a card printed more than
once.

iOS only for now.

## Getting started

**A fresh clone has card data and no art.** `assets/cards.json` is committed;
`assets/CardImages/` is not — it is ~750 MB, and the build script generates it.

```sh
flutter pub get

# Fetches the scan sheets and crops every card out of them.
# The first run costs ~9.2 GB and a few hours; it is cached, so later runs are seconds.
python tools/build_assets.py

flutter run -d <simulator-id>
```

The script needs `~/Documents/marvelsdb-json-data` checked out beside this repo, and
Python 3.12 with Pillow. Override the input paths with `MC_JSON_DATA`, `MC_TTS_SAVE`
and `MC_CACHE_DIR` if yours live elsewhere.

```sh
python tools/build_assets.py --dry-run      # report what would change, touch nothing
python tools/build_assets.py --skip-images  # rebuild the JSON only, no network
```

## Tests

```sh
flutter analyze                                   # must be clean
flutter test                                      # 76 tests, ~8s, headless
flutter test integration_test -d <simulator-id>   # the memory ceiling, needs a device
```

`flutter test` covers the data layer, the text rules and the screens, headless against
the real bundled art. Only the image-cache ceiling needs a real device, and that is the
only thing left in `integration_test/`.

## How it works

[`AGENTS.md`](AGENTS.md) is the real documentation: where the data comes from, how a
community scan is matched to a card code, and the long list of things about this data
that are easy to get wrong. Read it before changing the pipeline.

The short version: two inputs, joined by `tools/build_assets.py`. **marvelsdb-json-data**
is authoritative for every fact about a card but carries no art; a **Tabletop Simulator
save** of the community's high-resolution scans is authoritative for art but records no
card codes. Nothing joins them directly, and hundreds of card names are shared, so the
script resolves them through a cascade of signals and fails the build on anything it
cannot resolve.

## Credits

This is an unofficial fan project, not affiliated with or endorsed by anyone below.

- **Card data** — [marvelsdb-json-data](https://github.com/zzorba/marvelsdb-json-data),
  licensed ISC. Names, text, stats, traits and sets all come from there.
- **Card art** — the community's *Marvel Champions High-Resolution Scans* project for
  Tabletop Simulator. `2665262903.json` is that save file, included here as a build
  input so a clone can rebuild the art. The scans themselves are not committed.
- **The game** — *Marvel Champions: The Card Game* is © Fantasy Flight Games. Marvel
  characters and art are © Marvel. All card text and images are their property.

The code in this repository is MIT licensed — see [LICENSE](LICENSE). That covers the
app and the build script, and nothing else: the card data and the art are not this
project's to license.
