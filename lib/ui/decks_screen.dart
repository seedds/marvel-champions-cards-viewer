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
      subtitle: Text('${deck.cardCount} cards'),
      trailing: const CupertinoListTileChevron(),
      onTap: onTap,
    );
  }
}

/// One deck's cards, in release order, with how many copies of each it holds.
class _DeckScreen extends StatelessWidget {
  const _DeckScreen({required this.deck});

  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    final slots = repository.cardsOf(deck);
    final cards = [for (final slot in slots) slot.card];

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
                child: Text('${deck.cardCount} cards', style: captionStyle(context)),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemExtent: CardRow.extent,
                itemCount: slots.length,
                // The count above holds the nav bar's inset for this one.
                padding: listInsets(context, top: false),
                itemBuilder: (context, index) {
                  return _SlotRow(
                    card: cards[index],
                    quantity: slots[index].quantity,
                    // Swiping on the detail screen walks this deck, in the order shown
                    // here.
                    onTap: () => Navigator.of(context, rootNavigator: true).push(
                      CupertinoPageRoute(
                        builder: (_) => CardDetailScreen(cards: cards, index: index),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
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
