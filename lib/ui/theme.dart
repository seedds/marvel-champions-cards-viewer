import 'package:flutter/material.dart';

/// The red of a Marvel Champions box, which both themes are grown from.
const _seed = Color(0xFFB3121C);

/// Dark was the only theme for a while, on the reasoning that a card's own art should
/// be the brightest thing on the screen. It still is, and it is still the better one
/// for looking at cards -- but which of the two to use is the reader's call, and the
/// system's answer is a perfectly good default.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // A shade off the scheme's own surface, so that a card's art sits on something
    // slightly darker (or lighter) than the panels and chips around it.
    scaffoldBackgroundColor: brightness == Brightness.dark
        ? const Color(0xFF121316)
        : scheme.surface,
  );
}

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
/// worst -- so on a light scheme they are darkened until they are. The identity is
/// preserved: a darker yellow is still recognisably Justice, where substituting a
/// theme colour would not be.
Color aspectTextColour(String factionCode, ColorScheme scheme) {
  final colour = aspectColour(factionCode);
  if (scheme.brightness == Brightness.dark) return colour;
  final hsl = HSLColor.fromColor(colour);
  return hsl.withLightness(hsl.lightness.clamp(0.0, 0.36)).toColor();
}

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
