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
    this.backLink,
    this.variantOf,
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

  /// Points *forward*, from the front of a two-sided card to its back.
  final String? backLink;

  /// The first printing of this card, when this record is a later reprint of it.
  ///
  /// Set by `tools/build_assets.py`, which joins printings by what is printed on them;
  /// nothing upstream links them. Null on a card printed once and on the first printing
  /// of one printed several times, so the root of a group points at nothing.
  final String? variantOf;

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
      backLink: json['back_link'] as String?,
      variantOf: json['variant_of'] as String?,
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
