import 'package:flutter/cupertino.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import '../main.dart';
import 'card_detail_screen.dart';
import 'card_row.dart';
import 'card_sort.dart';
import 'filter_sheet.dart';
import 'theme.dart';

/// The whole collection: searched by name, narrowed by a set of facets, and put in
/// whichever order the reader asked for.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _searchController = TextEditingController();
  CardFilter _filter = const CardFilter();
  CardSort _sort = CardSort.release;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = CardRepositoryScope.of(context);
    // Search, then narrow, then order: sorting last means the sort only ever handles
    // what survived, and release order -- the default -- sorts nothing at all.
    final matches = _sort.sorted(_filter.apply(repository.search(_query)));

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Cards'),
        // Sort on the left, filter on the right: the two do different jobs -- one
        // reorders every card, the other takes cards away -- and putting them at
        // opposite ends says so. This is the root of a tab, so nothing else wants the
        // leading slot; there is no back button for it to displace.
        //
        // Sorting is one choice from five, so it is an action sheet rather than a
        // page: a tap and a tap, against the filter's tap, page, tick, back, done.
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          alignment: Alignment.centerLeft,
          onPressed: () async {
            final chosen = await showSortSheet(context, current: _sort);
            if (chosen != null) setState(() => _sort = chosen);
          },
          // iOS has no tooltip, so the label is a semantic one. The icon is also how
          // the tests find the button.
          child: Semantics(label: 'Sort', child: const Icon(sortIcon)),
        ),
        // The count of active facets rides beside the icon rather than on a badge over
        // it: iOS has no badged bar button, and the number is the whole point.
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          alignment: Alignment.centerRight,
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
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Semantics(label: 'Filter', child: const Icon(filterIcon)),
              ),
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
          _ResultCount(count: matches.length, sort: _sort),
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

/// The sort button's icon, and how a test finds it. See [filterIcon].
const sortIcon = CupertinoIcons.arrow_up_arrow_down;

/// Choose an order. Returns the chosen one, or null if the sheet was dismissed.
///
/// An action sheet rather than a page of its own: five fixed options, one of which is
/// already in force, is exactly what iOS puts in one. The tick marks the current order
/// so the sheet answers "what is this sorted by?" as well as changing it.
Future<CardSort?> showSortSheet(BuildContext context, {required CardSort current}) {
  return showCupertinoModalPopup<CardSort>(
    context: context,
    builder: (context) => CupertinoActionSheet(
      title: const Text('Sort by'),
      actions: [
        for (final sort in CardSort.values)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(sort),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(sort.label),
                if (sort == current)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      CupertinoIcons.checkmark,
                      size: 20,
                      color: CupertinoTheme.of(context).primaryColor,
                    ),
                  ),
              ],
            ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
    ),
  );
}

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
  const _ResultCount({required this.count, required this.sort});

  final int count;
  final CardSort sort;

  @override
  Widget build(BuildContext context) {
    // The order is named only when it is not the default one. Release order is what a
    // person gets without asking, and a line that always ends "· by release order"
    // would be saying nothing on nearly every visit.
    final label = [
      count == 1 ? '1 card' : '$count cards',
      if (sort != CardSort.release) 'by ${sort.label.toLowerCase()}',
    ].join('  \u00b7  ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, style: captionStyle(context)),
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
