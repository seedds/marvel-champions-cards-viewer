import 'package:flutter/cupertino.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import 'theme.dart';

/// One card per row: its art in miniature, then what the card is and where it is from.
///
/// Two lines, because the row's job is to be scanned past. The name says which card
/// this is; the line under it says what the card does and which set it was printed in.
/// The cost, the stats and the text are on the detail screen, one tap away.
///
/// The thumbnail is [thumbnailWidth] logical pixels against a scan of 710, so it
/// decodes at a fraction of native size. A list that decoded these at full size would
/// fill any image cache it was given within a screenful.
///
/// Deliberately not a `CupertinoListTile`, which brings its own minimum height and
/// padding: a fixed 48.6pt extent is what lets a 3,632-row list jump to an offset, and
/// the 28pt thumbnail is what keeps a screenful of art inside the image cache. Both
/// would be lost to the tile's own arithmetic.
class CardRow extends StatefulWidget {
  const CardRow({required this.card, required this.onTap, super.key});

  final MarvelCard card;
  final VoidCallback onTap;

  static const thumbnailWidth = 28.0;

  /// The thumbnail at the printed card's ratio, plus the padding above and below it.
  /// The two lines of text are shorter than this, so the picture sets the height.
  static const extent = thumbnailWidth / (710 / 1030) + 8;

  @override
  State<CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<CardRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final traits = CardFilter.splitTraits(card.traits);
    final brightness = CupertinoTheme.brightnessOf(context);

    // iOS answers a touch by greying the row rather than with Material's spreading ink.
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: _pressed
              ? CupertinoColors.systemFill.resolveFrom(context)
              : rowBackground.resolveFrom(context),
          border: Border(
            bottom: BorderSide(
              color: CupertinoColors.separator.resolveFrom(context),
              width: 0.0,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CardThumbnail(card: card, width: CardRow.thumbnailWidth),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Separate Text widgets rather than one rich span, so that a test --
                  // and VoiceOver -- can find a card by its name alone.
                  Row(
                    children: [
                      if (card.isUnique)
                        const Padding(
                          padding: EdgeInsets.only(right: 3),
                          child: Text('\u2605', style: TextStyle(fontSize: 10)),
                        ),
                      Flexible(
                        child: Text(
                          card.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: rowTitleStyle(context),
                        ),
                      ),
                      // The subname rides on the name's line rather than taking one of
                      // its own: only 188 cards have one, and a line reserved for it
                      // would be blank on the other 3,444.
                      if (card.subname != null)
                        Flexible(
                          child: Text(
                            '  \u2014  ${card.subname}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: rowCaptionStyle(context),
                          ),
                        ),
                    ],
                  ),
                  // One line, two voices: what the card is, in its aspect's colour,
                  // then where it was printed, in the quiet caption colour. The
                  // provenance in the aspect colour at w600 would read as another
                  // trait. One Text.rich rather than a Row, so the two share the
                  // line's ellipsis: the traits give way before they collide.
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: [
                            typeLabel(card.typeCode),
                            if (traits.isNotEmpty) traits.join(' \u00b7 '),
                          ].join('  \u2014  '),
                          style: rowCaptionStyle(context).copyWith(
                            color: aspectTextColour(card.factionCode, brightness),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '  \u2014  ${rowProvenance(card)}',
                          style: rowCaptionStyle(context),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where a card was printed, as a row says it: the set, or the pack for the 750 cards
/// in no set, and the number printed on the card.
///
/// The same two facts, spelled the same way, that `_editionCaption` in
/// `card_detail_screen.dart` opens with -- a card's provenance should not read
/// differently depending on which screen is showing it. Which is why this reads
/// [MarvelCard.printedNumber] and not `position`: a card the box prints several
/// versions of is numbered with a letter, and `40A` here and `40` one tap later would
/// be the same card claiming two numbers.
String rowProvenance(MarvelCard card) =>
    '${card.setName ?? card.packName}  \u00b7  #${card.printedNumber}';

/// A card's art in miniature, decoded at the size it is drawn.
class CardThumbnail extends StatelessWidget {
  const CardThumbnail({required this.card, required this.width, super.key});

  final MarvelCard card;
  final double width;

  @override
  Widget build(BuildContext context) {
    // Every thumbnail is the same box whatever the card's orientation, so names and
    // types line up down the list. A landscape card is fitted inside it rather than
    // cropped, which keeps its own title legible.
    final height = width / (710 / 1030);
    final colour = aspectColour(card.factionCode);

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: card.frontImage == null
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: colour.withValues(alpha: 0.25),
                  border: Border.all(color: colour.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Center(child: Icon(CupertinoIcons.photo, size: 12)),
              )
            : Image.asset(
                'assets/CardImages/${card.frontImage}',
                fit: card.landscape ? BoxFit.contain : BoxFit.cover,
                // Decode at the size it is drawn, not the scan's 710px.
                cacheWidth:
                    (width * MediaQuery.devicePixelRatioOf(context)).round(),
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}
