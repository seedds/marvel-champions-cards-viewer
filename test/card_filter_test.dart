import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/data/card_filter.dart';
import 'package:marvel_champions_cards_viewer/data/marvel_card.dart';

void main() {
  group('splitting traits', () {
    test('splits on a full stop and a space', () {
      expect(
        CardFilter.splitTraits('Avenger. Superpower.'),
        ['Avenger', 'Superpower'],
      );
    });

    // The reason this is not a split on '.': the game has two dotted acronyms, and
    // naively splitting turns S.H.I.E.L.D. into six one-letter traits.
    test('keeps a dotted acronym whole, wherever it falls in the line', () {
      expect(CardFilter.splitTraits('S.H.I.E.L.D.'), ['S.H.I.E.L.D.']);
      expect(
        CardFilter.splitTraits('S.H.I.E.L.D. Soldier.'),
        ['S.H.I.E.L.D.', 'Soldier'],
      );
      expect(
        CardFilter.splitTraits('Location. S.H.I.E.L.D.'),
        ['Location', 'S.H.I.E.L.D.'],
      );
      expect(CardFilter.splitTraits('A.I.M.'), ['A.I.M.']);
    });

    test('an empty or absent trait line yields nothing', () {
      expect(CardFilter.splitTraits(null), isEmpty);
      expect(CardFilter.splitTraits(''), isEmpty);
    });

    test('no trait in the whole collection is a stray letter or a fragment', () {
      final cards = _loadCards();
      final traits = <String>{};
      for (final card in cards) {
        traits.addAll(CardFilter.splitTraits(card.traits));
      }
      // 221 traits, and the only ones containing a full stop are the two acronyms.
      final dotted = traits.where((t) => t.contains('.')).toList()..sort();
      expect(dotted, ['A.I.M.', 'S.H.I.E.L.D.']);
      expect(traits.where((t) => t.length < 3), isEmpty);
    });
  });

  group('applying a filter', () {
    test('an empty filter passes everything through unchanged', () {
      final cards = _loadCards();
      expect(const CardFilter().apply(cards), same(cards));
    });

    test('facets of different kinds combine with AND', () {
      final cards = _loadCards();
      final filtered = CardFilter(
        types: const {'ally'},
        factions: const {'leadership'},
      ).apply(cards);

      expect(filtered, isNotEmpty);
      for (final card in filtered) {
        expect(card.typeCode, 'ally');
        expect(card.factionCode, 'leadership');
      }
    });

    test('values within one facet combine with OR', () {
      final cards = _loadCards();
      final filtered =
          const CardFilter(factions: {'justice', 'protection'}).apply(cards);
      final factions = filtered.map((c) => c.factionCode).toSet();
      expect(factions, {'justice', 'protection'});
    });

    test('a trait filter matches a card that has the trait among others', () {
      final cards = _loadCards();
      final filtered = const CardFilter(traits: {'S.H.I.E.L.D.'}).apply(cards);
      expect(filtered, isNotEmpty);
      for (final card in filtered) {
        expect(CardFilter.splitTraits(card.traits), contains('S.H.I.E.L.D.'));
      }
    });

    test('counts the facets a person has chosen', () {
      const filter = CardFilter(types: {'ally', 'event'}, factions: {'basic'});
      expect(filter.activeCount, 3);
      expect(filter.isEmpty, isFalse);
      expect(const CardFilter().isEmpty, isTrue);
    });
  });
}

List<MarvelCard> _loadCards() {
  final raw = File('assets/cards.json').readAsStringSync();
  return (jsonDecode(raw) as List)
      .cast<Map<String, dynamic>>()
      .map(MarvelCard.fromJson)
      .toList();
}
