import 'package:appstudio/toolchain/install_progress.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:flutter_test/flutter_test.dart';

ToolProgress at(
  ToolId id,
  ToolPhase phase, {
  int received = 0,
  int total = 0,
}) =>
    ToolProgress(
      id: id,
      phase: phase,
      receivedBytes: received,
      totalBytes: total,
    );

void main() {
  final started = DateTime(2026, 8, 2, 12);

  group('ToolProgress.fraction', () {
    test('download progress is capped at its phase weight', () {
      final half = at(ToolId.flutter, ToolPhase.downloading,
          received: 50, total: 100);
      expect(half.fraction, closeTo(0.425, 0.001)); // 0.5 * 0.85

      final full = at(ToolId.flutter, ToolPhase.downloading,
          received: 100, total: 100);
      expect(full.fraction, closeTo(0.85, 0.001));
    });

    test('later phases never go backwards', () {
      final download = at(ToolId.flutter, ToolPhase.downloading,
          received: 100, total: 100);
      final verify = at(ToolId.flutter, ToolPhase.verifying);
      final extract = at(ToolId.flutter, ToolPhase.extracting);
      final done = at(ToolId.flutter, ToolPhase.done);

      expect(verify.fraction! >= download.fraction!, isTrue);
      expect(extract.fraction! >= verify.fraction!, isTrue);
      expect(done.fraction, 1.0);
    });

    test('an unknown total is indeterminate rather than zero', () {
      expect(at(ToolId.flutter, ToolPhase.downloading, received: 5).fraction,
          isNull);
    });

    test('failure and cancellation are indeterminate', () {
      expect(at(ToolId.flutter, ToolPhase.failed).fraction, isNull);
      expect(at(ToolId.flutter, ToolPhase.cancelled).fraction, isNull);
    });

    test('a received count beyond the total cannot exceed the weight', () {
      final over = at(ToolId.flutter, ToolPhase.downloading,
          received: 500, total: 100);
      expect(over.fraction, closeTo(0.85, 0.001));
    });
  });

  group('InstallProgress', () {
    test('weights by download size, not tool count', () {
      // Flutter is ~60x the CLI; finishing the CLI must barely move the bar.
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.queued, total: 694000000),
          at(ToolId.serverpodCli, ToolPhase.done, total: 11000000),
        ],
      );
      expect(progress.fraction, lessThan(0.02));
    });

    test('reaches 1 only when everything is done', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.done, total: 100),
          at(ToolId.git, ToolPhase.done, total: 100),
        ],
      );
      expect(progress.fraction, 1.0);
      expect(progress.isDone, isTrue);
      expect(progress.hasFailure, isFalse);
    });

    test('a failed tool is terminal but flagged', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.done, total: 100),
          at(ToolId.git, ToolPhase.failed, total: 100),
        ],
      );
      expect(progress.isDone, isTrue);
      expect(progress.hasFailure, isTrue);
    });

    test('sums received bytes across tools', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.downloading, received: 40, total: 100),
          at(ToolId.git, ToolPhase.downloading, received: 10, total: 50),
        ],
      );
      expect(progress.bytesReceived, 50);
      expect(progress.bytesTotal, 150);
    });

    test('withholds an ETA until there is signal', () {
      // Under three seconds in: any estimate would be noise.
      expect(
        InstallProgress(
          startedAt: started,
          now: started.add(const Duration(seconds: 2)),
          tools: [
            at(ToolId.flutter, ToolPhase.downloading, received: 10, total: 100),
          ],
        ).eta,
        isNull,
      );
    });

    test('estimates from elapsed time once underway', () {
      // 25 % done after 10 s implies roughly 30 s left.
      final progress = InstallProgress(
        startedAt: started,
        now: started.add(const Duration(seconds: 10)),
        tools: [
          at(ToolId.flutter, ToolPhase.downloading,
              received: 29, total: 100), // 0.29 * 0.85 ≈ 0.25
        ],
      );
      final eta = progress.eta!;
      expect(eta.inSeconds, inInclusiveRange(25, 45));
    });

    test('no ETA once complete', () {
      expect(
        InstallProgress(
          startedAt: started,
          now: started.add(const Duration(seconds: 30)),
          tools: [at(ToolId.flutter, ToolPhase.done, total: 100)],
        ).eta,
        isNull,
      );
    });

    test('names the first tool still working', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.done, total: 100),
          at(ToolId.git, ToolPhase.extracting, total: 100),
        ],
      );
      expect(progress.statusLabel, 'Extracting Git…');
    });

    test('calls the tail after the last download "Finishing up"', () {
      // The re-probe and the shell PATH write still have to run, so naming the
      // last tool here would report the install as over while it is not.
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.done, total: 100),
          at(ToolId.git, ToolPhase.done, total: 100),
        ],
      );
      expect(progress.statusLabel, 'Finishing up…');
    });

    test('looks up a tool by id', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [at(ToolId.git, ToolPhase.extracting, total: 10)],
      );
      expect(progress[ToolId.git]?.phase, ToolPhase.extracting);
      expect(progress[ToolId.flutter], isNull);
    });
  });
}
