import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/data/card_repository.dart';
import 'package:marvel_champions_cards_viewer/data/marvel_card.dart';
import 'package:marvel_champions_cards_viewer/ui/theme.dart';

/// Tested against the real assets/cards.json rather than a fixture. The point of this
/// layer is to be right about that file's quirks, and a fixture would only assert that
/// the quirks I already knew about are handled.
void main() {
  late List<MarvelCard> all;
  late CardRepository repo;

  setUpAll(() {
    final raw = File('assets/cards.json').readAsStringSync();
    all = (jsonDecode(raw) as List)
        .cast<Map<String, dynamic>>()
        .map(MarvelCard.fromJson)
        .toList();
    repo = CardRepository.parse(
      raw,
      File('assets/decks.json').readAsStringSync(),
    );
  });

  test('every record parses', () {
    expect(all, hasLength(3956));
  });

  group('folding two-sided cards', () {
    test('backs are excluded from browsing', () {
      expect(repo.browsable, hasLength(3632));
    });

    test('no browsable card is the back of another', () {
      final orphans = repo.browsable.where((c) => repo.isBackSide(c.code));
      expect(orphans, isEmpty);
    });

    test('a back is reachable from its front', () {
      final spiderMan = repo.byCode('01001a')!;
      expect(spiderMan.name, 'Spider-Man');
      expect(repo.backOf(spiderMan)?.name, 'Peter Parker');
    });

    // 322 back_links run a->b, but the three Green Goblin villains run b->a. Trusting
    // the letter suffix instead of the link direction gets these backwards.
    test('a link that runs b->a folds the right way round', () {
      expect(repo.isBackSide('02001a'), isTrue);
      expect(repo.isBackSide('02001b'), isFalse);
      expect(repo.frontOfBack('02001a')?.code, '02001b');
    });

    test('a back shared by two fronts does not break the index', () {
      expect(repo.isBackSide('45105b'), isTrue);
      expect(repo.byCode('45105b'), isNotNull);
      expect(repo.browsable.where((c) => c.code == '45105b'), isEmpty);
    });

    // 01043a..01043d are one card in four artworks, linked by nothing. They are four
    // browsable entries, not one card with three backs.
    test('a lettered run that is not a back stays browsable', () {
      for (final code in ['01043a', '01043b', '01043c', '01043d']) {
        expect(repo.isBackSide(code), isFalse, reason: code);
      }
    });

    test('the one self-contained two-sided card keeps its back', () {
      final vision = repo.byCode('26002')!;
      expect(vision.doubleSided, isTrue);
      expect(vision.backName, 'Dense');
      expect(vision.backText, isNotNull);
      expect(repo.backOf(vision), isNull, reason: 'its back is on its own record');
    });
  });

  // Nothing upstream joins the cards that share a name: a card reprinted into a second
  // encounter set gets a wholly new code and no pointer at all, and a hero, an ally and
  // a minion can all be called Hawkeye. `tools/build_assets.py` groups them by name and
  // type and writes `edition_of`; these assert the grouping it arrived at.
  group('editions of one card', () {
    late List<MarvelCard> editions;

    setUp(() {
      editions = repo.browsable.where((c) => c.editionOf != null).toList();
    });

    test('the expected number of cards have another edition', () {
      expect(editions, hasLength(323));
      expect(editions.map((c) => c.editionOf).toSet(), hasLength(206));
    });

    test('a card whose name and type are unique is its own only edition', () {
      final natasha = repo.byCode('08001a')!;
      expect(repo.editionsOf(natasha), [natasha]);
    });

    test('every edition of a card returns the same list, in release order', () {
      // Hydra Mercenary is Core Set, Black Widow and Winter Soldier.
      const codes = ['01101', '08028', '54031'];
      for (final code in codes) {
        expect(
          repo.editionsOf(repo.byCode(code)!).map((c) => c.code),
          codes,
          reason: code,
        );
      }
    });

    test('an edition points at the first of the group, not the one before it', () {
      // Four Corrupt Prison Guards, one per Wrecking Crew villain. A chain would need
      // walking; a direct pointer does not.
      for (final code in ['07023', '07037', '07052']) {
        expect(repo.byCode(code)!.editionOf, '07008', reason: code);
      }
    });

    test('every edition_of names a card that is itself a root', () {
      for (final card in editions) {
        final root = repo.byCode(card.editionOf!);
        expect(root, isNotNull, reason: card.code);
        expect(root!.editionOf, isNull, reason: card.code);
      }
    });

    test('no edition is a back side', () {
      for (final card in editions) {
        expect(repo.isBackSide(card.code), isFalse, reason: card.code);
        expect(repo.isBackSide(card.editionOf!), isFalse, reason: card.code);
      }
    });

    // The detail screen draws one art box for a whole group and swaps only the picture
    // in it. A group that disagreed about its shape would resize under the finger.
    // Two-sidedness is deliberately not asserted with it -- see the test below.
    test('a group agrees on orientation', () {
      for (final card in editions) {
        expect(repo.editionsOf(card).map((c) => c.landscape).toSet(), hasLength(1),
            reason: card.code);
      }
    });

    // Which is why the flip button follows the chosen edition rather than the group:
    // seven groups hold both a card with a back and one without.
    test('a group may disagree about having a second side', () {
      final antMan = repo.editionsOf(repo.byCode('12001a')!);
      expect(antMan.map((c) => c.code), ['12001a', '12001c']);
      expect(repo.backOf(antMan[0]), isNotNull, reason: 'his alter-ego');
      expect(repo.backOf(antMan[1]), isNull, reason: 'the giant form has no back');
    });

    // Grouping is by name *and* type. Name alone would put these in one list, and they
    // are different cards that happen to share a name rather than editions of one.
    test('cards sharing a name but not a type stay apart', () {
      expect(repo.editionsOf(repo.byCode('01001a')!).map((c) => c.code),
          ['01001a', '27030a'], reason: 'the two Spider-Man heroes, not the allies');
      expect(repo.editionsOf(repo.byCode('04045')!), hasLength(7),
          reason: 'the Spider-Man allies, without either hero');
      expect(repo.editionsOf(repo.byCode('50064')!).map((c) => c.code),
          ['50064', '50065', '50066'],
          reason: "Black Widow's villain stages, without her hero card");
    });

    // What the old rule -- two records are one card when every printed field agrees --
    // kept apart, and what a person holding one of them would plainly want to see.
    test('cards differing in what is printed on them are still editions', () {
      // Expert Kang has more health than the standard printing.
      expect(repo.editionsOf(repo.byCode('11003')!).map((c) => c.code),
          ['11003', '11036']);
      // Shuri's Vibranium has a deck limit of 2 where the Core Set's is 3.
      expect(repo.editionsOf(repo.byCode('01044')!).map((c) => c.code),
          ['01044', '51006']);
      // Master Mold I, II and III differ by stage alone.
      expect(repo.editionsOf(repo.byCode('32109')!), hasLength(3));
      // The Wakanda Forever! run differs by resource pip, and Shuri's by a reworded
      // reminder sentence. This is the group the grouping was widened for.
      expect(repo.editionsOf(repo.byCode('01043a')!).map((c) => c.code),
          ['01043a', '01043b', '01043c', '01043d', '51005']);
    });

    // The picker captions each row with where the card was printed, plus what is
    // printed on it where that is not enough: the stage for a villain's three, and the
    // resource pips for a run like Wakanda Forever! whose five agree on set and number.
    // Four groups are separated by none of it and carry a flag saying the code stands
    // in; every row of every group has to end up with a caption of its own.
    test('every edition of a card gets a caption of its own', () {
      for (final card in editions) {
        final group = repo.editionsOf(card);
        final captions = group
            .map((c) => [
                  c.setName ?? c.packName,
                  c.position,
                  c.stage,
                  c.resources.join(),
                  if (c.editionCaptionCode) c.code,
                ].join('/'))
            .toSet();
        expect(captions, hasLength(group.length), reason: card.code);
      }
    });

    // The four that need the code, and the reason each does. Asserted by name so that a
    // data drop adding a fifth shows up as a failure here rather than as two rows in
    // the picker that nothing tells apart.
    test('only the groups that need the code carry the flag', () {
      final flagged = repo.browsable.where((c) => c.editionCaptionCode);
      expect(flagged.map((c) => c.name).toSet(),
          {'Android Efficiency', 'Ant-Man', 'Wasp', 'Apocalypse'});
    });

    // Grouping deliberately ignores where a card sits. An earlier rule also required
    // the editions to be in different encounter sets, which admitted the first of
    // these -- a fifth printing sits in Synthezoid Smackdown -- and refused the second,
    // whose five are all in the Enchantress set and whose scans are byte-identical.
    test('editions in one set or one pack are still one card', () {
      final act = repo.editionsOf(repo.byCode('56063a')!);
      expect(act.map((c) => c.code),
          ['56063a', '56096a', '56121a', '56122a', '57005a']);
      expect(act.where((c) => c.packName == 'Civil War'), hasLength(4));

      final gaze = repo.editionsOf(repo.byCode('55007a')!);
      expect(gaze.map((c) => c.code),
          ['55007a', '55008a', '55009a', '55010a', '55011a']);
      expect(gaze.map((c) => c.setName).toSet(), {'Enchantress'});
    });
  });

  group('back images', () {
    test('an alter-ego portrait comes from the front scan', () {
      // Peter Parker was scanned on the back of Spider-Man's card, so the back image
      // of 01001a is what shows him.
      expect(repo.backImageOf(repo.byCode('01001a')!), '01001ab.webp');
    });

    test('a back with no art anywhere returns null', () {
      final blank = repo.browsable
          .where((c) => c.backLink != null && repo.backImageOf(c) == null);
      expect(blank, isNotEmpty, reason: '5 backs have no scan');
    });
  });

  group('search', () {
    test('folds accents so an ASCII keyboard finds the card', () {
      final names = repo.search('coup de grace').map((c) => c.name);
      expect(names, contains('Coup de Grâce'));
      expect(repo.search('deja vu').map((c) => c.name), contains('Déjà Vu'));
    });

    test('ignores punctuation and case', () {
      expect(repo.search('IM TOUGH').map((c) => c.name), contains('"I\'m Tough"'));
    });

    test('an empty query is everything', () {
      expect(repo.search('  '), hasLength(repo.browsable.length));
    });

    test('never returns a back side', () {
      expect(repo.search('peter parker'), isEmpty);
    });
  });

  group('the data contract the app relies on', () {
    test('the expected number of cards have art', () {
      // 3,759 until 51001a Shuri's Black Panther was pinned. Both Black Panther hero
      // packs hold an object called "Black Panther" and both resolved to 01040a, so
      // Shuri's scan overwrote T'Challa's art and Shuri's card had none.
      //
      // 3,760 until the matcher stopped collapsing a lettered run of codes onto its
      // first code. Fourteen cards were losing their art that way -- the four Wakanda
      // Forever! printings and Shuri's, the Jubilee and Echo pip runs, and Ultron's
      // three Android Efficiency -- because every member of a run wrote one filename
      // and the last crop won.
      //
      // 3,774 until the build stopped trusting the save's UniqueBack flag, which is
      // false on 132 sheets that are a single card's own scanned back. That was every
      // main scheme's second stage and every alter-ego's portrait: 124 cards, and the
      // reason The Break-In! could not be turned over.
      //
      // 3,898 until five scans in the Shuri and Miles bags were pinned to the printing
      // whose bag holds them. Each had resolved to a Core Set card that shares its name
      // and was overwriting that card's art: 01044 wore Shuri's Vibranium, 01008 wore
      // Miles' Web-Shooter, and the alter-ego portrait 01040b wore an ally's card.
      expect(all.where((c) => c.hasArt), hasLength(3903));
      expect(all.where((c) => !c.hasArt), hasLength(53));
    });

    // The build script reads orientation from the TTS save, where it is the only
    // source. A widget must never have to guess it from type_code, which is wrong for
    // eight cards, nor wait for an image to decode.
    test('landscape agrees with the shape of the card image', () {
      final wrong = <String>[];
      for (final card in all) {
        final name = card.frontImage;
        if (name == null) continue;
        final bytes = File('assets/CardImages/$name').readAsBytesSync();
        final size = _webPSize(bytes);
        if (size == null) continue;
        final isWide = size.$1 > size.$2;
        // 42001c Archangel is a genuinely oversized card, 1430x1030, alone on its
        // sheet -- wider than tall without being rotated.
        if (isWide != card.landscape && card.code != '42001c') {
          wrong.add('${card.code} ${card.name}');
        }
      }
      expect(wrong, isEmpty);
    });

    test('every referenced image exists on disk', () {
      final missing = <String>[];
      for (final card in all) {
        for (final name in [card.frontImage, card.backImage]) {
          if (name == null) continue;
          if (!File('assets/CardImages/$name').existsSync()) missing.add(name);
        }
      }
      expect(missing, isEmpty);
    });

    test('stage is a printed marker, not a number', () {
      final staged = all.where((c) => c.stage != null);
      expect(staged, isNotEmpty);
      expect(staged.map((c) => c.stage), contains('1A'));
    });

    test('a stat printed blank is told apart from a stat not printed', () {
      final hulk = repo.byCode('01050')!;
      expect(hulk.name, 'Hulk');
      expect(hulk.thwart, isNull);
      expect(hulk.statPrintedBlank, contains('thwart'));

      final spiderMan = repo.byCode('01001a')!;
      expect(spiderMan.cost, isNull);
      expect(spiderMan.statPrintedBlank, isNot(contains('cost')));
    });

    test('a starred stat keeps both its number and its star', () {
      final charge = repo.byCode('01099')!;
      expect(charge.name, 'Charge');
      expect(charge.attack, 3);
      expect(charge.starred, contains('attack'));
    });
  });

  // The Tabletop Simulator save makes each of these easy to get wrong, and every one
  // of them was wrong in decks.json before the deck screen existed to show it. They
  // are settled in tools/build_assets.py, and asserted here against the real asset.
  group('the pre-built hero pack decks', () {
    test('one per hero pack', () {
      expect(repo.decks, hasLength(67));
    });

    test('ids are unique', () {
      // The screen keys on the id. Two packs are both called "Black Panther Hero
      // Pack", so a name-derived id collided until the set name was used instead.
      final ids = repo.decks.map((deck) => deck.id).toSet();
      expect(ids, hasLength(repo.decks.length));
    });

    test('names are distinct, so two decks are never the same row twice', () {
      final names = repo.decks.map((deck) => deck.name).toSet();
      expect(names, hasLength(repo.decks.length));
    });

    test('every deck knows whose it is, and that hero has art', () {
      for (final deck in repo.decks) {
        final hero = repo.byCode(deck.hero);
        expect(hero, isNotNull, reason: '${deck.name} has no hero record');
        expect(
          hero!.typeCode,
          anyOf('hero', 'alter_ego'),
          reason: '${deck.name} names ${hero.name}, which is not an identity',
        );
        expect(hero.frontImage, isNotNull, reason: '${deck.name} has no portrait');
      }
    });

    test('a hero is never listed among its own deck slots', () {
      for (final deck in repo.decks) {
        expect(deck.slots.keys, isNot(contains(deck.hero)), reason: deck.name);
      }
    });

    test('no slot is the back side of a card', () {
      // 01040b T'Challa was listed by Shuri's deck. A back is not browsable, so it
      // would have been a row that could not be opened.
      for (final deck in repo.decks) {
        for (final code in deck.slots.keys) {
          expect(repo.isBackSide(code), isFalse, reason: '${deck.name} lists $code');
        }
      }
    });

    test('every slot resolves to a card', () {
      for (final deck in repo.decks) {
        for (final code in deck.slots.keys) {
          expect(repo.byCode(code), isNotNull, reason: '${deck.name} lists $code');
        }
      }
    });

    test('every deck is 40 cards, which is the size of a pre-built deck', () {
      // Every deck in the game is 40. The build script fails rather than write one
      // that is not, so this is the assertion that says the whole pipeline is right
      // about a fact with no exceptions -- and it is the one that would have caught
      // reading the save's hero-deck bag, which gave all 67 decks 15 cards.
      for (final deck in repo.decks) {
        expect(
          deck.cardCount,
          40,
          reason: '${deck.name} holds ${deck.cardCount} cards',
        );
      }
    });

    test("Spider-Man's deck is the precon as published", () {
      // The one deck pinned card for card, against marvelcdb decklist 31300. The 40
      // are derived from marvelsdb's printed order, and the Core Set's five need an
      // override on top because Core prints one aspect pool shared by all five heroes
      // -- so nothing but a published list can say this deck is justice and holds two
      // For Justice! where the box holds three. Fifteen of these were missing.
      final deck = repo.decks.firstWhere((deck) => deck.hero == '01001a');
      expect(deck.aspects, ['justice']);
      expect(deck.slots, {
        '01002': 1, '01003': 2, '01004': 2, '01005': 3, '01006': 1,
        '01007': 2, '01008': 2, '01009': 2, // signature
        '01058': 1, '01059': 1, '01060': 2, '01061': 2, '01062': 2,
        '01063': 2, '01064': 2, '01065': 2, // justice
        '01083': 1, '01084': 1, '01085': 1, '01086': 1, '01087': 1, '01088': 1,
        '01089': 1, '01090': 1, '01091': 1, '01092': 1, '01093': 1, // basic
      });
    });

    test('every deck says which aspects it is built from', () {
      for (final deck in repo.decks) {
        expect(deck.aspects, isNotEmpty, reason: deck.name);
        for (final aspect in deck.aspects) {
          expect(
            aspectColours.keys,
            contains(aspect),
            reason: '${deck.name} is built from $aspect, which has no colour',
          );
        }
        // The aspect is the aspect of cards the deck actually holds, not a label
        // alongside it.
        final held = deck.slots.keys
            .map((code) => repo.byCode(code)!.factionCode)
            .toSet();
        expect(held, containsAll(deck.aspects), reason: deck.name);
      }
    });

    test('cardsOf returns every slot, in release order', () {
      for (final deck in repo.decks) {
        final slots = repo.cardsOf(deck);
        expect(slots, hasLength(deck.slots.length), reason: deck.name);
        expect(
          slots.fold(0, (sum, slot) => sum + slot.quantity),
          deck.cardCount,
          reason: deck.name,
        );

        for (var i = 1; i < slots.length; i++) {
          final before = slots[i - 1].card;
          final after = slots[i].card;
          expect(
            _precedes(before, after),
            isTrue,
            reason: '${deck.name}: ${before.code} should not follow ${after.code}',
          );
        }
      }
    });

    test('every deck sets aside at least its obligation', () {
      // A deck is not everything a hero pack gives you. The obligation is not even in
      // the pack's own run -- marvelsdb prints it in the pack's *_encounter.json --
      // which is why set-aside is completed from set membership rather than the run.
      for (final deck in repo.decks) {
        expect(deck.setAside, isNotEmpty, reason: deck.name);
        expect(
          deck.setAside.keys.map((code) => repo.byCode(code)!.typeCode),
          contains('obligation'),
          reason: '${deck.name} sets aside no obligation',
        );
      }
    });

    test('the set-aside permanents are there', () {
      // These were absent entirely: each sits loose in the pack bag rather than in the
      // hero deck, which is the same place the identity card sits.
      expect(_setAsideOf(repo, 'Wolverine'), contains('35002')); // Wolverine's Claws
      expect(_setAsideOf(repo, 'Rogue'), contains('38002')); // Touched
      expect(_setAsideOf(repo, 'Vision'), contains('26002')); // Intangible
      // Spectrum's Photon and Pulsar are states of the Gamma card, not cards in a bag.
      expect(_setAsideOf(repo, 'Spectrum'), containsAll(['21003', '21004']));
      // Psylocke's Psi-Knife is in a "Setup Cards" bag of its own.
      expect(_setAsideOf(repo, 'Psylocke'), contains('41002a'));
      // Angel's alternate hero form, which is a card the deck never holds.
      expect(_setAsideOf(repo, 'Angel'), contains('42001c')); // Archangel
    });

    test('a set-aside card is a real, browsable card with art', () {
      for (final deck in repo.decks) {
        for (final code in deck.setAside.keys) {
          final card = repo.byCode(code);
          expect(card, isNotNull, reason: '${deck.name} sets aside $code');
          expect(repo.isBackSide(code), isFalse, reason: '${deck.name} sets aside $code');
          // The five that had none were the five whose art a Core Set card was wearing.
          expect(card!.hasArt, isTrue, reason: '${deck.name} sets aside $code');
        }
      }
    });

    test('nothing is both in the deck and set aside', () {
      for (final deck in repo.decks) {
        expect(
          deck.setAside.keys.toSet().intersection(deck.slots.keys.toSet()),
          isEmpty,
          reason: deck.name,
        );
        expect(deck.setAside.keys, isNot(contains(deck.hero)), reason: deck.name);
      }
    });

    test('a deck and its set-aside cards account for the whole hero set', () {
      // Every card printed in a hero's set is in the deck, set aside beside it, or is
      // the identity itself -- so none can go missing again. Not the reverse: a deck
      // is 40 cards and a hero set is a dozen, and the rest of the deck is the aspect
      // and basic cards the pack prints alongside, which are in no set at all.
      for (final deck in repo.decks) {
        final setCode = repo.byCode(deck.hero)!.setCode;
        final printed = all
            .where((card) => card.setCode == setCode && !repo.isBackSide(card.code))
            .map((card) => card.code)
            .toSet();
        expect(
          {...deck.slots.keys, ...deck.setAside.keys, deck.hero},
          containsAll(printed),
          reason: deck.name,
        );
      }
    });

    test('setAsideCardsOf returns every card, in release order', () {
      for (final deck in repo.decks) {
        final slots = repo.setAsideCardsOf(deck);
        expect(slots, hasLength(deck.setAside.length), reason: deck.name);
        for (var i = 1; i < slots.length; i++) {
          expect(
            _precedes(slots[i - 1].card, slots[i].card),
            isTrue,
            reason: deck.name,
          );
        }
      }
    });

    test('the two Black Panther decks are told apart', () {
      // Neither the pack name nor the hero's name separates these: both packs are
      // "Black Panther Hero Pack" and both identities are called "Black Panther".
      final panthers =
          repo.decks.where((deck) => deck.name.startsWith('Black Panther')).toList();
      expect(panthers, hasLength(2));
      expect(
        panthers.map((deck) => deck.name),
        containsAll(['Black Panther', 'Black Panther (Shuri)']),
      );
      expect(panthers.map((deck) => deck.hero).toSet(), hasLength(2));
    });
  });
}

/// The codes a named deck sets aside.
Iterable<String> _setAsideOf(CardRepository repo, String name) =>
    repo.decks.firstWhere((deck) => deck.name == name).setAside.keys;

/// Whether [a] comes before [b] in release order: pack position, then position within
/// the pack. Compared as numbers -- a string sort puts card 10 before card 2.
bool _precedes(MarvelCard a, MarvelCard b) {
  for (var i = 0; i < a.sortKey.length && i < b.sortKey.length; i++) {
    if (a.sortKey[i] != b.sortKey[i]) return a.sortKey[i] < b.sortKey[i];
  }
  return a.code.compareTo(b.code) <= 0;
}

/// Width and height from a lossy WebP header, enough to check orientation without
/// pulling in an image package for one assertion.
(int, int)? _webPSize(Uint8List bytes) {
  if (bytes.length < 30) return null;
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;
  final format = String.fromCharCodes(bytes.sublist(12, 16));
  if (format == 'VP8 ') {
    // Frame header sits after the 20-byte chunk header and a 3-byte start code.
    final width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
    final height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
    return (width, height);
  }
  if (format == 'VP8L') {
    final bits = bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
  }
  return null;
}
