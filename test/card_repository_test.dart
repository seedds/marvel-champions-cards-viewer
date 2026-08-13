import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/data/card_repository.dart';
import 'package:marvel_champions_cards_viewer/data/marvel_card.dart';

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

  // A card reprinted into a second encounter set gets a wholly new code and nothing
  // upstream joins it to the first. `tools/build_assets.py` joins them by what is
  // printed on them and writes `variant_of`; these assert the join it arrived at.
  group('printings of one card', () {
    late List<MarvelCard> variants;

    setUp(() {
      variants = repo.browsable.where((c) => c.variantOf != null).toList();
    });

    test('the expected number of cards are reprints', () {
      expect(variants, hasLength(67));
      expect(variants.map((c) => c.variantOf).toSet(), hasLength(43));
    });

    test('a card printed once is its own only printing', () {
      final rhino = repo.byCode('01113')!;
      expect(repo.printingsOf(rhino), [rhino]);
    });

    test('every printing of a card returns the same list, in release order', () {
      // Hydra Mercenary is Core Set, Black Widow and Winter Soldier.
      const codes = ['01101', '08028', '54031'];
      for (final code in codes) {
        expect(
          repo.printingsOf(repo.byCode(code)!).map((c) => c.code),
          codes,
          reason: code,
        );
      }
    });

    test('a printing points at the first printing, not the one before it', () {
      // Four Corrupt Prison Guards, one per Wrecking Crew villain. A chain would need
      // walking; a direct pointer does not.
      for (final code in ['07023', '07037', '07052']) {
        expect(repo.byCode(code)!.variantOf, '07008', reason: code);
      }
    });

    test('every variant_of names a card that is not itself a reprint', () {
      for (final card in variants) {
        final root = repo.byCode(card.variantOf!);
        expect(root, isNotNull, reason: card.code);
        expect(root!.variantOf, isNull, reason: card.code);
      }
    });

    test('no printing is a back side', () {
      for (final card in variants) {
        expect(repo.isBackSide(card.code), isFalse, reason: card.code);
        expect(repo.isBackSide(card.variantOf!), isFalse, reason: card.code);
      }
    });

    // The detail screen draws one art box for a whole group and swaps only the picture
    // in it. A group that disagreed about its shape would resize under the finger.
    test('a group agrees on orientation and on having a second side', () {
      for (final card in variants) {
        final group = repo.printingsOf(card);
        expect(group.map((c) => c.landscape).toSet(), hasLength(1),
            reason: card.code);
        expect(
          group.map((c) => c.backLink != null || c.doubleSided).toSet(),
          hasLength(1),
          reason: card.code,
        );
      }
    });

    // What separates a reprint from a card that merely shares a name. Each of these is
    // a pair the join has to refuse, and each refuses it for a different reason.
    test('cards that share a name but not their printing stay apart', () {
      // Expert Kang has more health than the standard printing.
      expect(repo.printingsOf(repo.byCode('11003')!), hasLength(1));
      // Shuri's Vibranium has a deck limit of 2 where the Core Set's is 3.
      expect(repo.printingsOf(repo.byCode('01044')!), hasLength(1));
      // Master Mold I, II and III differ by stage alone.
      expect(repo.printingsOf(repo.byCode('32109')!), hasLength(1));
      // The Wakanda Forever! run shares its encounter set and differs by resource pip.
      expect(repo.printingsOf(repo.byCode('01043a')!), hasLength(1));
    });

    // A reprint differs in nothing a card row shows -- same name, type, traits and
    // text -- so the picker captions each row with where the card was printed instead.
    // The printed number is part of that caption because set and pack alone are not
    // unique: Civil War prints Superhero Registration Act four times, at 63, 96, 121 and
    // 122, and 56096a and 56122a even have byte-identical art. Without the number those
    // are four rows a person cannot tell apart.
    test('every printing of a card gets a caption of its own', () {
      for (final card in variants) {
        final group = repo.printingsOf(card);
        final captions = group
            .map((c) => '${c.setName ?? c.packName}/${c.packName}/${c.position}')
            .toSet();
        expect(captions, hasLength(group.length), reason: card.code);
      }
    });

    // Grouping deliberately ignores where a card sits. An earlier rule also required
    // the printings to be in different encounter sets, which admitted the first of
    // these -- a fifth printing sits in Synthezoid Smackdown -- and refused the second,
    // whose five are all in the Enchantress set and whose scans are byte-identical.
    test('printings in one set or one pack are still one card', () {
      final act = repo.printingsOf(repo.byCode('56063a')!);
      expect(act.map((c) => c.code),
          ['56063a', '56096a', '56121a', '56122a', '57005a']);
      expect(act.where((c) => c.packName == 'Civil War'), hasLength(4));

      final gaze = repo.printingsOf(repo.byCode('55007a')!);
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

    test('a deck is the size of a real pre-built deck', () {
      // Daredevil and Echo read as 30 cards each: the save holds their packs both
      // loose and inside a patch bag, so every copy was counted twice.
      for (final deck in repo.decks) {
        expect(
          deck.cardCount,
          allOf(greaterThanOrEqualTo(15), lessThanOrEqualTo(16)),
          reason: '${deck.name} holds ${deck.cardCount} cards',
        );
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
      // The 15-card deck is not everything a hero pack gives you, and the save keeps
      // the rest in three different places -- loose beside the identity, as a state of
      // another card, or in a bag of its own. These come from set membership instead.
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

    test('a deck and its set-aside cards are the whole of the hero set', () {
      // The point of deriving these from set membership: every card printed in a
      // hero's set is accounted for exactly once, so none can go missing again.
      for (final deck in repo.decks) {
        final setCode = repo.byCode(deck.hero)!.setCode;
        final printed = all
            .where((card) => card.setCode == setCode && !repo.isBackSide(card.code))
            .map((card) => card.code)
            .toSet();
        expect(
          {...deck.slots.keys, ...deck.setAside.keys, deck.hero},
          printed,
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
