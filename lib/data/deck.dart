/// A pre-built deck as `assets/decks.json` carries it: the deck that ships in a hero
/// pack, ready to play out of the box.
///
/// The build script has already settled what the Tabletop Simulator save makes awkward
/// about these -- packs listed twice, two packs sharing a name, a slot naming the back
/// of a card, and the identity card that sits beside a deck rather than in it. So this
/// is a transcription of a record and not a place for rules.
class Deck {
  const Deck({
    required this.id,
    required this.name,
    required this.hero,
    required this.slots,
  });

  /// Unique, and built from the deck's set name rather than its pack name, because two
  /// packs can share a name.
  final String id;

  /// What to call the deck. The set name, which is the identity the deck was printed
  /// for: `Black Panther` and `Black Panther (Shuri)` are two different decks.
  final String name;

  /// The code of the hero or alter-ego card this is the deck of. Never in [slots]: the
  /// save keeps a pack's identity card beside the deck, not inside it.
  final String hero;

  /// How many copies of each card code the deck holds.
  final Map<String, int> slots;

  /// The number of physical cards in the deck.
  int get cardCount => slots.values.fold(0, (sum, count) => sum + count);

  factory Deck.fromJson(Map<String, dynamic> json) {
    return Deck(
      id: json['id'] as String,
      name: json['name'] as String,
      hero: json['hero'] as String,
      slots: (json['slots'] as Map<String, dynamic>).cast<String, int>(),
    );
  }
}
