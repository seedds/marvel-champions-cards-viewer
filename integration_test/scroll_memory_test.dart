import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:marvel_champions_cards_viewer/main.dart';

/// Scrolling the whole collection must not grow the image cache without bound.
///
/// The bundled scans are ~710x1030. Decoded at native size a screenful is tens of
/// megabytes and iOS terminates the app, so the tiles decode at tile size. This drives
/// a real device hard enough to prove it, because the failure only appears on one.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the grid scrolls without the image cache running away',
      (tester) async {
    await tester.pumpWidget(const CardViewerApp());

    // Loading and parsing 2.2 MB of JSON happens off the UI thread.
    await tester.pumpAndSettle(const Duration(seconds: 30));
    expect(find.text('3632 cards'), findsOneWidget);

    final list = find.byType(ListView);
    expect(list, findsOneWidget);

    var peakBytes = 0;
    var peakCount = 0;

    for (var fling = 0; fling < 60; fling++) {
      await tester.fling(list, const Offset(0, -1200), 4000);
      await tester.pumpAndSettle();

      final cache = PaintingBinding.instance.imageCache;
      peakBytes = peakBytes > cache.currentSizeBytes
          ? peakBytes
          : cache.currentSizeBytes;
      peakCount = peakCount > cache.currentSize ? peakCount : cache.currentSize;
    }

    final peakMb = (peakBytes / (1024 * 1024)).toStringAsFixed(1);
    final average = peakCount == 0 ? 0 : peakBytes ~/ peakCount;
    debugPrint(
      'MEASURED peak image cache $peakMb MB across $peakCount images, '
      'average ${(average / 1024).round()} KB each',
    );
    developer.log('peak $peakMb MB / $peakCount images', name: 'scroll_memory');

    // The app lowers the ceiling to 24 MB. Staying under it proves both that the app
    // set it and that the cache is a bounded LRU rather than something that grows.
    expect(
      peakBytes,
      lessThanOrEqualTo(24 * 1024 * 1024),
      reason: 'peak was $peakMb MB',
    );

    // The real check on cacheWidth: a 710x1030 scan decoded at native size is about
    // 2.9 MB. A 28pt thumbnail is a small fraction of that -- measured at 36 KB, or
    // 680 of them inside the cap -- and if this average ever approaches the native
    // figure then the decode size has been lost somewhere.
    expect(
      average,
      lessThan(300 * 1024),
      reason: 'average decoded thumbnail was ${(average / 1024).round()} KB',
    );
  });
}
