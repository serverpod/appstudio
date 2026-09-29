import 'package:appstudio/toolchain/install_progress.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:flutter_test/flutter_test.dart';

ToolProgress at(
  ToolId id,
  ToolPhase phase, {
  int received = 0,
  int total = 0,
  DateTime? since,
}) =>
    ToolProgress(
      id: id,
      phase: phase,
      receivedBytes: received,
      totalBytes: total,
      phaseStartedAt: since,
    );

void main() {
  final started = DateTime(2026, 8, 2, 12);

  group('ToolProgress.fraction', () {
    test('a download measures itself', () {
      expect(
        at(ToolId.flutter, ToolPhase.downloading, received: 50, total: 100)
            .fraction,
        closeTo(0.5, 0.001),
      );
    });

    test('a received count beyond the total is capped', () {
      expect(
        at(ToolId.flutter, ToolPhase.downloading, received: 500, total: 100)
            .fraction,
        1.0,
      );
    });

    test('an unknown total is indeterminate rather than zero', () {
      expect(
        at(ToolId.flutter, ToolPhase.downloading, received: 5).fraction,
        isNull,
      );
    });

    test('steps that report nothing are indeterminate', () {
      // Apple's installer, flutter upgrade and dart install say nothing about
      // how far along they are; a bar that sits still would read as a hang.
      for (final phase in [
        ToolPhase.waitingForApple,
        ToolPhase.extracting,
        ToolPhase.configuring,
        ToolPhase.upgrading,
        ToolPhase.installing,
      ]) {
        expect(at(ToolId.flutter, phase).fraction, isNull, reason: '$phase');
      }
    });
  });

  group('InstallProgress', () {
    test('reports the first step that is not finished', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.commandLineTools, ToolPhase.done),
          at(ToolId.flutter, ToolPhase.downloading, received: 1, total: 4),
          at(ToolId.serverpodCli, ToolPhase.queued),
        ],
      );

      expect(progress.current?.id, ToolId.flutter);
      expect(progress.statusLabel, 'Downloading Flutter…');
      expect(progress.fraction, closeTo(0.25, 0.001));
      expect(progress.bytesReceived, 1);
      expect(progress.bytesTotal, 4);
    });

    test('waiting on Apple says what to do rather than showing bytes', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [at(ToolId.commandLineTools, ToolPhase.waitingForApple)],
      );

      expect(progress.statusLabel, 'Installing Apple\'s command line tools…');
      expect(
        progress.hint,
        'Follow the installation steps in the pop-up window.',
      );
      expect(progress.isDownloading, isFalse);
      expect(progress.fraction, isNull);
    });

    test('names the tail once every step is terminal', () {
      // The re-probe is still running; "Installed Serverpod" read as
      // finished while the dialog was visibly still busy.
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.done),
          at(ToolId.serverpodCli, ToolPhase.done),
        ],
      );

      expect(progress.isDone, isTrue);
      expect(progress.statusLabel, 'Finishing up…');
      expect(progress.fraction, 1.0);
    });

    test('a failure is terminal and reported', () {
      final progress = InstallProgress(
        startedAt: started,
        tools: [
          at(ToolId.flutter, ToolPhase.failed),
          at(ToolId.serverpodCli, ToolPhase.cancelled),
        ],
      );
      expect(progress.isDone, isTrue);
      expect(progress.hasFailure, isTrue);
    });

    group('eta', () {
      InstallProgress downloading({
        required int received,
        required Duration elapsed,
      }) =>
          InstallProgress(
            startedAt: started,
            now: started.add(elapsed),
            tools: [
              at(
                ToolId.flutter,
                ToolPhase.downloading,
                received: received,
                total: 100,
                since: started,
              ),
            ],
          );

      test('extrapolates from the download so far', () {
        final eta =
            downloading(received: 25, elapsed: const Duration(seconds: 30)).eta;
        expect(eta, const Duration(seconds: 90));
      });

      test('stays quiet for the first seconds', () {
        expect(
          downloading(received: 25, elapsed: const Duration(seconds: 2)).eta,
          isNull,
        );
      });

      test('is null outside a download', () {
        final progress = InstallProgress(
          startedAt: started,
          now: started.add(const Duration(minutes: 5)),
          tools: [
            at(ToolId.serverpodCli, ToolPhase.installing, since: started),
          ],
        );
        expect(progress.eta, isNull);
      });
    });
  });

  test('the line under the bar never repeats the status line', () {
    // "Setting up Flutter…" above and "Setting up Flutter" below read as a
    // stutter; those steps leave the line empty instead.
    for (final phase in [
      ToolPhase.configuring,
      ToolPhase.upgrading,
      ToolPhase.installing,
    ]) {
      expect(phase.hint, isNull, reason: '$phase');
    }
  });
}
