import 'package:flutter/cupertino.dart';

import '../data/settings.dart';
import 'theme.dart';

/// The theme choice, as iOS presents a choice: a row saying what it is set to, which
/// opens a page of the options with a tick against the current one.
///
/// The same shape as Settings > Display & Brightness. The alternative -- three radio
/// rows on this page -- saves a tap and costs the reader a screen that does not look
/// like the one they know.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: const CupertinoNavigationBar(middle: Text('Settings')),
      // Below the scaffold, which is where the nav bar's inset is. See listInsets.
      child: Builder(
        builder: (context) => ListView(
          padding: listInsets(context),
          children: [
            CupertinoListSection.insetGrouped(
              header: const Text('Appearance'),
              children: [
                CupertinoListTile.notched(
                  title: const Text('Theme'),
                  additionalInfo: Text(themeLabel(settings.theme)),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(builder: (_) => const _ThemeScreen()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The options, with a tick against the one in force.
class _ThemeScreen extends StatelessWidget {
  const _ThemeScreen();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);

    return CupertinoPageScaffold(
      backgroundColor: listBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Theme'),
        previousPageTitle: 'Settings',
      ),
      child: Builder(
        builder: (context) => ListView(
          padding: listInsets(context),
          children: [
            CupertinoListSection.insetGrouped(
              footer: const Text('System follows the device setting.'),
              children: [
                for (final theme in AppTheme.values)
                  CupertinoListTile.notched(
                    title: Text(themeLabel(theme)),
                    trailing: theme == settings.theme
                        ? Icon(
                            CupertinoIcons.checkmark,
                            size: 20,
                            color: CupertinoTheme.of(context).primaryColor,
                          )
                        : null,
                    // The page stays open, the way iOS's own does: the choice repaints
                    // the app underneath, which is the confirmation that it took.
                    onTap: () => settings.setTheme(theme),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String themeLabel(AppTheme theme) => switch (theme) {
  AppTheme.system => 'System',
  AppTheme.light => 'Light',
  AppTheme.dark => 'Dark',
};
