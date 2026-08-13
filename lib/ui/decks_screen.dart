import 'package:flutter/cupertino.dart';

import '../data/deck.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_detail_screen.dart';
import 'card_row.dart';
import 'theme.dart';

/// The pre-built deck that ships in each hero pack, ready to play out of the box.
class DecksScreen extends StatelessWidget {
  const DecksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: const CupertinoNavigationBar(middle: Text('Decks')),
      // The Builder puts the context below the scaffold, which is where the nav bar's
      // inset is reported. See listInsets.
      child: Builder(
        builder: (context) => ListView.builder(
          itemCount: repository.decks.length,
          padding: listInsets(context, extra: 8),
          itemBuilder: (context, index) {
            final deck = repository.decks[index];
            return _DeckRow(
              deck: deck,
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute(builder: (_) => _DeckScreen(deck: deck)),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DeckRow extends StatelessWidget {
  const _DeckRow({required this.deck, required this.onTap});

  final Deck deck;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    // Never null: the build script fails rather than write a deck whose hero it could
    // not name, so a missing one here would be a broken asset.
    final hero = repository.byCode(deck.hero)!;

    return CupertinoListTile.notched(
      leading: CardThumbnail(card: hero, width: 30),
      title: Text(deck.name),
      subtitle: _AspectLine(deck: deck),
      trailing: const CupertinoListTileChevron(),
      onTap: onTap,
    );
  }
}

/// What a deck is built from and how big it is: "Justice — 40 cards".
///
/// The aspect is the first thing a person choosing between decks wants, and it is
/// coloured because that is how the game itself distinguishes them. Six decks draw on
/// more than one aspect, so this joins them rather than assuming a single one.
class _AspectLine extends StatelessWidget {
  const _AspectLine({required this.deck});

  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final brightness = CupertinoTheme.brightnessOf(context);
    final style = captionStyle(context);

    return Text.rich(
      TextSpan(
        children: [
          for (final (index, aspect) in deck.aspects.indexed) ...[
            if (index > 0) const TextSpan(text: ' \u00b7 '),
            TextSpan(
              text: factionLabel(aspect),
              style: style.copyWith(
                color: aspectTextColour(aspect, brightness),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          TextSpan(text: '  \u2014  ${deck.cardCount} cards', style: style),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// One deck's cards, in release order, with how many copies of each it holds.
///
/// Two groups, because a hero pack gives you more than a deck. The obligation goes into
/// the encounter deck, a permanent like Wolverine's Claws starts in play, and Archangel
/// is a form Angel turns into -- none of them is shuffled in with the forty, so
/// showing them in one list would say they are.
class _DeckScreen extends StatelessWidget {
  const _DeckScreen({required this.deck});

  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    final slots = repository.cardsOf(deck);
    final setAside = repository.setAsideCardsOf(deck);
    // Swiping the detail screen walks both groups, in the order they are shown.
    final cards = [
      for (final slot in slots) slot.card,
      for (final slot in setAside) slot.card,
    ];

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(deck.name),
        previousPageTitle: 'Decks',
      ),
      // Below the scaffold, which is where the nav bar's inset is. See listInsets.
      child: Builder(
        builder: (context) => Column(
          children: [
            // A static Cupertino nav bar has no room under its title the way an AppBar's
            // `bottom` did, so the count is a strip beneath the bar -- the same shape the
            // browse list's own count has.
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 6,
                16,
                6,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _AspectLine(deck: deck),
              ),
            ),
            Expanded(
              // No itemExtent here, unlike the browse list: these are two dozen rows
              // with headings between them, not 3,632 uniform ones, so there is no
              // offset to jump to and nothing to gain by restating the arithmetic.
              child: ListView(
                // The count above holds the nav bar's inset for this one.
                padding: listInsets(context, top: false),
                children: [
                  for (final (index, slot) in slots.indexed)
                    _SlotRow(
                      card: slot.card,
                      quantity: slot.quantity,
                      onTap: () => _open(context, cards, index),
                    ),
                  _GroupHeading(label: 'Set aside'),
                  for (final (index, slot) in setAside.indexed)
                    _SlotRow(
                      card: slot.card,
                      quantity: slot.quantity,
                      onTap: () => _open(context, cards, slots.length + index),
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

/// The detail screen is pushed on the root navigator so it covers the tab bar, and is
/// given both groups so a swipe carries on past the end of the deck.
void _open(BuildContext context, List<MarvelCard> cards, int index) {
  Navigator.of(context, rootNavigator: true).push(
    CupertinoPageRoute(builder: (_) => CardDetailScreen(cards: cards, index: index)),
  );
}

/// The label above a group of rows, in the shape iOS puts above a list section.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: captionStyle(context).copyWith(fontSize: 12, letterSpacing: 0.5),
      ),
    );
  }
}

/// A card in a deck: the ordinary row, with the number of copies alongside.
class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.card, required this.quantity, required this.onTap});

  final MarvelCard card;
  final int quantity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The count sits on the row's own background, so the two read as one row rather
    // than as a row with something stuck to its side.
    return ColoredBox(
      color: rowBackground.resolveFrom(context),
      child: Row(
        children: [
          Expanded(
            child: CardRow(card: card, onTap: onTap),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('\u00d7$quantity', style: captionStyle(context)),
          ),
        ],
      ),
    );
  }
}
