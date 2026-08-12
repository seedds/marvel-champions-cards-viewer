import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'deck.dart';
import 'marvel_card.dart';

/// Every card, and the answers the screens need about them.
///
/// Built once at startup from `assets/cards.json`. The awkward parts of the data are
/// settled here rather than in a widget: which records are the back of another card,
/// how a name is matched when the user cannot type an accent, and what a card's back is.
class CardRepository {
  const CardRepository._(
    this.browsable,
    this.decks,
    this._byCode,
    this._backToFront,
    this._printingsByRoot,
    this._foldedNames,
  );

  /// The cards a person browses: fronts and standalone cards, in release order.
  /// A two-sided card appears once, as its front.
  final List<MarvelCard> browsable;

  /// The pre-built deck from each hero pack, in the release order of its hero.
  final List<Deck> decks;

  final Map<String, MarvelCard> _byCode;
  final Map<String, String> _backToFront;

  /// Every printing of a card, keyed by the code of its first printing. Only cards
  /// printed more than once are in here -- 38 groups over 97 cards.
  final Map<String, List<MarvelCard>> _printingsByRoot;

  /// Folded name per entry of [browsable], in the same order, so filtering a query
  /// never re-folds 3,600 names.
  final List<String> _foldedNames;

  static Future<CardRepository> load() async {
    final cards = await rootBundle.loadString('assets/cards.json');
    final decks = await rootBundle.loadString('assets/decks.json');
    // 2.2 MB of JSON, off the UI thread so the first frame is not held up by it.
    return compute((sources) => _parse(sources.$1, sources.$2), (cards, decks));
  }

  /// Build from the contents of cards.json and decks.json. Public so a test can read
  /// the assets from disk without a bundle behind them.
  @visibleForTesting
  static CardRepository parse(String cards, String decks) => _parse(cards, decks);

  /// Strip a name down to what a person can type: no accents, no punctuation, no case.
  /// `Coup de Grâce` and `Déjà Vu` have to be reachable from an ASCII keyboard, and
  /// `"I'm Tough"` without guessing the quotes. This mirrors `fold_name` in
  /// `tools/build_assets.py`, which matched the scans by the same rule.
  static String foldName(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.toLowerCase().runes) {
      final char = String.fromCharCode(rune);
      final folded = _accents[char] ?? char;
      for (final code in folded.codeUnits) {
        final isDigit = code >= 0x30 && code <= 0x39;
        final isLetter = code >= 0x61 && code <= 0x7A;
        if (isDigit || isLetter) buffer.writeCharCode(code);
      }
    }
    return buffer.toString();
  }

  static const _accents = <String, String>{
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
    'ñ': 'n', 'ç': 'c', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
  };

  MarvelCard? byCode(String code) => _byCode[code];

  /// The other side of [card], or null when it has only one.
  ///
  /// Two-sided cards come in two shapes. Nearly all are two records joined by
  /// `back_link`, where the back carries its own name, text and stats. One card,
  /// `26002` Intangible, holds both faces on a single record. Missing the second shape
  /// silently halves that card.
  MarvelCard? backOf(MarvelCard card) {
    final link = card.backLink;
    if (link != null) return _byCode[link];
    return null;
  }

  /// The image to show for the back of [card], which is not always the back record's
  /// own front image: for a scan that carried both faces it is the front's back image.
  /// 125 backs have no art at all and return null.
  String? backImageOf(MarvelCard card) {
    if (card.backImage != null) return card.backImage;
    return backOf(card)?.frontImage;
  }

  /// Every printing of [card], in release order, [card] itself among them.
  ///
  /// A card printed once returns just itself, so a caller never has to special-case the
  /// common one. The 38 cards printed into more than one encounter set -- Hydra
  /// Mercenary across three, Corrupt Prison Guard across four -- return the whole run,
  /// which is the same list whichever of them is asked.
  List<MarvelCard> printingsOf(MarvelCard card) =>
      _printingsByRoot[card.variantOf ?? card.code] ?? [card];

  /// True when [card] is the back of some other card, and so is not browsed in its
  /// own right. Computed from what links *to* a record, because the letter suffix
  /// lies: 322 links run a->b but three run b->a.
  bool isBackSide(String code) => _backToFront.containsKey(code);

  /// The front whose back is [code].
  MarvelCard? frontOfBack(String code) {
    final front = _backToFront[code];
    return front == null ? null : _byCode[front];
  }

  /// Cards whose name contains [query], folded so accents and punctuation do not
  /// matter. An empty query is every browsable card.
  List<MarvelCard> search(String query) {
    final needle = foldName(query);
    if (needle.isEmpty) return browsable;
    final matches = <MarvelCard>[];
    for (var i = 0; i < browsable.length; i++) {
      if (_foldedNames[i].contains(needle)) matches.add(browsable[i]);
    }
    return matches;
  }

  /// The cards a [Deck] holds, in release order, each with how many copies of it the
  /// deck contains. A deck's own hero is not among them: it sits beside the deck in the
  /// pack rather than in it, and is [Deck.hero].
  List<({MarvelCard card, int quantity})> cardsOf(Deck deck) {
    final cards = [
      for (final entry in deck.slots.entries)
        if (_byCode[entry.key] case final MarvelCard card)
          (card: card, quantity: entry.value),
    ];
    cards.sort((a, b) => _releaseOrder(a.card, b.card));
    return cards;
  }

  static int _releaseOrder(MarvelCard a, MarvelCard b) {
    for (var i = 0; i < a.sortKey.length && i < b.sortKey.length; i++) {
      final difference = a.sortKey[i].compareTo(b.sortKey[i]);
      if (difference != 0) return difference;
    }
    return a.code.compareTo(b.code);
  }

  static CardRepository _parse(String raw, String deckRaw) {
    final records = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    final cards = records.map(MarvelCard.fromJson).toList(growable: false);

    final byCode = {for (final card in cards) card.code: card};

    // A record is the back of another when something links to it. Two fronts can share
    // one back -- 45105b is the back of two Age of Apocalypse side schemes -- so the
    // first front to claim it wins and the second is not lost, it simply is not the
    // one this map names.
    final backToFront = <String, String>{};
    for (final card in cards) {
      final link = card.backLink;
      if (link != null) backToFront.putIfAbsent(link, () => card.code);
    }

    final browsable = [
      for (final card in cards)
        if (!backToFront.containsKey(card.code)) card,
    ];

    // `variant_of` names the first printing directly rather than the one before it, so
    // a group is one pass and needs no walk to a root. The build script guarantees that:
    // it links every member of a group to the group's first card.
    final printingsByRoot = <String, List<MarvelCard>>{};
    for (final card in browsable) {
      final root = card.variantOf;
      if (root == null) continue;
      printingsByRoot
          .putIfAbsent(root, () => [byCode[root]!])
          .add(card);
    }

    final decks = (jsonDecode(deckRaw) as List)
        .cast<Map<String, dynamic>>()
        .map(Deck.fromJson)
        .toList(growable: false);

    return CardRepository._(
      browsable,
      decks,
      byCode,
      backToFront,
      printingsByRoot,
      [for (final card in browsable) foldName(card.name)],
    );
  }
}
