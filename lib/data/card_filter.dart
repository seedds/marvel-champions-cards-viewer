import 'marvel_card.dart';

/// A set of chosen facets. Empty means "everything", which is why an unset filter
/// costs nothing to apply.
class CardFilter {
  const CardFilter({
    this.packs = const {},
    this.sets = const {},
    this.types = const {},
    this.factions = const {},
    this.traits = const {},
  });

  final Set<String> packs;
  final Set<String> sets;
  final Set<String> types;
  final Set<String> factions;
  final Set<String> traits;

  int get activeCount =>
      packs.length + sets.length + types.length + factions.length + traits.length;

  bool get isEmpty => activeCount == 0;

  /// Facets combine as AND across kinds and OR within one: a leadership *or* justice
  /// ally, rather than a card that is somehow both aspects at once.
  List<MarvelCard> apply(List<MarvelCard> cards) {
    if (isEmpty) return cards;
    return [
      for (final card in cards)
        if (_matches(card)) card,
    ];
  }

  bool _matches(MarvelCard card) {
    if (packs.isNotEmpty && !packs.contains(card.packName)) return false;
    if (sets.isNotEmpty && (card.setName == null || !sets.contains(card.setName))) {
      return false;
    }
    if (types.isNotEmpty && !types.contains(card.typeCode)) return false;
    if (factions.isNotEmpty && !factions.contains(card.factionCode)) return false;
    if (traits.isNotEmpty) {
      final own = splitTraits(card.traits);
      if (!traits.any(own.contains)) return false;
    }
    return true;
  }

  CardFilter copyWith({
    Set<String>? packs,
    Set<String>? sets,
    Set<String>? types,
    Set<String>? factions,
    Set<String>? traits,
  }) {
    return CardFilter(
      packs: packs ?? this.packs,
      sets: sets ?? this.sets,
      types: types ?? this.types,
      factions: factions ?? this.factions,
      traits: traits ?? this.traits,
    );
  }

  /// Traits are one full-stop separated string -- `Avenger. Superpower.` -- so they
  /// split on a full stop *followed by a space*. Splitting on the full stop alone
  /// shreds `S.H.I.E.L.D.` into six single letters.
  ///
  /// The trailing stop is punctuation and comes off, except on a dotted acronym where
  /// it belongs to the word. Without that exception `S.H.I.E.L.D.` and `S.H.I.E.L.D`
  /// are two different traits depending on where in the line they fell.
  static List<String> splitTraits(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final traits = <String>[];
    for (final part in raw.split(RegExp(r'\.\s+'))) {
      final trait = _clean(part);
      if (trait.isNotEmpty) traits.add(trait);
    }
    return traits;
  }

  static final _acronym = RegExp(r'^(?:[A-Z]\.)+[A-Z]?\.$');

  static String _clean(String part) {
    final text = part.trim();
    if (text.isEmpty) return '';
    final dotted = text.endsWith('.') ? text : '$text.';
    if (_acronym.hasMatch(dotted)) return dotted;
    return (text.endsWith('.') ? text.substring(0, text.length - 1) : text).trim();
  }
}
