import 'package:appstudio/util/byte_format.dart';
import 'package:appstudio/widgets/determinate_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('leaves small sizes in bytes', () {
      expect(formatBytes(0), '0 bytes');
      expect(formatBytes(1), '1 bytes');
      expect(formatBytes(999), '999 bytes');
    });

    test('uses decimal SI, matching how macOS reports sizes', () {
      expect(formatBytes(1000), '1 kB');
      expect(formatBytes(1500), '1.5 kB');
      expect(formatBytes(1000000), '1 MB');
    });

    test('drops the decimal at or above ten of a unit', () {
      expect(formatBytes(9900000), '9.9 MB');
      expect(formatBytes(12300000), '12 MB');
      expect(formatBytes(132000000), '132 MB');
    });

    test('formats the real toolchain sizes', () {
      expect(formatBytes(1610612736), '1.6 GB'); // Flutter, unpacked
      expect(formatBytes(980000000), '980 MB'); // the download total
      expect(formatBytes(29000000), '29 MB'); // Serverpod CLI
    });

    test('carries over instead of rendering 1000 of a unit', () {
      // 999.96 MB rounds to 1000 MB at one decimal — must become 1 GB.
      expect(formatBytes(999960000), '1 GB');
    });

    test('treats a negative size as zero rather than throwing', () {
      expect(formatBytes(-1), '0 bytes');
    });
  });

  group('formatDuration', () {
    test('never shows zero seconds', () {
      expect(formatDuration(Duration.zero), '1 sec');
      expect(formatDuration(const Duration(milliseconds: 400)), '1 sec');
    });

    test('switches to minutes then hours', () {
      expect(formatDuration(const Duration(seconds: 45)), '45 sec');
      expect(formatDuration(const Duration(seconds: 150)), '3 min');
      expect(formatDuration(const Duration(minutes: 59)), '59 min');
      expect(formatDuration(const Duration(minutes: 60)), '1 hr');
      expect(formatDuration(const Duration(minutes: 90)), '1 hr 30 min');
    });
  });

  group('formatTransferCaption', () {
    test('reads as "received of total · eta"', () {
      expect(
        formatTransferCaption(
          received: 412000000,
          total: 980000000,
          eta: const Duration(minutes: 2),
        ),
        '412 MB of 980 MB · 2 min left',
      );
    });

    test('drops the eta when it is unknown', () {
      expect(
        formatTransferCaption(received: 412000000, total: 980000000),
        '412 MB of 980 MB',
      );
    });

    test('drops the total when the server sent no length', () {
      expect(
        formatTransferCaption(received: 412000000, total: 0),
        '412 MB',
      );
    });
  });
}
