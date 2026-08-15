/// One card record as `assets/cards.json` carries it.
///
/// The build script has already resolved everything awkward about the upstream data --
/// pack and set names, image filenames, orientation, release order -- so this is a
/// transcription of a record and not a place for rules. A field is null when the card
/// has no such value, which is not the same as zero: a zero-cost card costs nothing,
/// a card with no cost has no cost printed on it at all.
class MarvelCard {
  const MarvelCard({
    required this.code,
    required this.name,
    required this.typeCode,
    required this.factionCode,
    required this.packCode,
    required this.packName,
    required this.position,
    required this.quantity,
    required this.sortKey,
    required this.landscape,
    this.subname,
    this.text,
    this.flavor,
    this.traits,
    this.setCode,
    this.setName,
    this.setPosition,
    this.frontImage,
    this.backImage,
    this.printings = const [],
    this.backLink,
    this.editionOf,
    this.editionCaptionCode = false,
    this.backName,
    this.backText,
    this.doubleSided = false,
    this.illustrator,
    this.errata,
    this.isUnique = false,
    this.permanent = false,
    this.hidden = false,
    this.cost,
    this.attack,
    this.thwart,
    this.defense,
    this.recover,
    this.health,
    this.handSize,
    this.scheme,
    this.boost,
    this.baseThreat,
    this.threat,
    this.escalationThreat,
    this.stage,
    this.deckLimit,
    this.statPrintedBlank = const {},
    this.resourcePhysical,
    this.resourceMental,
    this.resourceEnergy,
    this.resourceWild,
    this.starred = const {},
  });

  final String code;
  final String name;
  final String? subname;
  final String? text;
  final String? flavor;
  final String? traits;

  final String typeCode;
  final String factionCode;
  final String packCode;
  final String packName;
  final String? setCode;
  final String? setName;
  final int position;
  final int? setPosition;
  final int quantity;

  /// Release order: pack position, then position within the pack.
  final List<int> sortKey;

  /// Printed sideways. Read from the TTS save by the build script, because
  /// `typeCode` does not imply it -- a few attachments and allies are landscape
  /// against type, and one side scheme is upright.
  final bool landscape;

  final String? frontImage;
  final String? backImage;

  /// Every printing of this card the scans cover, when the box holds more than one.
  ///
  /// A box printing three copies of a card prints three *different* collector numbers
  /// on them, and the community scanned each copy separately -- so one record can have
  /// three pictures that differ only in the number in the corner. Empty for the great
  /// majority of cards, which have one printing; never one entry long. The first is
  /// always the same file as [frontImage], so a caller that ignores this field still
  /// shows the card.
  ///
  /// This is deliberately not [editionOf]: those are different cards that share a name,
  /// and each has its own record and its own row in the browse list. These are one card,
  /// one record, one row, and several pictures.
  final List<CardPrinting> printings;

  /// Points *forward*, from the front of a two-sided card to its back.
  final String? backLink;

  /// The first card sharing this one's name and type, when this record is a later one.
  ///
  /// Set by `tools/build_assets.py`, which groups cards by name and type; nothing
  /// upstream links them. Null on a card whose name and type are unique and on the
  /// first of a group, so the root of a group points at nothing.
  final String? editionOf;

  /// True when this card's editions cannot be told apart by set, printed number, stage
  /// and resource pips, so the picker has to caption them with their codes instead.
  /// Four groups: Android Efficiency, Ant-Man, Wasp and Apocalypse.
  final bool editionCaptionCode;

  /// The one card whose back is carried on its own record rather than a linked one.
  final String? backName;
  final String? backText;
  final bool doubleSided;

  final String? illustrator;
  final String? errata;
  final bool isUnique;
  final bool permanent;
  final bool hidden;

  final int? cost;
  final int? attack;
  final int? thwart;
  final int? defense;
  final int? recover;
  final int? health;
  final int? handSize;
  final int? scheme;
  final int? boost;
  final int? baseThreat;
  final int? threat;
  final int? escalationThreat;

  /// A printed stage marker, not a number: `1A`, `III`, `B2`.
  final String? stage;
  final int? deckLimit;

  /// Stats the card prints with no number -- Hulk the ally cannot thwart at all, which
  /// upstream spells as a key present and explicitly null. Distinct from a stat the
  /// card simply does not have, which is an absent key.
  final Set<String> statPrintedBlank;

  final int? resourcePhysical;
  final int? resourceMental;
  final int? resourceEnergy;
  final int? resourceWild;

  /// The resource pips printed on this card, named as `ui/card_text.dart` names them.
  ///
  /// A card prints at most one of each but can print two -- Jubilee's Plasmoid Energy
  /// is energy and mental. This is what separates the editions of Wakanda Forever!,
  /// whose five records agree on set and printed number and differ only by the pip.
  List<String> get resources => [
        if (resourcePhysical != null) 'physical',
        if (resourceMental != null) 'mental',
        if (resourceEnergy != null) 'energy',
        if (resourceWild != null) 'wild',
      ];

  /// Stats whose printed value carries a star qualifier, by field name. `Charge` has
  /// an attack of 3 and a starred attack, and the star changes what the number means.
  final Set<String> starred;

  bool get hasArt => frontImage != null;

  factory MarvelCard.fromJson(Map<String, dynamic> json) {
    // marvelsdb spells a starred stat as a sibling boolean, `attack_star` beside
    // `attack`. Collapsing them into one set keeps 20-odd near-duplicate fields off
    // this class without losing which stat the star belongs to.
    final starred = <String>{};
    final blank = <String>{};
    for (final entry in json.entries) {
      if (entry.key.endsWith('_star') && entry.value == true) {
        starred.add(entry.key.substring(0, entry.key.length - '_star'.length));
      } else if (entry.value == null) {
        blank.add(entry.key);
      }
    }

    return MarvelCard(
      code: json['code'] as String,
      name: json['name'] as String,
      subname: json['subname'] as String?,
      text: json['text'] as String?,
      flavor: json['flavor'] as String?,
      traits: json['traits'] as String?,
      typeCode: json['type_code'] as String,
      factionCode: json['faction_code'] as String,
      packCode: json['pack_code'] as String,
      packName: json['pack_name'] as String,
      setCode: json['set_code'] as String?,
      setName: json['set_name'] as String?,
      position: json['position'] as int,
      setPosition: json['set_position'] as int?,
      quantity: json['quantity'] as int,
      sortKey: (json['sort_key'] as List).cast<int>(),
      landscape: json['landscape'] as bool,
      frontImage: json['front_image'] as String?,
      backImage: json['back_image'] as String?,
      printings: [
        for (final printing in (json['printings'] as List? ?? const []))
          CardPrinting.fromJson(printing as Map<String, dynamic>),
      ],
      backLink: json['back_link'] as String?,
      editionOf: json['edition_of'] as String?,
      editionCaptionCode: json['edition_caption_code'] as bool? ?? false,
      backName: json['back_name'] as String?,
      backText: json['back_text'] as String?,
      doubleSided: json['double_sided'] as bool? ?? false,
      illustrator: json['illustrator'] as String?,
      errata: json['errata'] as String?,
      isUnique: json['is_unique'] as bool? ?? false,
      permanent: json['permanent'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      cost: json['cost'] as int?,
      attack: json['attack'] as int?,
      thwart: json['thwart'] as int?,
      defense: json['defense'] as int?,
      recover: json['recover'] as int?,
      health: json['health'] as int?,
      handSize: json['hand_size'] as int?,
      scheme: json['scheme'] as int?,
      boost: json['boost'] as int?,
      baseThreat: json['base_threat'] as int?,
      threat: json['threat'] as int?,
      escalationThreat: json['escalation_threat'] as int?,
      stage: json['stage'] as String?,
      deckLimit: json['deck_limit'] as int?,
      resourcePhysical: json['resource_physical'] as int?,
      resourceMental: json['resource_mental'] as int?,
      resourceEnergy: json['resource_energy'] as int?,
      resourceWild: json['resource_wild'] as int?,
      starred: starred,
      statPrintedBlank: blank,
    );
  }
}

/// One physical copy of a card as the box prints it, and the scan of that copy.
///
/// The [number] is the collector number printed in the card's bottom corner -- the 5 of
/// "CAPTAIN MARVEL 5/15" -- which is the only thing separating a box's three copies of
/// one card. The build script reads it off the scan rather than deriving it, because
/// upstream's `set_position` is wrong for a handful of sets and the copies of two of
/// Groot's cards interleave rather than run consecutively.
class CardPrinting {
  const CardPrinting({required this.number, required this.image});

  final int number;
  final String image;

  factory CardPrinting.fromJson(Map<String, dynamic> json) => CardPrinting(
        number: json['number'] as int,
        image: json['image'] as String,
      );
}
