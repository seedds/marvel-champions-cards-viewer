import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marvel_champions_cards_viewer/ui/card_text.dart';

/// The rendered text of a CardText widget, with widget-span icons left out.
///
/// A resource badge is itself a Text inside a WidgetSpan, so the descendant Texts are
/// skipped and only the one CardText builds is read.
String _renderedText(WidgetTester tester) {
  final widget = tester.widget<Text>(
    find.descendant(
      of: find.byType(CardText),
      matching: find.byType(Text),
      matchRoot: true,
    ).first,
  );
  return widget.textSpan!.toPlainText(includeSemanticsLabels: false);
}

Future<void> _pump(WidgetTester tester, String markup) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: CardText(markup))),
  );
}

void main() {
  testWidgets('bold and italic tags do not survive as literal text', (tester) async {
    await _pump(
      tester,
      'Spider-Sense \u2014 <b>Interrupt</b>: draw 1 card. <i>(Once per round.)</i>',
    );
    final text = _renderedText(tester);
    expect(text, isNot(contains('<b>')));
    expect(text, isNot(contains('</i>')));
    expect(text, contains('Interrupt'));
    expect(text, contains('(Once per round.)'));
  });

  testWidgets('a resource icon becomes a badge rather than raw markup',
      (tester) async {
    await _pump(tester, 'Spend a [energy] resource.');
    expect(_renderedText(tester), isNot(contains('[energy]')));
    // The badge is a widget span, so it is not part of the plain text.
    expect(find.byType(Container), findsWidgets);
  });

  testWidgets('the star icon reads as a star', (tester) async {
    await _pump(tester, '[star] <b>Forced Interrupt</b>: something happens.');
    final text = _renderedText(tester);
    expect(text, isNot(contains('[star]')));
    expect(text, contains('\u2605'));
  });

  testWidgets('a known word icon is spelled out', (tester) async {
    await _pump(tester, 'Health is 10 [per_hero].');
    final text = _renderedText(tester);
    expect(text, contains('per hero'));
    expect(text, isNot(contains('[per_hero]')));
  });

  // 46 distinct tokens appear today and a new set will add more. An unknown one must
  // read as a word, not leak brackets onto the card.
  testWidgets('an unknown icon degrades to its name', (tester) async {
    await _pump(tester, 'Gains [some_new_keyword] until the end of the phase.');
    final text = _renderedText(tester);
    expect(text, contains('some new keyword'));
    expect(text, isNot(contains('[')));
  });

  testWidgets('newlines in card text are preserved', (tester) async {
    await _pump(tester, 'First line.\nSecond line.');
    expect(_renderedText(tester), contains('\n'));
  });

  testWidgets('plain text passes through untouched', (tester) async {
    await _pump(tester, 'Attach to Rhino.');
    expect(_renderedText(tester), 'Attach to Rhino.');
  });
}
