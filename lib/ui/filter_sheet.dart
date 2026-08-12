import 'package:flutter/material.dart';

import '../data/card_filter.dart';
import '../data/marvel_card.dart';
import 'theme.dart';

/// Choose facets. Returns the new filter, or null if the sheet was dismissed.
Future<CardFilter?> showFilterSheet(
  BuildContext context, {
  required List<MarvelCard> cards,
  required CardFilter current,
}) {
  return showModalBottomSheet<CardFilter>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FilterSheet(cards: cards, current: current),
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
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('Filter', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  if (!_filter.isEmpty)
                    TextButton(
                      onPressed: () => setState(() => _filter = const CardFilter()),
                      child: const Text('Clear all'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_filter),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _ChipSection(
                    title: 'Aspect',
                    values: _facets.factions,
                    selected: _filter.factions,
                    labelFor: (code) => _factionLabel(code),
                    colourFor: aspectColour,
                    onChanged: (next) =>
                        setState(() => _filter = _filter.copyWith(factions: next)),
                  ),
                  _ChipSection(
                    title: 'Type',
                    values: _facets.types,
                    selected: _filter.types,
                    labelFor: typeLabel,
                    onChanged: (next) =>
                        setState(() => _filter = _filter.copyWith(types: next)),
                  ),
                  // 61 packs, 356 sets and 221 traits are too many for a wall of chips,
                  // so each gets a searchable list of its own.
                  _PickerRow(
                    title: 'Pack',
                    values: _facets.packs,
                    selected: _filter.packs,
                    onChanged: (next) =>
                        setState(() => _filter = _filter.copyWith(packs: next)),
                  ),
                  _PickerRow(
                    title: 'Set',
                    values: _facets.sets,
                    selected: _filter.sets,
                    onChanged: (next) =>
                        setState(() => _filter = _filter.copyWith(sets: next)),
                  ),
                  _PickerRow(
                    title: 'Trait',
                    values: _facets.traits,
                    selected: _filter.traits,
                    onChanged: (next) =>
                        setState(() => _filter = _filter.copyWith(traits: next)),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

String _factionLabel(String code) => switch (code) {
      'aggression' => 'Aggression',
      'justice' => 'Justice',
      'leadership' => 'Leadership',
      'protection' => 'Protection',
      'basic' => 'Basic',
      'hero' => 'Hero',
      'pool' => 'Pool',
      'encounter' => 'Encounter',
      'campaign' => 'Campaign',
      _ => code,
    };

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
        ..sort((a, b) => _factionLabel(a).compareTo(_factionLabel(b))),
      traits: traits.toList()..sort(),
    );
  }
}

class _ChipSection extends StatelessWidget {
  const _ChipSection({
    required this.title,
    required this.values,
    required this.selected,
    required this.labelFor,
    required this.onChanged,
    this.colourFor,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final String Function(String) labelFor;
  final Color Function(String)? colourFor;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in values)
              FilterChip(
                label: Text(labelFor(value)),
                selected: selected.contains(value),
                avatar: colourFor == null
                    ? null
                    : CircleAvatar(backgroundColor: colourFor!(value), radius: 7),
                onSelected: (isOn) {
                  final next = selected.toSet();
                  if (isOn) {
                    next.add(value);
                  } else {
                    next.remove(value);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// One line per long facet, opening a searchable list of its values.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.title,
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(
        selected.isEmpty
            ? 'Any of ${values.length}'
            : selected.toList().join(', '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final next = await Navigator.of(context).push<Set<String>>(
          MaterialPageRoute(
            builder: (_) => _ValuePicker(
              title: title,
              values: values,
              selected: selected,
            ),
          ),
        );
        if (next != null) onChanged(next);
      },
    );
  }
}

class _ValuePicker extends StatefulWidget {
  const _ValuePicker({
    required this.title,
    required this.values,
    required this.selected,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;

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
        : widget.values.where((v) => v.toLowerCase().contains(needle)).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: false,
              autocorrect: false,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search ${widget.title.toLowerCase()}s',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final value = shown[index];
                return CheckboxListTile(
                  title: Text(value),
                  value: _selected.contains(value),
                  onChanged: (isOn) => setState(() {
                    if (isOn ?? false) {
                      _selected.add(value);
                    } else {
                      _selected.remove(value);
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
