import 'package:flutter/material.dart';

import 'data/card_repository.dart';
import 'data/settings.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() => runApp(const CardViewerApp());

class CardViewerApp extends StatefulWidget {
  const CardViewerApp({super.key});

  @override
  State<CardViewerApp> createState() => _CardViewerAppState();
}

class _CardViewerAppState extends State<CardViewerApp> {
  late final Future<CardRepository> _repository = CardRepository.load();

  /// Read before the first frame that has a theme to apply, so that someone who chose
  /// Dark does not get a white flash on every launch.
  late final Future<Settings> _settings = Settings.load();

  @override
  void initState() {
    super.initState();
    // A list of 3,632 cards will fill whatever image cache it is given, and Flutter's
    // default ceiling is 100 MB -- measured at exactly that, across 159 thumbnails.
    // A row's art is 56 logical pixels wide, so 24 MB holds hundreds of rows and
    // leaves headroom for the full-size art a detail screen decodes. The cache is an
    // LRU: a smaller one costs a re-decode when scrolling back, never a blank row.
    //
    // Set here rather than in main() so that it is part of the widget under test.
    PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Settings>(
      future: _settings,
      builder: (context, settingsSnapshot) {
        final settings = settingsSnapshot.data;
        if (settings == null) {
          // A file read, not a network call. Nothing is shown for it rather than a
          // spinner that would flash for a frame or two.
          return const SizedBox.shrink();
        }

        return SettingsScope(
          notifier: settings,
          child: FutureBuilder<CardRepository>(
            future: _repository,
            builder: (context, snapshot) {
              final repository = snapshot.data;
              final error = snapshot.error;

              // The scope goes *above* the MaterialApp, and so above the Navigator it
              // creates. Below it, a pushed route is a sibling of the home screen
              // rather than a descendant, and every card detail screen fails to find
              // the data.
              return CardRepositoryScope(
                repository: repository,
                // The MaterialApp reads themeMode, so something between it and the
                // settings has to listen: SettingsScope only rebuilds what is *below*
                // it, and the app is below it. Without this the setting is stored and
                // applied on the next launch, which looks like the switch not working.
                child: ListenableBuilder(
                  listenable: settings,
                  builder: (context, _) => MaterialApp(
                    title: 'Marvel Champions Cards',
                    theme: buildTheme(Brightness.light),
                    darkTheme: buildTheme(Brightness.dark),
                    themeMode: settings.themeMode,
                    home: switch ((repository, error)) {
                      (_, final Object error) => _LoadFailed(error: error),
                      (null, _) => const Scaffold(
                          body: Center(child: CircularProgressIndicator()),
                        ),
                      _ => const HomeScreen(),
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The card data, available to every screen below it.
///
/// There is one immutable repository for the life of the app, so this never notifies:
/// nothing about it can change. Filters and queries are screen state, held where they
/// are used.
class CardRepositoryScope extends InheritedWidget {
  const CardRepositoryScope({
    required this.repository,
    required super.child,
    super.key,
  });

  /// Null only while the data is still loading, when no screen that reads it is on
  /// the tree.
  final CardRepository? repository;

  static CardRepository of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<CardRepositoryScope>();
    assert(scope != null, 'No CardRepositoryScope above this widget');
    final repository = scope!.repository;
    assert(repository != null, 'Card data read before it finished loading');
    return repository!;
  }

  @override
  bool updateShouldNotify(CardRepositoryScope oldWidget) =>
      repository != oldWidget.repository;
}

/// The card data ships inside the app, so a failure here is a broken build rather
/// than something a person can retry their way out of. Say so plainly.
class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text('The bundled card data could not be read.'),
              const SizedBox(height: 8),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
