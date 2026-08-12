import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/main.dart';
import 'package:marvel_champions_cards_viewer/ui/card_row.dart';

/// Walks the screens a person actually uses.
///
/// The cases here are the ones the data makes awkward: a landscape card, a card with
/// no scan, and a two-sided card's flip. Each one asserts what should be on screen,
/// because a layout can be technically valid and still show the wrong thing.
///
/// Headless, against the real bundled assets: `flutter test` builds them into
/// `build/unit_test_assets`, so `rootBundle` serves the same cards.json and the same
/// art the app ships with. Only the image *cache* behaves differently from a device,
/// which is why the memory ceiling is asserted in `integration_test/` instead.
void main() {
  // CachingAssetBundle memoises the Future it hands back per key. One created inside a
  // previous test's fake-async zone never completes again, so without this every test
  // after the first waits on the loading spinner forever.
  setUp(rootBundle.clear);

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(const CardViewerApp());

    // The app's startup work is genuinely asynchronous -- a bundle read and an isolate
    // -- while the test clock is fake, so pumpAndSettle cannot advance it and would
    // simply time out. Let real time pass, pump a frame so the FutureBuilders rebuild
    // against what arrived, and repeat until the cards are on screen. Six seconds is
    // far longer than the ~200 ms it takes, and failing loudly beats a silent hang.
    for (var round = 0; round < 300; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(CardRow).evaluate().isNotEmpty) return;
    }
    throw StateError('the app never finished loading');
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).first, query);
    await tester.pumpAndSettle();
  }

  Future<void> openFirstResult(WidgetTester tester) async {
    await tester.tap(find.byType(CardRow).first);
    await tester.pumpAndSettle();
  }

  /// Every asset image currently on screen, with the size it was decoded at.
  List<({String asset, int? cacheWidth})> imagesOnScreen(WidgetTester tester) {
    return tester
        .widgetList<Image>(find.byType(Image))
        .where((image) => image.image is ResizeImage || image.image is AssetImage)
        .map((image) {
      final provider = image.image;
      if (provider is ResizeImage) {
        final inner = provider.imageProvider;
        return (
          asset: inner is AssetImage ? inner.assetName : '?',
          cacheWidth: provider.width,
        );
      }
      return (asset: (provider as AssetImage).assetName, cacheWidth: null);
    }).toList();
  }

  testWidgets('the list shows card art, decoded small', (tester) async {
    await boot(tester);
    expect(find.text('3632 cards'), findsOneWidget);

    final images = imagesOnScreen(tester);
    expect(images, isNotEmpty, reason: 'rows show their card art');
    for (final image in images) {
      expect(image.asset, startsWith('assets/CardImages/'));
      // A row thumbnail is 56pt. Anything near the scan's own 710px means the decode
      // size has been lost and the image cache will fill within a screenful.
      expect(image.cacheWidth, isNotNull, reason: '${image.asset} decodes unresized');
      expect(image.cacheWidth, lessThan(300), reason: image.asset);
    }
  });

  testWidgets('a two-sided card flips to its other side', (tester) async {
    await boot(tester);
    await search(tester, 'black panther');
    await openFirstResult(tester);

    // 01040a Black Panther, whose back is T'Challa the alter-ego.
    expect(find.text('Black Panther'), findsWidgets);

    final flip = find.byTooltip('Flip');
    expect(flip, findsOneWidget, reason: 'a two-sided card offers a flip');
    await tester.tap(flip);
    await tester.pumpAndSettle();

    expect(find.text("T'Challa"), findsWidgets);
    // The back is a different picture, not the front shown twice.
    expect(
      imagesOnScreen(tester).map((i) => i.asset),
      contains('assets/CardImages/01040ab.webp'),
    );
  });

  testWidgets('tapping the art flips the card', (tester) async {
    await boot(tester);
    await search(tester, 'black panther');
    await openFirstResult(tester);

    Iterable<String> assets() => imagesOnScreen(tester).map((i) => i.asset);
    expect(assets(), contains('assets/CardImages/01040a.webp'));

    // The picture is the whole screen, so it is the obvious thing to tap. The AppBar
    // button stays as the affordance that says the card has another side at all.
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(assets(), contains('assets/CardImages/01040ab.webp'));

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(assets(), contains('assets/CardImages/01040a.webp'));
  });

  testWidgets('swiping walks the cards either side', (tester) async {
    await boot(tester);

    // Release order opens the collection with 01002 Black Cat, 01003 Backflip,
    // 01004 Enhanced Spider-Sense, so the third row has a card on either side. Not
    // searched for: a swipe walks the matches that were on screen, and a one-result
    // search has no neighbours to walk to.
    await tester.tap(find.text('Backflip'));
    await tester.pumpAndSettle();
    expect(find.text('Backflip'), findsWidgets);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Enhanced Spider-Sense'), findsWidgets, reason: 'the next card');

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Black Cat'), findsWidgets, reason: 'the previous card');
  });

  testWidgets('a swipe from the very edge still goes back', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);
    expect(find.text('Backflip'), findsWidgets);

    // The iOS back gesture lives in the leading 20pt and must survive the PageView
    // beneath it: a drag from the edge pops, a drag from anywhere else changes card.
    await tester.dragFrom(const Offset(2, 400), const Offset(500, 0));
    await tester.pumpAndSettle();

    expect(find.byType(CardRow), findsAny, reason: 'back on the browse list');
    // The only test here that depends on the platform: the edge-swipe is Cupertino's,
    // and the headless test binding reports as Android, where the gesture does not
    // exist. The app is iOS-only, so the variant states outright what the rest of the
    // file gets for free from running on an iOS device.
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a scanned card shows its art and nothing else', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);

    expect(
      imagesOnScreen(tester).map((i) => i.asset),
      contains('assets/CardImages/01003.webp'),
    );
    // Everything the heading, stats and provenance would say is printed on the scan.
    expect(find.text('Event'), findsNothing, reason: 'no type tag');
    expect(find.text('COST'), findsNothing, reason: 'no stat chips');
    expect(find.textContaining('Card 01003'), findsNothing, reason: 'no provenance');
  });

  testWidgets('an unscanned card falls back to its text', (tester) async {
    await boot(tester);
    // 34033 Psychic Misdirection has no scan anywhere in the TTS save. With no picture
    // to read the card off, the written-out version is all there is.
    await search(tester, 'psychic misdirection');
    await openFirstResult(tester);

    // The text starts where the picture would be. There is no placeholder above it:
    // a box saying "not scanned" is a card's height of nothing, and would push the
    // only information there is below the fold.
    expect(imagesOnScreen(tester), isEmpty, reason: 'no art, and no empty frame');
    // The card's own heading, not the AppBar's title, which has the same words.
    final heading = tester.getTopLeft(find.text('Psychic Misdirection').last);
    expect(heading.dy, lessThan(200),
        reason: 'the name is near the top of the screen, not a card-height down it');

    expect(find.text('Event'), findsOneWidget, reason: 'the type tag is shown');
    expect(find.text('COST'), findsOneWidget, reason: 'the stats are shown');

    // The provenance is the last thing on a list that builds lazily, so it is below
    // the fold until scrolled to. The scrollable has to be named: the card's own text
    // list sits inside the PageView that swipes between cards, so there are two.
    await tester.scrollUntilVisible(
      find.textContaining('Card 34033'),
      200,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.textContaining('Card 34033'), findsOneWidget);
  });

  // 01101 Hydra Mercenary is printed three times -- Core Set's Rhino, Black Widow's
  // nemesis set and Winter Soldier's -- with different art each time and nothing in
  // the data joining them. `tools/build_assets.py` joins them by what is printed.
  testWidgets('a card printed several times offers its other printings',
      (tester) async {
    await boot(tester);
    await search(tester, 'hydra mercenary');
    await openFirstResult(tester);

    Iterable<String> assets() => imagesOnScreen(tester).map((i) => i.asset);
    expect(assets(), contains('assets/CardImages/01101.webp'),
        reason: 'the opened printing is the one on show');

    // Captioned by where each was printed, because a reprint's name, type, traits and
    // text are all identical to the original's.
    expect(find.text('Rhino'), findsOneWidget);
    expect(find.text('Black Widow Nemesis'), findsOneWidget);
    expect(find.text('Winter Soldier Nemesis'), findsOneWidget);

    await tester.tap(find.text('Winter Soldier Nemesis'));
    await tester.pumpAndSettle();
    expect(assets(), contains('assets/CardImages/54031.webp'),
        reason: 'choosing a printing swaps the art above');
  });

  testWidgets('a card printed once shows no picker', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);

    // One printing, so the art keeps the whole screen exactly as it did before.
    expect(find.text('Core Set'), findsNothing);
    expect(imagesOnScreen(tester), hasLength(1));
  });

  testWidgets('the picker on an unscanned card sits below its text',
      (tester) async {
    await boot(tester);
    // 27039 Web-Shooter has no scan; the Core Set's 01008 does. The picker is the way
    // to the art the card does have somewhere.
    await search(tester, 'web-shooter');
    await tester.tap(find.text('Web-Shooter').last);
    await tester.pumpAndSettle();

    expect(find.text('Printed 2 times'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Printed 2 times')).dy,
      greaterThan(tester.getTopLeft(find.text('Web-Shooter').first).dy),
      reason: 'the text comes first, the printings after it',
    );
  });

  testWidgets('a one-sided card offers no flip', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);

    expect(find.text('Backflip'), findsWidgets);
    expect(find.byTooltip('Flip'), findsNothing);
  });

  testWidgets('a landscape card keeps its own orientation', (tester) async {
    await boot(tester);
    await search(tester, 'the break-in');
    await openFirstResult(tester);

    expect(find.text('The Break-In!'), findsWidgets);
    final art = imagesOnScreen(tester)
        .where((i) => i.asset.contains('01097a'))
        .toList();
    expect(art, isNotEmpty, reason: 'the sideways main scheme shows its art');
  });

  testWidgets('a card with no scan is still browsable', (tester) async {
    await boot(tester);
    // The Expert Kang villains, 11034-11039, have no scan anywhere in the TTS save.
    // They must still be listed and openable: their text and stats are complete, and
    // hiding a real card is worse than showing one without its picture.
    await search(tester, 'kang');
    await tester.pumpAndSettle();
    expect(find.byType(CardRow), findsAny);

    await tester.tap(find.text('Kang (Iron Lad)').first);
    await tester.pumpAndSettle();
    expect(find.text('Kang (Iron Lad)'), findsWidgets);
  });

  testWidgets('search narrows the list and clears again', (tester) async {
    await boot(tester);
    await search(tester, 'wakanda forever');
    expect(find.text('3632 cards'), findsNothing);
    expect(find.byType(CardRow), findsAny);

    await search(tester, '');
    expect(find.text('3632 cards'), findsOneWidget);
  });

  testWidgets('the filter sheet offers the facets', (tester) async {
    await boot(tester);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();

    expect(find.text('Aspect'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);

    // Pack, Set and Trait sit below the fold. The browse list is still mounted behind
    // the sheet, so the scroll has to name the sheet's own scrollable.
    final sheetList = find.descendant(
      of: find.byType(DraggableScrollableSheet),
      matching: find.byType(Scrollable),
    );
    for (final facet in ['Pack', 'Set', 'Trait']) {
      await tester.scrollUntilVisible(find.text(facet), 200, scrollable: sheetList);
      expect(find.text(facet), findsOneWidget);
    }
  });

  testWidgets('choosing an aspect filters the list', (tester) async {
    await boot(tester);
    await tester.tap(find.byTooltip('Filter'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilterChip, 'Leadership'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('3632 cards'), findsNothing);
    expect(find.byType(CardRow), findsAny);
  });

  group('the tabs', () {
    Future<void> openTab(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a tab keeps its search while another is on top', (tester) async {
      await boot(tester);
      await search(tester, 'wakanda forever');
      expect(find.text('3632 cards'), findsNothing);

      await openTab(tester, 'Settings');
      expect(find.text('Theme'), findsNothing, reason: 'the header is upper-cased');
      expect(find.text('System'), findsOneWidget);

      // An IndexedStack rather than a rebuild: the query is still typed in.
      await openTab(tester, 'Cards');
      expect(find.text('3632 cards'), findsNothing);
      expect(find.text('wakanda forever'), findsOneWidget);
    });

    testWidgets('the decks tab lists every hero pack deck', (tester) async {
      await boot(tester);
      await openTab(tester, 'Decks');

      expect(find.text('15 cards'), findsAny, reason: 'a deck says how big it is');
      // Both Black Panther packs are listed, and told apart.
      await tester.scrollUntilVisible(find.text('Black Panther (Shuri)'), 200);
      expect(find.text('Black Panther (Shuri)'), findsOneWidget);
    });

    testWidgets('a deck opens, and its cards swipe', (tester) async {
      await boot(tester);
      await openTab(tester, 'Decks');

      await tester.tap(find.text('Spider-Man').first);
      await tester.pumpAndSettle();
      expect(find.byType(CardRow), findsAny, reason: 'the deck lists its cards');
      expect(find.textContaining('\u00d7'), findsAny, reason: 'copies per card');

      await tester.tap(find.byType(CardRow).first);
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsOneWidget);

      // The detail screen covers the tab bar rather than sitting above it.
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('choosing Light repaints the app', (tester) async {
      await boot(tester);
      // The theme as the widgets below MaterialApp actually see it, rather than a
      // Scaffold's own backgroundColor, which is null unless something set it.
      Brightness brightness() =>
          Theme.of(tester.element(find.byType(NavigationBar))).brightness;

      await openTab(tester, 'Settings');

      // Both explicit modes are asserted rather than compared against the starting
      // one: the device's own setting decides what System looks like, so on a light
      // simulator System and Light are the same colour and prove nothing.
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.dark);

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(brightness(), Brightness.light);
    });
  });
}
