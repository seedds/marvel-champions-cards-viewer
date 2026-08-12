import 'package:flutter/material.dart';

import '../data/deck.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_detail_screen.dart';
import 'card_row.dart';

/// The pre-built deck that ships in each hero pack, ready to play out of the box.
class DecksScreen extends StatelessWidget {
  const DecksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Decks')),
      body: ListView.builder(
        itemCount: repository.decks.length,
        itemBuilder: (context, index) {
          final deck = repository.decks[index];
          return _DeckRow(
            deck: deck,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => _DeckScreen(deck: deck)),
            ),
          );
        },
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

    return ListTile(
      leading: CardThumbnail(card: hero, width: 34),
      title: Text(deck.name),
      subtitle: Text('${deck.cardCount} cards'),
      trailing: const Icon(Icons.chevron_right),
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

    return Scaffold(
      appBar: AppBar(
        title: Text(deck.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${deck.cardCount} cards',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ),
      ),
      body: ListView.builder(
        itemExtent: CardRow.extent,
        itemCount: slots.length,
        itemBuilder: (context, index) {
          return _SlotRow(
            card: cards[index],
            quantity: slots[index].quantity,
            // Swiping on the detail screen walks this deck, in the order shown here.
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => CardDetailScreen(cards: cards, index: index),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A card in a deck: the ordinary row, with the number of copies alongside.
class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.card,
    required this.quantity,
    required this.onTap,
  });

  final MarvelCard card;
  final int quantity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: CardRow(card: card, onTap: onTap)),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            '\u00d7$quantity',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}
