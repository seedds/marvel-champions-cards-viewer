import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/main.dart';
import 'package:marvel_champions_cards_viewer/ui/browse_screen.dart';
import 'package:marvel_champions_cards_viewer/ui/card_detail_screen.dart';
import 'package:marvel_champions_cards_viewer/ui/card_row.dart';
import 'package:marvel_champions_cards_viewer/ui/card_text.dart';

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
    await tester.enterText(find.byType(CupertinoTextField).first, query);
    await tester.pumpAndSettle();
  }

  /// The filter and flip buttons are found by their icon: iOS has no tooltip, which is
  /// how the Material versions were found.
  Finder button(IconData icon) => find.byIcon(icon);

  /// An edition row's caption, by the markup it is written in. `find.text` cannot see
  /// these: a caption is a [CardText], so a `[wild]` pip is a WidgetSpan drawn as the
  /// same lozenge the card's own text uses, and the rendered string has a hole in it.
  Finder caption(String markup) => find.byWidgetPredicate(
        (widget) => widget is CardText && widget.text == markup,
      );

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

    final flip = button(flipIcon);
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

    // The picture is the whole screen, so it is the obvious thing to tap. The nav bar
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
    // The only test here that depends on the platform: the edge-swipe is the iOS back
    // gesture, and the headless test binding reports as Android, where it does not
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
    // The card's own heading, not the nav bar's title, which has the same words.
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
  // the data joining them. `tools/build_assets.py` groups them by name and type.
  testWidgets('a card with other editions offers them', (tester) async {
    await boot(tester);
    await search(tester, 'hydra mercenary');
    await openFirstResult(tester);

    Iterable<String> assets() => imagesOnScreen(tester).map((i) => i.asset);
    expect(assets(), contains('assets/CardImages/01101.webp'),
        reason: 'the opened edition is the one on show');

    // Each row leads with the card's name, as every other row in the app does, and is
    // told apart by the caption under it -- these three agree on type, traits and text,
    // so where each was printed is the only difference. Three rows plus the nav title.
    expect(find.text('Hydra Mercenary'), findsNWidgets(4));
    expect(caption('Rhino  \u00b7  #101'), findsOneWidget);
    expect(caption('Black Widow Nemesis  \u00b7  #28'), findsOneWidget);
    expect(caption('Winter Soldier Nemesis  \u00b7  #31'), findsOneWidget);

    await tester.tap(caption('Winter Soldier Nemesis  \u00b7  #31'));
    await tester.pumpAndSettle();
    expect(assets(), contains('assets/CardImages/54031.webp'),
        reason: 'choosing an edition swaps the art above');
  });

  // The five Wakanda Forever! cards are why the grouping is by name and type rather
  // than by what is printed on them: 01043a-d differ by resource pip and deck limit,
  // and Shuri's 51005 rewords a reminder sentence, so a rule wanting every printed
  // field to agree left each of them alone on the screen.
  testWidgets('editions differing by a resource pip are told apart by it',
      (tester) async {
    await boot(tester);
    await search(tester, 'wakanda forever');
    await openFirstResult(tester);

    // All four Core Set printings caption as "Black Panther · #43", so the pip is the
    // only thing between them. CardText draws it as the lozenge the card's text uses,
    // which is why these are found as a caption rather than as flat text.
    expect(caption('Black Panther  \u00b7  #43  \u00b7  [energy]'), findsOneWidget);
    expect(caption('Black Panther  \u00b7  #43  \u00b7  [mental]'), findsOneWidget);
    expect(caption('Black Panther  \u00b7  #43  \u00b7  [physical]'), findsOneWidget);
    expect(caption('Black Panther  \u00b7  #43  \u00b7  [wild]'), findsOneWidget);

    // Shuri's is the fifth row, and the picker draws four before it scrolls, so it is
    // not built until scrolled to. It needs no pip to separate it -- a different set
    // and number already do -- but it carries one, as the caption is per card.
    const shuri = 'Black Panther (Shuri)  \u00b7  #5  \u00b7  [wild]';
    expect(caption(shuri), findsNothing, reason: 'the fifth row is below the fold');
    await tester.drag(find.byType(CardThumbnail).last, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(caption(shuri), findsOneWidget);

    await tester.tap(caption(shuri));
    await tester.pumpAndSettle();
    expect(imagesOnScreen(tester).map((i) => i.asset),
        contains('assets/CardImages/51005.webp'));
  });

  // Ant-Man's alter-ego is the back of 12001a; his giant form 12001c has no back at
  // all. Seven groups mix the two, so the flip button belongs to the chosen edition
  // rather than to the card the page was opened at.
  testWidgets('the flip button follows the chosen edition', (tester) async {
    await boot(tester);
    await search(tester, 'ant-man');
    await openFirstResult(tester);

    expect(button(flipIcon), findsOneWidget, reason: '12001a has an alter-ego');

    await tester.tap(caption('Ant-Man  \u00b7  #1  \u00b7  12001c'));
    await tester.pumpAndSettle();
    expect(button(flipIcon), findsNothing,
        reason: 'the giant form has no second side to turn to');
  });

  testWidgets('a card with no other edition shows no picker', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);

    // One edition, so the art keeps the whole screen exactly as it did before: no
    // picker row, and so no caption naming the set Backflip was printed in.
    expect(caption('Spider-Man  \u00b7  #3'), findsNothing);
    expect(imagesOnScreen(tester), hasLength(1));
  });

  // A phone shape on purpose. On the 800x600 default a portrait scan is limited by the
  // height and fills the space whether it is top-aligned or centred, so these
  // assertions would pass either way and prove nothing. At 390x844 the scan is limited
  // by the width, leaving real slack for the layout to place.
  group('on a phone-shaped screen', () {
    setUp(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(390, 844);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
    });

    testWidgets('the art sits at the top with its editions under it',
        (tester) async {
      await boot(tester);
      await search(tester, 'hydra mercenary');
      await openFirstResult(tester);

      final art = tester.getRect(find.byKey(artKey));
      expect(art.top, lessThan(80),
          reason: 'the picture starts just below the nav bar, not a third of the way '
              'down the screen');

      // The editions follow the picture rather than being pinned to the bottom edge,
      // so the gap between them is the divider and nothing else. Found by caption,
      // because the name on each row is now the card's own and repeats down them.
      final first = tester.getRect(caption('Rhino  \u00b7  #101'));
      expect(first.top - art.bottom, lessThan(60),
          reason: 'the editions sit directly beneath the art');

      // Whatever space is left over is below both, which is the point of the change.
      final last = tester.getRect(caption('Winter Soldier Nemesis  \u00b7  #31'));
      expect(last.bottom, lessThan(800),
          reason: 'the whole column is packed towards the top');

      // Everything above is measured before any image has actually decoded -- the test
      // clock is fake -- which is the point. The art claims its box from the card's
      // `landscape` flag, so the picture is 366x531 on the first frame and the
      // editions are already in their final place. Sized from the image instead, this
      // would be 0x0 here and the editions would sit under the AppBar until the scan
      // arrived and shoved them down the screen.
      expect(art.width, moreOrLessEquals(366, epsilon: 1));
      expect(art.height, moreOrLessEquals(531, epsilon: 1));
    });

    // Apocalypse's eight editions are 389pt of rows, which would leave a phone almost
    // no room for the card itself, so the picker caps at four and scrolls. Opened by
    // its exact name, because a search for it also finds The Horsemen of Apocalypse,
    // which sorts first and is a main scheme printed once.
    testWidgets('a large group does not crowd out the art', (tester) async {
      await boot(tester);
      await search(tester, 'apocalypse');
      await tester.tap(find.text('Apocalypse').first);
      await tester.pumpAndSettle();

      final art = tester.getRect(find.byKey(artKey));
      expect(art.height, greaterThan(300),
          reason: 'the picture keeps most of the screen');
      expect(find.byType(CardThumbnail), findsNWidgets(4),
          reason: 'four rows are drawn; the other four are scrolled to');
    });

    testWidgets('a card with no other edition is top-aligned too', (tester) async {
      await boot(tester);
      await search(tester, 'backflip');
      await openFirstResult(tester);

      // No picker to make room for, but the picture still starts where every other
      // card's does: a scan should not jump down the screen for want of a picker.
      expect(tester.getRect(find.byKey(artKey)).top, lessThan(80));
      // A CupertinoNavigationBar is translucent, so the art draws behind it and the
      // SafeArea is what keeps it clear. Below the bar, not under it.
      expect(tester.getRect(find.byKey(artKey)).top, greaterThan(44));
    });

    // The space reserved comes from the card's `landscape` flag, so a sideways card
    // must claim a sideways box -- and claim it before decoding, like a portrait one.
    testWidgets('a landscape card reserves a landscape box', (tester) async {
      await boot(tester);
      await search(tester, 'the break-in');
      await openFirstResult(tester);

      final art = tester.getRect(find.byKey(artKey));
      expect(art.width, greaterThan(art.height),
          reason: 'a sideways scheme reserves a wider box than it is tall');
      expect(art.top, lessThan(80));
    });
  });

  testWidgets('the picker on an unscanned card sits below its text',
      (tester) async {
    await boot(tester);
    // Coup de Grâce is printed in the Brawler and Commander role sets and neither 32176
    // nor 32181 was ever scanned, so the card is all text and the picker has to follow
    // it. Web-Shooter used to stand here, until 27039 was found to have a scan of its
    // own that had been overwriting the Core Set printing's.
    //
    // The first row, not the last: Civil War's 56016 shares the name, has art and is an
    // event where these are upgrades, so it is not one of their editions, and it sorts
    // after them both.
    await search(tester, 'coup de');
    await tester.tap(find.text('Coup de Grâce').first);
    await tester.pumpAndSettle();

    expect(find.text('2 editions'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('2 editions')).dy,
      greaterThan(tester.getTopLeft(find.text('Coup de Grâce').first).dy),
      reason: 'the text comes first, the editions after it',
    );
  });

  testWidgets('a one-sided card offers no flip', (tester) async {
    await boot(tester);
    await search(tester, 'backflip');
    await openFirstResult(tester);

    expect(find.text('Backflip'), findsWidgets);
    expect(button(flipIcon), findsNothing);
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
    await tester.tap(button(filterIcon));
    await tester.pumpAndSettle();

    // Five drill-down rows, all on one page: there is nothing to scroll to, which is
    // the point of the shape. Each says how many values it is not narrowing.
    for (final facet in ['Aspect', 'Type', 'Pack', 'Set', 'Trait']) {
      expect(find.text(facet), findsOneWidget, reason: facet);
    }
    expect(find.text('Any'), findsNWidgets(5), reason: 'nothing is filtered yet');
  });

  testWidgets('choosing an aspect filters the list', (tester) async {
    await boot(tester);
    await tester.tap(button(filterIcon));
    await tester.pumpAndSettle();

    // Aspect is a page of its own now, so the choice is: open it, tick Leadership,
    // back out to the sheet, and close the sheet.
    await tester.tap(find.text('Aspect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leadership'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filter'));
    await tester.pumpAndSettle();

    // The sheet reports the choice back before it is applied.
    expect(find.text('Leadership'), findsOneWidget, reason: 'the row says what is set');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('3632 cards'), findsNothing);
    expect(find.byType(CardRow), findsAny);
    // The count of active facets rides beside the filter icon, where Material had a
    // badge over it.
    expect(find.text('1'), findsOneWidget);
  });

  group('the tabs', () {
    Future<void> openTab(WidgetTester tester, String label) async {
      await tester.tap(find.descendant(
        of: find.byType(CupertinoTabBar),
        matching: find.text(label),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a tab keeps its search while another is on top', (tester) async {
      await boot(tester);
      await search(tester, 'wakanda forever');
      expect(find.text('3632 cards'), findsNothing);

      await openTab(tester, 'Settings');
      // The theme is one navigation row saying what it is set to, the way iOS spells a
      // choice, rather than three radios on this page.
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System'), findsOneWidget, reason: 'the row says the setting');

      // The tab is kept alive rather than rebuilt: the query is still typed in.
      await openTab(tester, 'Cards');
      expect(find.text('3632 cards'), findsNothing);
      expect(find.text('wakanda forever'), findsOneWidget);
    });

    testWidgets('the theme row opens a page of the options', (tester) async {
      await boot(tester);
      await openTab(tester, 'Settings');

      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();

      // All three on the pushed page, with a tick against the one in force.
      for (final label in ['System', 'Light', 'Dark']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.byIcon(CupertinoIcons.checkmark), findsOneWidget,
          reason: 'exactly one option is ticked');
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

      // The detail screen covers the tab bar rather than sitting above it. This is why
      // the tabs are not each a CupertinoTabView: a per-tab Navigator would leave the
      // tab bar visible under the card.
      expect(find.byType(CupertinoTabBar), findsNothing);
    });

    testWidgets('a deck shows its set-aside cards under their own heading',
        (tester) async {
      await boot(tester);
      await openTab(tester, 'Decks');

      // Eviction Notice is Spider-Man's obligation. It goes into the encounter deck
      // rather than the player's, so it is not one of the fifteen -- and it was missing
      // from the screen entirely, as every hero's obligation was.
      await tester.tap(find.text('Spider-Man').first);
      await tester.pumpAndSettle();

      // A deck is 15 rows before the heading, so it starts below the fold. The deck's
      // own list is the last Scrollable: the decks list it was pushed over is still
      // mounted behind it.
      await tester.scrollUntilVisible(
        find.text('Eviction Notice'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('SET ASIDE'), findsOneWidget);
      expect(find.text('Eviction Notice'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Eviction Notice')).dy,
        greaterThan(tester.getTopLeft(find.text('SET ASIDE')).dy),
        reason: 'the heading comes before the cards it names',
      );
      // The count is the deck, which these are not part of.
      expect(find.text('15 cards'), findsOneWidget);
    });

    testWidgets('choosing Light repaints the app', (tester) async {
      await boot(tester);
      // The brightness as the widgets below CupertinoApp actually see it, rather than
      // the theme the app was handed -- which is what proves the choice reached them.
      // Read from the theme page itself: it is pushed on the root navigator, so it
      // covers the tab bar and there is no tab bar on screen to read from.
      Brightness brightness() =>
          CupertinoTheme.brightnessOf(tester.element(find.text('Dark')));

      await openTab(tester, 'Settings');
      await tester.tap(find.text('Theme'));
      await tester.pumpAndSettle();

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
