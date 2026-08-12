import 'package:flutter/material.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_detail_screen.dart';
import 'card_row.dart';
import 'filter_sheet.dart';

/// The whole collection, in release order, filtered by a query and a set of facets.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _searchController = TextEditingController();
  CardFilter _filter = const CardFilter();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    final matches = _filter.apply(repository.search(_query));

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _SearchField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              filterCount: _filter.activeCount,
              onFilterPressed: () async {
                final chosen = await showFilterSheet(
                  context,
                  cards: repository.browsable,
                  current: _filter,
                );
                if (chosen != null) setState(() => _filter = chosen);
              },
            ),
            _ResultCount(count: matches.length),
            Expanded(
              child: matches.isEmpty
                  ? const _NoMatches()
                  : _CardList(cards: matches),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.filterCount,
    required this.onFilterPressed,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int filterCount;
  final VoidCallback onFilterPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'Search cards',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Badge(
            isLabelVisible: filterCount > 0,
            label: Text('$filterCount'),
            child: IconButton.filledTonal(
              onPressed: onFilterPressed,
              icon: const Icon(Icons.tune),
              tooltip: 'Filter',
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  const _ResultCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          count == 1 ? '1 card' : '$count cards',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

class _CardList extends StatelessWidget {
  const _CardList({required this.cards});

  final List<MarvelCard> cards;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // A fixed row height lets the viewport jump straight to an offset rather than
      // measuring its way there, which is what makes a 3,632-row list scroll smoothly.
      // The separator lives inside the row so the extent stays uniform.
      itemExtent: CardRow.extent,
      itemCount: cards.length,
      itemBuilder: (context, index) {
        return CardRow(
          card: cards[index],
          // The whole list is handed over, not just the card, so that a swipe on the
          // detail screen walks the same set of matches that is on screen here.
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CardDetailScreen(cards: cards, index: index),
            ),
          ),
        );
      },
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No cards match.',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
