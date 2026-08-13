import 'dart:math';

import 'package:flutter/cupertino.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_row.dart';
import 'card_text.dart';
import 'theme.dart';

/// How many edition rows the picker shows before it scrolls. Four is what leaves a
/// portrait card most of a phone's height; 23 of the 206 groups are larger.
const _maxPickerRows = 4;

/// One card, front and back -- and the cards either side of it.
///
/// [cards] is the list the card was opened from, so a swipe walks exactly the rows
/// that were on screen behind it: the search results, the filtered set, or a deck.
class CardDetailScreen extends StatefulWidget {
  const CardDetailScreen({required this.cards, required this.index, super.key});

  final List<MarvelCard> cards;
  final int index;

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  late final PageController _controller = PageController(initialPage: widget.index);
  late int _index = widget.index;
  bool _showingBack = false;

  /// The edition being shown, when it is not the card the page was opened at. Held
  /// here rather than in the page because the flip button is in the nav bar, and
  /// whether a card has a back is a fact about the *chosen* edition: Ant-Man's 12001a
  /// has one and his giant form 12001c does not, and seven groups are like that.
  MarvelCard? _selected;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    final front = _selected ?? widget.cards[_index];

    // A card's back comes in two shapes: a linked record with its own name and text,
    // or -- for 26002 Intangible alone -- a second face carried on this same record.
    final linkedBack = repository.backOf(front);
    final hasBack = linkedBack != null || front.doubleSided;
    final showingBack = _showingBack && hasBack;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(showingBack ? _backTitle(front, linkedBack) : front.name),
        trailing: hasBack
            ? CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _showingBack = !_showingBack),
                // iOS has no tooltip, so the label a screen reader reads is also what
                // a test finds this button by.
                child: Semantics(
                  label: 'Flip',
                  button: true,
                  child: const Icon(flipIcon),
                ),
              )
            : null,
      ),
      // Only the current page is built at rest, and two during a swipe, because
      // `allowImplicitScrolling` is left off. Two full-size decodes is what the 24 MB
      // image cache is sized for; a cached neighbourhood of them would not be.
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.cards.length,
        // A card turned over and swiped past goes back to its front, and to the edition
        // it was opened at, rather than being remembered for the rest of the session.
        onPageChanged: (index) => setState(() {
          _index = index;
          _showingBack = false;
          _selected = null;
        }),
        itemBuilder: (context, index) => _CardPage(
          // Keyed by code so that swiping to another card builds a fresh page, rather
          // than reusing this one's state.
          key: ValueKey(widget.cards[index].code),
          card: widget.cards[index],
          // Only the page being looked at follows the chosen edition. The rest are off
          // screen or sliding past, and show the card the list put there.
          selected: index == _index ? front : widget.cards[index],
          // Every page but the current one is face-up: they are off screen or sliding
          // past, and the flip belongs to the card being looked at.
          showingBack: index == _index && showingBack,
          onFlip: index == _index && hasBack
              ? () => setState(() => _showingBack = !_showingBack)
              : null,
          // Choosing an edition shows its front, rather than the side the previous one
          // happened to be turned to -- and it may not have a back at all.
          onSelected: (edition) => setState(() {
            _selected = edition;
            _showingBack = false;
          }),
        ),
      ),
    );
  }
}

/// One card of the swipeable run -- and, when others share its name and type, the
/// edition currently on show.
class _CardPage extends StatelessWidget {
  const _CardPage({
    required this.card,
    required this.selected,
    required this.showingBack,
    required this.onFlip,
    required this.onSelected,
    super.key,
  });

  /// The card this page is for, which is what decides the group of editions.
  final MarvelCard card;

  /// The edition on show, [card] itself unless one was chosen.
  final MarvelCard selected;

  final bool showingBack;
  final VoidCallback? onFlip;
  final ValueChanged<MarvelCard> onSelected;

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    final editions = repository.editionsOf(card);

    final front = selected;
    final linkedBack = repository.backOf(front);
    final face = showingBack ? (linkedBack ?? front) : front;
    final image = showingBack ? repository.backImageOf(front) : front.frontImage;

    final picker = editions.length < 2
        ? null
        : _Editions(
            editions: editions,
            selected: selected,
            onSelected: onSelected,
          );

    // The scan is the card: everything the heading, stats and text below would say is
    // already printed on it, and better. The written-out version is the fallback for
    // a side with no scan, which is 53 of 3,632 fronts and 5 of 324 backs. The choice
    // stays per side rather than per card: the five remaining two-sided gaps happen to
    // have neither side scanned, but that is the state of one TTS save and not a rule,
    // and a half-scanned card should show art one way and text the other.
    //
    // An unscanned side shows that text *where the picture would be*, with no
    // placeholder above it. A box saying "not scanned" is a card's height of nothing,
    // and pushes the only information there is below the fold.
    if (image == null) {
      return ListView(
        // The nav bar is translucent and this text starts at the top of the screen, so
        // the bar's own inset is what keeps the card's name out from under it.
        padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 12, 16, 40),
        children: [
          _Heading(card: face, front: front, showingBack: showingBack),
          const SizedBox(height: 12),
          _Stats(card: face),
          _Body(card: face, front: front, showingBack: showingBack),
          const SizedBox(height: 16),
          _Provenance(card: front),
          // At the bottom rather than up where the art would be: the text is what the
          // space above was given to.
          if (picker != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: _Separator(),
            ),
            _EditionsHeading(count: editions.length),
            const SizedBox(height: 4),
            picker,
          ],
        ],
      );
    }

    final art = _Art(
      key: artKey,
      image: image,
      // The side on show decides the shape, not the card: 10 cards are portrait one
      // way and landscape the other -- Criminal Enterprise, both Choosing Sides. `face`
      // is already the record for the side being drawn.
      landscape: face.landscape,
      onTap: onFlip,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          children: [
            // Flexible rather than Expanded, so the picture asks for its own height and
            // no more: a portrait scan on a phone is limited by the width, and under
            // Expanded the leftover height would be split above and below it. Here the
            // column packs from the top instead, the editions sit directly beneath the
            // art rather than against the bottom edge, and the slack falls below both.
            // Still flexible, so a card too tall for the space shrinks to fit rather
            // than pushing the picker off the screen.
            Flexible(child: art),
            // The picker asks only for its own rows, so a card with one other edition
            // gives up two rows' worth of picture rather than a third of the screen.
            // Past [_maxPickerRows] it scrolls instead: Apocalypse's eight would be
            // 389pt, which leaves a phone almost no room for the card itself.
            if (picker != null) ...[
              const SizedBox(height: 12),
              const _Separator(),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      min(editions.length, _maxPickerRows) * CardRow.extent,
                ),
                child: picker,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _backTitle(MarvelCard front, MarvelCard? linkedBack) =>
    linkedBack?.name ?? front.backName ?? front.name;

/// The flip button's icon, named so that a test can find it.
const flipIcon = CupertinoIcons.arrow_2_squarepath;

/// A hairline, where Material had a Divider. Zero width means one physical pixel,
/// which is what iOS draws and what `CupertinoListSection` uses between its rows.
class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.0,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.0,
          ),
        ),
      ),
    );
  }
}

/// The big picture, as opposed to the thumbnail the printing picker shows for the same
/// card. Both draw the same asset, so a test looking for the art by its image cannot
/// tell them apart; this can.
const artKey = ValueKey('card art');

/// The card's picture. A side with no scan does not reach here: it shows its text in
/// this space instead of a placeholder.
///
/// [onTap] flips a two-sided card and is null on a one-sided one. The gesture is on
/// the picture alone rather than the whole screen, so that a tap meant for the printing
/// picker below does not turn the card over.
class _Art extends StatelessWidget {
  const _Art({required this.image, required this.landscape, this.onTap, super.key});

  final String image;

  /// The orientation of the side on show, which decides how much room the picture
  /// claims before it has decoded.
  final bool landscape;

  final VoidCallback? onTap;

  /// The printed card, and so every scan of one.
  static const _portraitRatio = 710 / 1030;

  @override
  Widget build(BuildContext context) {
    // The box is claimed from the card's own `landscape` flag rather than measured
    // from the picture, because the picture has no size until it has decoded. Sizing
    // to the image would collapse this to nothing on the first frame and shove
    // whatever is below it up the screen, then drop it as the scan arrives.
    //
    // The fit stays `contain`, so the flag decides only how much space to reserve and
    // never crops: 42001c Archangel is genuinely 1430x1030 rather than rotated, and
    // letterboxes by a hair inside the box its flag asks for.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AspectRatio(
        aspectRatio: landscape ? 1 / _portraitRatio : _portraitRatio,
        child: LayoutBuilder(
          builder: (context, constraints) => ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/CardImages/$image',
              fit: BoxFit.contain,
              // Decoded no wider than it can be drawn, rather than at the scan's
              // native 710px, which matters when several detail screens are on the
              // stack. ResizeImage does not upscale, so this clamps to the scan.
              cacheWidth: (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                  .round(),
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

/// The label above the picker on an unscanned card, where it has no art beside it to
/// explain what the list is.
class _EditionsHeading extends StatelessWidget {
  const _EditionsHeading({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Text('$count editions', style: captionStyle(context));
  }
}

/// Every card sharing one name and type, to pick between.
///
/// Shaped like a [CardRow] -- name on top, a caption under it -- because that is what a
/// row of this app means, and a list whose first line is a set name reads as a list of
/// sets. The name repeats down the rows, which is the point: it says what is being
/// chosen between.
///
/// The caption is [_editionCaption], which has to separate every row of a group. Where
/// it cannot, `tools/build_assets.py` says so on the card and the code stands in.
class _Editions extends StatelessWidget {
  const _Editions({
    required this.editions,
    required this.selected,
    required this.onSelected,
  });

  final List<MarvelCard> editions;
  final MarvelCard selected;
  final ValueChanged<MarvelCard> onSelected;

  @override
  Widget build(BuildContext context) {
    final tint = CupertinoTheme.of(context).primaryColor;

    return ListView.builder(
      // Sized by its parent, and short: 206 groups, the largest eight rows, and past
      // four the parent's cap makes this scroll.
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: editions.length,
      itemExtent: CardRow.extent,
      itemBuilder: (context, index) {
        final edition = editions[index];
        final isSelected = edition.code == selected.code;

        return GestureDetector(
          onTap: () => onSelected(edition),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            color: isSelected ? tint.withValues(alpha: 0.10) : null,
            child: Row(
              children: [
                CardThumbnail(card: edition, width: CardRow.thumbnailWidth),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        edition.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: rowTitleStyle(context).copyWith(
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      // CardText rather than Text, so a resource pip is the same
                      // lozenge here as it is in the card's own text below.
                      CardText(
                        _editionCaption(edition),
                        style: rowCaptionStyle(context),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                if (isSelected) Icon(CupertinoIcons.checkmark, size: 18, color: tint),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What one edition's row says beneath the name, which has to be different from every
/// other row of its group. Mirrors `_edition_caption` in `tools/build_assets.py`, which
/// is what checks that it is.
///
/// Where the card was printed separates most groups. The rest need what is printed on
/// the card: the stage, for a villain's three; the resource pips, for a run like
/// Wakanda Forever! whose five agree on set and number and differ by the pip alone.
///
/// Four groups are separated by none of it -- Android Efficiency's three differ by a pip
/// inside their boost text, Ant-Man and Wasp by the attack of their giant form, and two
/// Apocalypse stages by scheme. The build script marks those and the code stands in: it
/// is printed on the card, and it is unique by construction.
String _editionCaption(MarvelCard card) {
  return [
    card.setName ?? card.packName,
    '#${card.position}',
    if (card.stage != null) 'Stage ${card.stage}',
    // Rendered by CardText as the same lozenge the card's own text uses.
    if (card.resources.isNotEmpty)
      card.resources.map((resource) => '[$resource]').join(),
    if (card.editionCaptionCode) card.code,
  ].join('  \u00b7  ');
}

class _Heading extends StatelessWidget {
  const _Heading({required this.card, required this.front, required this.showingBack});

  final MarvelCard card;
  final MarvelCard front;
  final bool showingBack;

  @override
  Widget build(BuildContext context) {
    final textTheme = CupertinoTheme.of(context).textTheme;
    final traits = CardFilter.splitTraits(card.traits);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (card.isUnique)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Text('\u2605', style: TextStyle(fontSize: 18)),
              ),
            Expanded(
              child: Text(
                showingBack ? _backTitle(front, null) : card.name,
                style: textTheme.navLargeTitleTextStyle.copyWith(fontSize: 24),
              ),
            ),
          ],
        ),
        if (card.subname != null)
          Text(
            card.subname!,
            style: textTheme.textStyle.copyWith(fontWeight: FontWeight.w600),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Tag(label: typeLabel(card.typeCode), colour: aspectColour(card.factionCode)),
            if (card.stage != null) _Tag(label: 'Stage ${card.stage}'),
            if (card.permanent) const _Tag(label: 'Permanent'),
            if (card.hidden) const _Tag(label: 'Hidden'),
          ],
        ),
        if (traits.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            traits.join(' \u00b7 '),
            style: captionStyle(context).copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.colour});

  final String label;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    // An aspect tag keeps the game's colour, which is dark enough for white type in
    // either theme. An untinted tag is a system fill, so its label has to be a label
    // colour or it disappears in light mode.
    final background = colour ?? CupertinoColors.tertiarySystemFill.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour == null ? background : background.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: rowCaptionStyle(context).copyWith(
          color: colour == null
              ? CupertinoColors.secondaryLabel.resolveFrom(context)
              : CupertinoColors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The numbers printed on the card, in the order they are printed.
class _Stats extends StatelessWidget {
  const _Stats({required this.card});

  final MarvelCard card;

  @override
  Widget build(BuildContext context) {
    final stats = <_Stat>[
      _Stat('Cost', card.cost, 'cost'),
      _Stat('THW', card.thwart, 'thwart'),
      _Stat('ATK', card.attack, 'attack'),
      _Stat('DEF', card.defense, 'defense'),
      _Stat('REC', card.recover, 'recover'),
      _Stat('SCH', card.scheme, 'scheme'),
      _Stat('Boost', card.boost, 'boost'),
      _Stat('Health', card.health, 'health'),
      _Stat('Threat', card.baseThreat ?? card.threat, 'base_threat'),
      _Stat('Hand', card.handSize, 'hand_size'),
    ];

    final shown = [
      for (final stat in stats)
        if (stat.value != null || card.statPrintedBlank.contains(stat.field)) stat,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final stat in shown)
            _StatChip(
              label: stat.label,
              // A stat printed with no number means the card cannot do that at all --
              // Hulk the ally cannot thwart. A dash says so; a 0 would be a lie.
              value: stat.value?.toString() ?? '\u2013',
              starred: card.starred.contains(stat.field),
            ),
        ],
      ),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.field);

  final String label;
  final int? value;
  final String field;
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value, required this.starred});

  final String label;
  final String value;
  final bool starred;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: rowCaptionStyle(context).copyWith(letterSpacing: 0.6),
          ),
          const SizedBox(width: 6),
          Text(
            starred ? '$value\u2605' : value,
            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.card, required this.front, required this.showingBack});

  final MarvelCard card;
  final MarvelCard front;
  final bool showingBack;

  @override
  Widget build(BuildContext context) {
    // The one self-contained two-sided card keeps its back's text on the front record.
    final text = showingBack && front.doubleSided ? front.backText : card.text;
    final bodyStyle = CupertinoTheme.of(context).textTheme.textStyle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text != null && text.isNotEmpty) ...[
          const SizedBox(height: 12),
          CardText(text, style: bodyStyle),
        ],
        if (card.flavor != null && card.flavor!.isNotEmpty) ...[
          const SizedBox(height: 12),
          CardText(
            card.flavor!,
            style: captionStyle(context).copyWith(fontStyle: FontStyle.italic),
          ),
        ],
        if (card.errata != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Errata',
                  style: captionStyle(context).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                CardText(card.errata!, style: captionStyle(context)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Provenance extends StatelessWidget {
  const _Provenance({required this.card});

  final MarvelCard card;

  @override
  Widget build(BuildContext context) {
    final style = captionStyle(context);
    final lines = <String>[
      if (card.setName != null) card.setName!,
      card.packName,
      if (card.illustrator != null) 'Art by ${card.illustrator}',
      'Card ${card.code} \u00b7 ${card.quantity} in the pack',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: _Separator()),
        for (final line in lines) Text(line, style: style),
      ],
    );
  }
}
