import 'package:flutter/material.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import 'theme.dart';

/// One card per row: its art in miniature, then what the card is.
///
/// Two lines, because the row's job is to be scanned past. The name says which card
/// this is and the type line says what it does; the pack, the cost and the rest are on
/// the detail screen, one tap away.
///
/// The thumbnail is [thumbnailWidth] logical pixels against a scan of 710, so it
/// decodes at a fraction of native size. A list that decoded these at full size would
/// fill any image cache it was given within a screenful.
class CardRow extends StatelessWidget {
  const CardRow({required this.card, required this.onTap, super.key});

  final MarvelCard card;
  final VoidCallback onTap;

  static const thumbnailWidth = 28.0;

  /// The thumbnail at the printed card's ratio, plus the padding above and below it.
  /// The two lines of text are shorter than this, so the picture sets the height.
  static const extent = thumbnailWidth / (710 / 1030) + 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final traits = CardFilter.splitTraits(card.traits);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CardThumbnail(card: card, width: thumbnailWidth),
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
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
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
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    [
                      typeLabel(card.typeCode),
                      if (traits.isNotEmpty) traits.join(' \u00b7 '),
                    ].join('  \u2014  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: aspectTextColour(card.factionCode, theme.colorScheme),
                      fontWeight: FontWeight.w600,
                    ),
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
                child: const Center(
                  child: Icon(Icons.image_not_supported_outlined, size: 12),
                ),
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
