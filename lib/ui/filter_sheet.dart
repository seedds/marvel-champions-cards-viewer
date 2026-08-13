import 'package:flutter/cupertino.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import 'theme.dart';

/// Choose facets. Returns the new filter, or null if the sheet was dismissed.
Future<CardFilter?> showFilterSheet(
  BuildContext context, {
  required List<MarvelCard> cards,
  required CardFilter current,
}) {
  return showCupertinoSheet<CardFilter>(
    context: context,
    // The sheet holds a Navigator of its own, so a facet's list of values pushes
    // *inside* the sheet rather than over the whole app.
    useNestedNavigation: true,
    scrollableBuilder: (context, controller) =>
        _FilterSheet(cards: cards, current: current),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.cards, required this.current});

  final List<MarvelCard> cards;
  final CardFilter current;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late CardFilter _filter = widget.current;
  late final _Facets _facets = _Facets.of(widget.cards);

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Filter'),
        automaticallyImplyLeading: false,
        leading: _filter.isEmpty
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
                onPressed: () => setState(() => _filter = const CardFilter()),
                child: const Text('Clear'),
              ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          alignment: Alignment.centerRight,
          // Popped on the root navigator: the sheet's own nested one would only close
          // this page inside the sheet and leave the sheet itself standing.
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(_filter),
          child: const Text('Done'),
        ),
      ),
      // Five rows, so nothing here scrolls -- which is why there is no controller to
      // hand to a list. Each facet opens a searchable list of its own values, the way
      // iOS spells a choice from more than a handful.
      child: ListView(
        children: [
          CupertinoListSection.insetGrouped(
            children: [
              _FacetRow(
                title: 'Aspect',
                values: _facets.factions,
                selected: _filter.factions,
                labelFor: factionLabel,
                colourFor: aspectColour,
                onChanged: (next) =>
                    setState(() => _filter = _filter.copyWith(factions: next)),
              ),
              _FacetRow(
                title: 'Type',
                values: _facets.types,
                selected: _filter.types,
                labelFor: typeLabel,
                onChanged: (next) =>
                    setState(() => _filter = _filter.copyWith(types: next)),
              ),
              _FacetRow(
                title: 'Pack',
                values: _facets.packs,
                selected: _filter.packs,
                onChanged: (next) =>
                    setState(() => _filter = _filter.copyWith(packs: next)),
              ),
              _FacetRow(
                title: 'Set',
                values: _facets.sets,
                selected: _filter.sets,
                onChanged: (next) =>
                    setState(() => _filter = _filter.copyWith(sets: next)),
              ),
              _FacetRow(
                title: 'Trait',
                values: _facets.traits,
                selected: _filter.traits,
                onChanged: (next) =>
                    setState(() => _filter = _filter.copyWith(traits: next)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Every value a facet takes, in the order it should be offered.
class _Facets {
  _Facets({
    required this.packs,
    required this.sets,
    required this.types,
    required this.factions,
    required this.traits,
  });

  final List<String> packs;
  final List<String> sets;
  final List<String> types;
  final List<String> factions;
  final List<String> traits;

  factory _Facets.of(List<MarvelCard> cards) {
    // Packs in release order, which is the order the sort key already encodes; the
    // rest alphabetically, since no other order means anything to a reader.
    final packOrder = <String, int>{};
    final sets = <String>{};
    final types = <String>{};
    final factions = <String>{};
    final traits = <String>{};

    for (final card in cards) {
      packOrder.putIfAbsent(card.packName, () => card.sortKey.first);
      if (card.setName != null) sets.add(card.setName!);
      types.add(card.typeCode);
      factions.add(card.factionCode);
      traits.addAll(CardFilter.splitTraits(card.traits));
    }

    final packs = packOrder.keys.toList()
      ..sort((a, b) => packOrder[a]!.compareTo(packOrder[b]!));

    return _Facets(
      packs: packs,
      sets: sets.toList()..sort(),
      types: types.toList()..sort((a, b) => typeLabel(a).compareTo(typeLabel(b))),
      factions: factions.toList()
        ..sort((a, b) => factionLabel(a).compareTo(factionLabel(b))),
      traits: traits.toList()..sort(),
    );
  }
}

/// One line per facet, opening a searchable list of its values.
class _FacetRow extends StatelessWidget {
  const _FacetRow({
    required this.title,
    required this.values,
    required this.selected,
    required this.onChanged,
    this.labelFor,
    this.colourFor,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  /// How a stored code reads. Null when the values are already the words themselves,
  /// which is every facet but Aspect and Type.
  final String Function(String)? labelFor;

  final Color Function(String)? colourFor;

  String _label(String value) => labelFor?.call(value) ?? value;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile.notched(
      title: Text(title),
      additionalInfo: Text(
        selected.isEmpty
            ? 'Any'
            : selected.length == 1
            ? _label(selected.first)
            : '${selected.length} chosen',
      ),
      trailing: const CupertinoListTileChevron(),
      onTap: () async {
        final next = await Navigator.of(context).push<Set<String>>(
          CupertinoPageRoute(
            builder: (_) => _ValuePicker(
              title: title,
              values: values,
              selected: selected,
              labelFor: _label,
              colourFor: colourFor,
            ),
          ),
        );
        if (next != null) onChanged(next);
      },
    );
  }
}

/// One facet's values, searchable, with a tick against each chosen one.
class _ValuePicker extends StatefulWidget {
  const _ValuePicker({
    required this.title,
    required this.values,
    required this.selected,
    required this.labelFor,
    this.colourFor,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final String Function(String) labelFor;
  final Color Function(String)? colourFor;

  @override
  State<_ValuePicker> createState() => _ValuePickerState();
}

class _ValuePickerState extends State<_ValuePicker> {
  late final Set<String> _selected = widget.selected.toSet();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final needle = _query.toLowerCase();
    final shown = needle.isEmpty
        ? widget.values
        : widget.values
              .where((v) => widget.labelFor(v).toLowerCase().contains(needle))
              .toList();
    final tint = CupertinoTheme.of(context).primaryColor;

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.title),
        automaticallyImplyLeading: false,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          alignment: Alignment.centerLeft,
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Filter'),
        ),
        trailing: _selected.isEmpty
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                alignment: Alignment.centerRight,
                onPressed: () => setState(_selected.clear),
                child: const Text('Clear'),
              ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: CupertinoSearchTextField(
              autocorrect: false,
              placeholder: 'Search ${widget.title.toLowerCase()}s',
              onChanged: (value) => setState(() => _query = value),
              onSuffixTap: () => setState(() => _query = ''),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final value = shown[index];
                final isOn = _selected.contains(value);
                final colour = widget.colourFor?.call(value);

                return CupertinoListTile.notched(
                  title: Text(widget.labelFor(value)),
                  leading: colour == null
                      ? null
                      : Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: colour,
                            shape: BoxShape.circle,
                          ),
                        ),
                  trailing: isOn
                      ? Icon(CupertinoIcons.checkmark, size: 20, color: tint)
                      : null,
                  onTap: () => setState(() {
                    if (isOn) {
                      _selected.remove(value);
                    } else {
                      _selected.add(value);
                    }
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
