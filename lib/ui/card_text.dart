import 'package:flutter/cupertino.dart';

/// Card text as printed: `<b>`, `<i>` and `[icon]` markup turned into spans.
///
/// 1,511 cards carry icon markup, 46 distinct tokens of it. No icon artwork is
/// bundled, so a resource token becomes a small lozenge in the resource's colour and
/// everything else becomes its name in small caps. That is honest about what is
/// missing rather than printing `[per_hero]` at a reader.
class CardText extends StatelessWidget {
  const CardText(this.text, {super.key, this.style, this.maxLines});

  final String text;
  final TextStyle? style;

  /// Null -- a card's own text runs to as many lines as it needs. Set where this is a
  /// row's caption and a second line would push the row past its fixed extent.
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final base = style ?? CupertinoTheme.of(context).textTheme.textStyle;
    return Text.rich(
      TextSpan(children: _parse(text, base)),
      style: base,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Colours for the four resource icons, which are the ones that carry meaning at a
/// glance. Everything else is a word.
const _resourceColours = <String, Color>{
  'physical': Color(0xFF9C3B2E),
  'mental': Color(0xFF2F6DA8),
  'energy': Color(0xFF3E8E6E),
  'wild': Color(0xFF7A4E9E),
};

const _iconWords = <String, String>{
  'star': '\u2605',
  'per_hero': 'per hero',
  'per_group': 'per group',
  'boost': 'BOOST',
  'cost': 'COST',
  'attack': 'ATK',
  'thwart': 'THW',
  'defense': 'DEF',
  'crisis': 'CRISIS',
  'acceleration': 'ACCELERATION',
  'hazard': 'HAZARD',
  'amplify': 'AMPLIFY',
  'unique': '\u2605',
};

final _markup = RegExp(r'<(/?)(b|i|em)>|\[([a-z_]+)\]', caseSensitive: false);

List<InlineSpan> _parse(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  var bold = 0;
  var italic = 0;
  var index = 0;

  TextStyle current() => base.copyWith(
        fontWeight: bold > 0 ? FontWeight.bold : null,
        fontStyle: italic > 0 ? FontStyle.italic : null,
      );

  for (final match in _markup.allMatches(text)) {
    if (match.start > index) {
      spans.add(TextSpan(text: text.substring(index, match.start), style: current()));
    }
    index = match.end;

    final token = match.group(3);
    if (token != null) {
      spans.add(_iconSpan(token, current()));
      continue;
    }

    final closing = match.group(1) == '/';
    final tag = match.group(2)!.toLowerCase();
    if (tag == 'b') {
      bold += closing ? -1 : 1;
    } else {
      italic += closing ? -1 : 1;
    }
  }

  if (index < text.length) {
    spans.add(TextSpan(text: text.substring(index), style: current()));
  }
  return spans;
}

InlineSpan _iconSpan(String token, TextStyle style) {
  final colour = _resourceColours[token];
  if (colour != null) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            token[0].toUpperCase(),
            style: style.copyWith(
              fontSize: (style.fontSize ?? 14) * 0.8,
              fontWeight: FontWeight.bold,
              color: CupertinoColors.white,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }

  final word = _iconWords[token];
  if (word != null) {
    return TextSpan(text: word, style: style.copyWith(fontWeight: FontWeight.w600));
  }

  // An unknown token is a trait or keyword the set introduced; its name reads fine.
  return TextSpan(
    text: token.replaceAll('_', ' '),
    style: style.copyWith(fontWeight: FontWeight.w600),
  );
}
