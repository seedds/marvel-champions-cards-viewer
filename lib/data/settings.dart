import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// The choices a person makes about the app, and where they are kept.
///
/// One small JSON file in the application support directory -- not the documents
/// directory, which is the user's, and not a database, for one enum. It notifies,
/// unlike the card data: the theme changes while the app is running, which is the whole
/// point of it.
class Settings extends ChangeNotifier {
  Settings._(this._file, this._themeMode);

  final File? _file;
  ThemeMode _themeMode;

  ThemeMode get themeMode => _themeMode;

  /// Read the stored settings, falling back to the defaults.
  ///
  /// Anything unreadable -- no file yet, a half-written file, a value from a newer
  /// version of the app -- is the defaults. A preference is not worth failing to start
  /// over, which is the opposite of how the bundled card data is treated: that being
  /// wrong is a broken build.
  static Future<Settings> load() async {
    File? file;
    var mode = ThemeMode.system;
    try {
      final directory = await getApplicationSupportDirectory();
      file = File('${directory.path}/settings.json');
      if (file.existsSync()) {
        final stored = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        mode = _modeFromName(stored['themeMode'] as String?) ?? mode;
      }
    } catch (_) {
      // Keep the defaults, and keep whatever file handle was resolved so that a
      // later write can still succeed.
    }
    return Settings._(file, mode);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'themeMode': _themeMode.name}));
    } catch (_) {
      // The setting still applies to this session; it just will not outlive it.
    }
  }

  static ThemeMode? _modeFromName(String? name) {
    for (final mode in ThemeMode.values) {
      if (mode.name == name) return mode;
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
