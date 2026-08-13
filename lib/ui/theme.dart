import 'package:flutter/cupertino.dart';

import '../data/settings.dart';

/// The theme, as the chosen setting asks for it.
///
/// Dark was the only theme for a while, on the reasoning that a card's own art should
/// be the brightest thing on the screen. It still is, and it is still the better one
/// for looking at cards -- but which of the two to use is the reader's call, and the
/// system's answer is a perfectly good default.
///
/// [AppTheme.system] becomes a **null brightness**, which is how Cupertino spells
/// "follow the device": `CupertinoApp` has no `themeMode` to pair with a light and a
/// dark theme the way `MaterialApp` does, and a null here leaves every widget below
/// deferring to `MediaQueryData.platformBrightness`.
CupertinoThemeData buildTheme(AppTheme theme) {
  return CupertinoThemeData(
    brightness: switch (theme) {
      AppTheme.system => null,
      AppTheme.light => Brightness.light,
      AppTheme.dark => Brightness.dark,
    },
  );
}

/// The room a scrolling list needs at each end.
///
/// A Cupertino nav bar and tab bar are both *translucent*, so a list draws behind them
/// rather than starting below them -- and `ListView` consumes none of that on its own.
/// Without this the first row sits under the nav bar's blur, where it cannot even be
/// tapped, and the last row is stuck behind the tab bar for good.
///
/// **The context must be below the `CupertinoPageScaffold`, not the one that built it.**
/// The scaffold reports the bar's height as padding to its *child*, so a `build` method
/// that creates the scaffold and calls this in the same breath reads zero and produces
/// exactly the bug this exists to prevent. Where the list is the scaffold's own child,
/// a `Builder` is what puts the context on the right side of it.
///
/// [top] is false for a list that has something above it already holding the nav bar's
/// inset, like the browse list under its search field.
EdgeInsets listInsets(BuildContext context, {bool top = true, double extra = 0}) {
  final padding = MediaQuery.paddingOf(context);
  return EdgeInsets.only(
    top: top ? padding.top + extra : 0,
    bottom: padding.bottom + extra,
  );
}

/// The background a list of cards sits on.
///
/// Grouped rather than plain, which is what iOS puts under inset sections and what
/// makes a row's own separator read as a separator rather than as an edge.
const listBackground = CupertinoColors.systemGroupedBackground;

/// A row's own surface, against [listBackground].
const rowBackground = CupertinoColors.secondarySystemGroupedBackground;

/// The three sizes the rows and headings use.
///
/// Cupertino's text theme is a handful of named roles -- `textStyle`, `navTitleTextStyle`
/// -- rather than Material's numbered scale, and nothing in it is the 13pt caption a
/// card row needs. These are derived from the theme's own `textStyle` so they inherit
/// its font and its label colour, and named once here rather than as loose `fontSize:`
/// arguments in five files.
TextStyle rowTitleStyle(BuildContext context) =>
    CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        );

/// The smaller line under a title, and the type-and-traits line of a card row.
TextStyle rowCaptionStyle(BuildContext context) =>
    CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          fontSize: 12,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        );

/// A count, a label, or anything else that is deliberately quiet.
TextStyle captionStyle(BuildContext context) =>
    CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          fontSize: 13,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        );

/// The colour that stands for each aspect, taken from the cards themselves. Encounter
/// and campaign cards are the game's rather than a player's, and are grey.
const aspectColours = <String, Color>{
  'aggression': Color(0xFFB3231F),
  'justice': Color(0xFFE0A526),
  'leadership': Color(0xFF2C7FC0),
  'protection': Color(0xFF4E9A3E),
  'basic': Color(0xFF8E8E93),
  'hero': Color(0xFF6C5CB5),
  'pool': Color(0xFFC64B8C),
  'encounter': Color(0xFF5A5A5F),
  'campaign': Color(0xFF5A5A5F),
};

Color aspectColour(String factionCode) =>
    aspectColours[factionCode] ?? const Color(0xFF5A5A5F);

/// The aspect colour as *text* on the current background.
///
/// The colours above are the game's, picked to read as a solid fill. Set as type on a
/// light page several of them stop being legible -- Justice's #E0A526 on white is the
/// worst -- so on a light theme they are darkened until they are. The identity is
/// preserved: a darker yellow is still recognisably Justice, where substituting a
/// theme colour would not be.
Color aspectTextColour(String factionCode, Brightness brightness) {
  final colour = aspectColour(factionCode);
  if (brightness == Brightness.dark) return colour;
  final hsl = HSLColor.fromColor(colour);
  return hsl.withLightness(hsl.lightness.clamp(0.0, 0.36)).toColor();
}

/// A faction, spelled the way the game does rather than as a snake_case code.
const factionLabels = <String, String>{
  'aggression': 'Aggression',
  'justice': 'Justice',
  'leadership': 'Leadership',
  'protection': 'Protection',
  'basic': 'Basic',
  'hero': 'Hero',
  'pool': 'Pool',
  'encounter': 'Encounter',
  'campaign': 'Campaign',
};

String factionLabel(String factionCode) =>
    factionLabels[factionCode] ?? factionCode;

/// A card type, spelled the way the game does rather than as a snake_case code.
const typeLabels = <String, String>{
  'ally': 'Ally',
  'alter_ego': 'Alter-Ego',
  'attachment': 'Attachment',
  'environment': 'Environment',
  'event': 'Event',
  'evidence_means': 'Evidence (Means)',
  'evidence_motive': 'Evidence (Motive)',
  'evidence_opportunity': 'Evidence (Opportunity)',
  'hero': 'Hero',
  'leader': 'Leader',
  'main_scheme': 'Main Scheme',
  'minion': 'Minion',
  'obligation': 'Obligation',
  'player_side_scheme': 'Player Side Scheme',
  'resource': 'Resource',
  'side_scheme': 'Side Scheme',
  'support': 'Support',
  'treachery': 'Treachery',
  'upgrade': 'Upgrade',
  'villain': 'Villain',
};

String typeLabel(String typeCode) => typeLabels[typeCode] ?? typeCode;
