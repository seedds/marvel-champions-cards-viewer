import 'package:flutter/cupertino.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_detail_screen.dart';
import 'card_row.dart';
import 'filter_sheet.dart';
import 'theme.dart';

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

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Cards'),
        // The count of active facets rides beside the icon rather than on a badge over
        // it: iOS has no badged bar button, and the number is the whole point.
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () async {
            final chosen = await showFilterSheet(
              context,
              cards: repository.browsable,
              current: _filter,
            );
            if (chosen != null) setState(() => _filter = chosen);
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_filter.activeCount > 0)
                Text(
                  '${_filter.activeCount}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CupertinoTheme.of(context).primaryColor,
                  ),
                ),
              const Padding(padding: EdgeInsets.only(left: 4), child: Icon(filterIcon)),
            ],
          ),
        ),
      ),
      child: Column(
        children: [
          _SearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
          ),
          _ResultCount(count: matches.length),
          Expanded(
            child: matches.isEmpty ? const _NoMatches() : _CardList(cards: matches),
          ),
        ],
      ),
    );
  }
}

/// The filter button's icon, named so that a test can find the button. iOS has no
/// tooltip, which was how the Material version was found.
const filterIcon = CupertinoIcons.line_horizontal_3_decrease;

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The nav bar is translucent and this sits directly under it, so the top inset
      // is the bar's own padding rather than a gap of this widget's choosing.
      padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 8, 16, 4),
      child: CupertinoSearchTextField(
        controller: controller,
        onChanged: onChanged,
        placeholder: 'Search cards',
        autocorrect: false,
        // The field brings its own clear button, which reports through onSuffixTap
        // rather than onChanged -- so the query has to be cleared by hand.
        onSuffixTap: () {
          controller.clear();
          onChanged('');
        },
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(count == 1 ? '1 card' : '$count cards', style: captionStyle(context)),
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
      // No top inset: the search field above already holds the nav bar's.
      padding: listInsets(context, top: false),
      itemBuilder: (context, index) {
        return CardRow(
          card: cards[index],
          // The whole list is handed over, not just the card, so that a swipe on the
          // detail screen walks the same set of matches that is on screen here.
          onTap: () => Navigator.of(context).push(
            CupertinoPageRoute(
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
    return Center(child: Text('No cards match.', style: captionStyle(context)));
  }
}
