import 'package:flutter/cupertino.dart';

import 'browse_screen.dart';
import 'decks_screen.dart';
import 'settings_screen.dart';

/// The three places there are to be.
///
/// `CupertinoTabScaffold` keeps every tab it has built alive and offstage, so each one
/// holds its scroll position, its search text and its filters while another is on top --
/// which is what a person expects of a tab, and what makes returning to a half-typed
/// search not a loss.
///
/// Deliberately without a `CupertinoTabView` per tab: that gives each tab its own
/// Navigator, which would leave the tab bar visible underneath a card. A card's art is
/// the point of the screen it is on, so a detail screen covers the tab bar instead,
/// pushed on the one root Navigator.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        items: const [
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.square_stack_3d_down_right),
            label: 'Cards',
          ),
          BottomNavigationBarItem(
            icon: Icon(CupertinoIcons.rectangle_stack),
            label: 'Decks',
          ),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.settings), label: 'Settings'),
        ],
      ),
      tabBuilder: (context, index) => switch (index) {
        0 => const BrowseScreen(),
        1 => const DecksScreen(),
        _ => const SettingsScreen(),
      },
    );
  }
}
