import '../data/card_repository.dart';
import '../data/marvel_card.dart';
import 'theme.dart';

/// The order the browse list is in.
///
/// Under `ui/` rather than `data/` because two of the orders sort by [typeLabel] and
/// [factionLabel] -- the words on the screen, not the snake_case codes underneath. The
/// two happen to agree today, and a label that was ever renamed would silently reorder
/// a list that sorted on the code instead. `theme.dart` imports `cupertino.dart`, so
/// this is also the only side of the line it can live on.
///
/// Release order is the default and is free: `assets/cards.json` is written in it and
/// [CardRepository.browsable] preserves it, so [sorted] hands the list straight back.
/// The rest are ways of finding a card when its release order is not what you know
/// about it -- the name you half-remember, the cost you can afford, the aspect you are
/// building.
///
/// **Every order but release sorts by a key that is not unique**, and Dart's
/// `List.sort` is an unstable quicksort: 2,174 cards have no printed cost and would
/// otherwise land in whatever order the partitioning happened to leave them, differently
/// on each rebuild. So every comparator falls back to
/// [CardRepository.releaseOrder], which is total. This is not a nicety -- without it a
/// list re-sorts under the reader between two identical frames.
enum CardSort {
  release('Release order'),
  name('Name'),
  cost('Cost'),
  type('Type'),
  aspect('Aspect');

  const CardSort(this.label);

  /// How the order reads in the sort sheet and beside the result count.
  final String label;

  /// [cards] in this order. The input is never modified: the browse list is the
  /// repository's own [CardRepository.browsable] when nothing is searched or filtered,
  /// and sorting it in place would permanently reorder every other screen's idea of
  /// release order.
  List<MarvelCard> sorted(List<MarvelCard> cards) {
    if (this == CardSort.release) return cards;

    // Decorate-sort-undecorate: a name is folded once per card rather than the
    // O(n log n) times a comparator would fold it, which is ~3,600 folds instead of
    // ~90,000 on the unfiltered list.
    final keyed = [
      for (final card in cards) (key: _key(card), card: card),
    ]..sort((a, b) {
        final difference = a.key.compareTo(b.key);
        if (difference != 0) return difference;
        return CardRepository.releaseOrder(a.card, b.card);
      });

    return [for (final entry in keyed) entry.card];
  }

  /// What this order compares, as a single sortable string.
  ///
  /// A string for every order, so there is one comparator rather than five. Cost is
  /// the only numeric one and is zero-padded to sort as a number -- `002` before `010`
  /// -- which needs only two digits for a game whose costliest card is 6.
  String _key(MarvelCard card) => switch (this) {
    // Unreachable: release returns early above. Named so the switch stays exhaustive
    // without a default that would swallow a new value added to this enum.
    CardSort.release => '',
    // Folded the way search folds a query, so `Coup de Grâce` sorts under C rather
    // than after Z, and `"I'm Tough"` sorts under I rather than under the quote.
    CardSort.name => CardRepository.foldName(card.name),
    CardSort.cost => _costKey(card.cost),
    // By the label rather than the code: `alter_ego` is filed under A either way, but
    // it is the words on the screen a reader is scanning for.
    CardSort.type => typeLabel(card.typeCode),
    CardSort.aspect => factionLabel(card.factionCode),
  };

  /// Costs ascend, then the two kinds of card that print no number.
  ///
  /// A card with **no cost at all** -- every villain, scheme and treachery, 2,174 of
  /// the 3,632 -- is not a 0-cost card, and sorting it as one would bury the 233 cards
  /// that genuinely cost nothing. It goes last. Between them sit the 6 cards printing
  /// a literal **X**, which upstream spells as -1: a real printed cost, but not one
  /// that can be filed among the numbers.
  static String _costKey(int? cost) {
    if (cost == null) return '2';
    if (cost < 0) return '1';
    return '0${cost.toString().padLeft(2, '0')}';
  }
}
