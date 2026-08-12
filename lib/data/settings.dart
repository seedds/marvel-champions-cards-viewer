import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Which of the two themes to use, or to take the device's answer.
///
/// Declared here rather than reusing Material's `ThemeMode`, which is the only thing
/// that would drag `material.dart` into the data layer of a Cupertino app. The names
/// match the ones already written to settings.json, so a stored choice still reads.
enum AppTheme { system, light, dark }

/// The choices a person makes about the app, and where they are kept.
///
/// One small JSON file in the application support directory -- not the documents
/// directory, which is the user's, and not a database, for one enum. It notifies,
/// unlike the card data: the theme changes while the app is running, which is the whole
/// point of it.
class Settings extends ChangeNotifier {
  Settings._(this._file, this._theme);

  final File? _file;
  AppTheme _theme;

  AppTheme get theme => _theme;

  /// Read the stored settings, falling back to the defaults.
  ///
  /// Anything unreadable -- no file yet, a half-written file, a value from a newer
  /// version of the app -- is the defaults. A preference is not worth failing to start
  /// over, which is the opposite of how the bundled card data is treated: that being
  /// wrong is a broken build.
  static Future<Settings> load() async {
    File? file;
    var theme = AppTheme.system;
    try {
      final directory = await getApplicationSupportDirectory();
      file = File('${directory.path}/settings.json');
      if (file.existsSync()) {
        final stored = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        theme = _themeFromName(stored['themeMode'] as String?) ?? theme;
      }
    } catch (_) {
      // Keep the defaults, and keep whatever file handle was resolved so that a
      // later write can still succeed.
    }
    return Settings._(file, theme);
  }

  Future<void> setTheme(AppTheme theme) async {
    if (theme == _theme) return;
    _theme = theme;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'themeMode': _theme.name}));
    } catch (_) {
      // The setting still applies to this session; it just will not outlive it.
    }
  }

  static AppTheme? _themeFromName(String? name) {
    for (final theme in AppTheme.values) {
      if (theme.name == name) return theme;
    }
    return null;
  }
}

/// The settings, available to every screen below.
class SettingsScope extends InheritedNotifier<Settings> {
  const SettingsScope({required Settings super.notifier, required super.child, super.key});

  static Settings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope?.notifier != null, 'No SettingsScope above this widget');
    return scope!.notifier!;
  }
}
