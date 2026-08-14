import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/data/card_repository.dart';
import 'package:marvel_champions_cards_viewer/data/marvel_card.dart';
import 'package:marvel_champions_cards_viewer/ui/card_sort.dart';

/// Against the real assets/cards.json, like the rest of the data tests: the orders are
/// only interesting where the collection is awkward -- 2,174 cards with no cost, six
/// printing an X, and a hundred names an ASCII keyboard cannot type.
void main() {
  late CardRepository repo;
  late List<MarvelCard> all;

  setUpAll(() {
    repo = CardRepository.parse(
      File('assets/cards.json').readAsStringSync(),
      File('assets/decks.json').readAsStringSync(),
    );
    all = repo.browsable;
  });

  test('release order is the list untouched', () {
    // Not merely equal: identical. cards.json is written in release order, so the
    // default costs nothing at all -- if this ever starts copying, 3,632 cards are
    // being sorted on every keystroke to arrive back where they started.
    expect(identical(CardSort.release.sorted(all), all), isTrue);
  });

  test('sorting leaves the caller\'s list alone', () {
    final before = List<MarvelCard>.from(all);
    CardSort.name.sorted(all);
    expect(all, orderedEquals(before),
        reason: 'browsable is the repository\'s own list, not a copy to sort in place');
  });

  test('every order keeps every card', () {
    for (final sort in CardSort.values) {
      expect(sort.sorted(all), hasLength(all.length), reason: sort.name);
      expect(sort.sorted(all).toSet(), all.toSet(), reason: sort.name);
    }
  });

  group('by name', () {
    test('runs from a number through to Zzzax', () {
      final sorted = CardSort.name.sorted(all);
      expect(sorted.first.name, '616 Hickory Branch Lane',
          reason: 'digits fold to themselves and sort before letters');
      expect(sorted.last.name, 'Zzzax');
    });

    // The whole reason this folds rather than comparing the raw strings: an accented
    // capital sorts after every ASCII letter in code-unit order, so Coup de Grâce
    // would land past Zzzax and Déjà Vu with it.
    test('an accent sorts under its plain letter', () {
      final sorted = CardSort.name.sorted(all);
      final names = [for (final card in sorted) card.name];

      // Coup de Grâce is printed three times, so it is a run rather than one row: the
      // neighbours to check are the ones either side of the whole run. Sorted on the
      // raw string, the accented â sorts after every ASCII letter and the run would
      // land past Zzzax instead of between these two.
      final first = names.indexOf('Coup de Grâce');
      final last = names.lastIndexOf('Coup de Grâce');
      expect(first, isNot(-1));
      expect(last - first, 2, reason: 'three printings, contiguous');
      expect(names[first - 1], 'Coup de Foudre');
      expect(names[last + 1], 'Covert Ops');
    });

    test('punctuation is not a sort key', () {
      // `"I'm Tough"` opens with a quote, which in code-unit order sorts before every
      // letter and would file the card at the very top of the list.
      final sorted = CardSort.name.sorted(all);
      final index = sorted.indexWhere((c) => c.name.contains("I'm Tough"));
      expect(index, isNot(-1));
      expect(CardRepository.foldName(sorted[index].name), startsWith('imtough'));
      expect(index, greaterThan(100), reason: 'filed under I, not under the quote');
    });

    test('the whole list is in folded order', () {
      final sorted = CardSort.name.sorted(all);
      for (var i = 1; i < sorted.length; i++) {
        expect(
          CardRepository.foldName(sorted[i - 1].name)
              .compareTo(CardRepository.foldName(sorted[i].name)),
          lessThanOrEqualTo(0),
          reason: '${sorted[i - 1].name} before ${sorted[i].name}',
        );
      }
    });
  });

  group('by cost', () {
    test('numbers ascend, then X, then the cards with no cost', () {
      final sorted = CardSort.cost.sorted(all);
      final costs = [for (final card in sorted) card.cost];

      // The three bands, in order: 0..6, then the six X cards, then everything with no
      // printed cost at all.
      final firstX = costs.indexWhere((cost) => cost != null && cost < 0);
      final firstNull = costs.indexOf(null);
      expect(firstX, lessThan(firstNull), reason: 'X is a printed cost; absent is not');

      for (var i = 1; i < firstX; i++) {
        expect(costs[i - 1]!, lessThanOrEqualTo(costs[i]!));
      }
      expect(costs.sublist(firstX, firstNull), everyElement(-1));
      expect(costs.sublist(firstNull), everyElement(isNull));
    });

    // 233 cards genuinely cost nothing and 2,174 print no cost at all. Sorting the
    // second as zero would bury the first under seven times their number.
    test('a card with no cost is not sorted as a zero-cost card', () {
      final sorted = CardSort.cost.sorted(all);
      expect(sorted.first.cost, 0);
      expect(sorted.last.cost, isNull);

      final zeroes = all.where((c) => c.cost == 0).length;
      expect(sorted.take(zeroes), everyElement(predicate<MarvelCard>((c) => c.cost == 0)),
          reason: 'the 0-cost cards are the whole of the head of the list');
    });
  });

  test('by type and by aspect run in label order', () {
    expect(CardSort.type.sorted(all).first.typeCode, 'ally');
    expect(CardSort.type.sorted(all).last.typeCode, 'villain');
    expect(CardSort.aspect.sorted(all).first.factionCode, 'aggression');
    expect(CardSort.aspect.sorted(all).last.factionCode, 'protection');
  });

  // Dart's List.sort is an unstable quicksort, and every order here has thousands of
  // ties -- 2,174 cards share "no cost" alone. Without an explicit tiebreak the list
  // reshuffles under the reader between two identical frames.
  group('ties are broken by release order', () {
    test('sorting twice gives the same list', () {
      for (final sort in CardSort.values) {
        final once = sort.sorted(all).map((c) => c.code).toList();
        final twice = sort.sorted(all).map((c) => c.code).toList();
        expect(once, orderedEquals(twice), reason: sort.name);
      }
    });

    test('the same order arrived at from a different input order', () {
      // The comparator is total only if it never consults the input order. Feed it the
      // list backwards and the answer must not move.
      final backwards = all.reversed.toList();
      for (final sort in CardSort.values.where((s) => s != CardSort.release)) {
        expect(
          sort.sorted(backwards).map((c) => c.code),
          orderedEquals(sort.sorted(all).map((c) => c.code)),
          reason: sort.name,
        );
      }
    });

    test('cards sharing a key stay in the order the game printed them', () {
      // The three Hydra Mercenaries share a name and a type, and none of them has a
      // cost, so they tie under every order but release.
      final sorted = CardSort.cost.sorted(all);
      final codes = [
        for (final card in sorted)
          if (card.name == 'Hydra Mercenary') card.code,
      ];
      expect(codes, ['01101', '08028', '54031']);
    });
  });
}
