import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../platform/linux/desktop_integration.dart';
import '../../platform/linux/running_app_image.dart';
import '../update_state.dart';
import 'appcast.dart';
import 'update_signals.dart';

export 'update_signals.dart';

/// Where the feed is and which key signs the downloads, compiled in by
/// `tool/linux/build_appimage.sh` from `linux/release.json`.
@immutable
class LinuxUpdateConfig {
  const LinuxUpdateConfig({required this.appcastUrl, required this.publicKey});

  static const compiledIn = LinuxUpdateConfig(
    appcastUrl: String.fromEnvironment('APPSTUDIO_APPCAST_URL'),
    publicKey: String.fromEnvironment('APPSTUDIO_EDDSA_PUBLIC_KEY'),
  );

  final String appcastUrl;

  /// The Ed25519 public key, base64 of its 32 bytes.
  final String publicKey;

  bool get isComplete => appcastUrl.isNotEmpty && publicKey.isNotEmpty;
}

/// Something the user should read: why a check or an update failed.
class LinuxUpdateException implements Exception {
  const LinuxUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A download that arrived whole and carries a valid signature, ready to
/// take the running AppImage's place.
class VerifiedUpdate {
  const VerifiedUpdate._(this.path, this.item);

  /// Only [LinuxUpdater.download] makes a real one: this skips the check.
  @visibleForTesting
  const VerifiedUpdate.forTesting(this.path, this.item);

  /// The hidden file beside the AppImage.
  final String path;
  final AppcastItem item;
}

/// App Studio's updater on Linux, where neither Sparkle nor WinSparkle runs:
/// reads the appcast, downloads a newer AppImage beside the running one,
/// checks its signature and renames it over the running file. A running
/// AppImage stays mounted when its file is replaced, so this copy carries on
/// until it quits and the new file starts.
///
/// Every outside thing is injected — the environment, the executable, the
/// HTTP client, the version — so the tests run on any host.
class LinuxUpdater {
  LinuxUpdater({
    LinuxUpdateConfig? config,
    Map<String, String>? environment,
    String? executable,
    http.Client? client,
    Future<AppVersion?> Function()? runningVersion,
    DesktopIntegration? desktop,
  }) : config = config ?? LinuxUpdateConfig.compiledIn,
       _environment = environment ?? Platform.environment,
       _executable = executable ?? Platform.resolvedExecutable,
       _client = client ?? http.Client(),
       _runningVersion = runningVersion ?? readRunningVersion,
       _desktop =
           desktop ??
           DesktopIntegration(
             environment: environment,
             executable: executable,
             runningVersion: runningVersion,
           );

  static const automaticKey = 'linux.updates.automatic';
  static const lastCheckKey = 'linux.updates.last_check';
  static const skippedBuildKey = 'linux.updates.skipped_build';

  /// How often the automatic check looks, as Sparkle's default on macOS.
  static const checkInterval = Duration(days: 1);

  /// The hidden file a download goes to, beside the AppImage.
  static const partName = '.AppStudio-update.part';

  final LinuxUpdateConfig config;
  final Map<String, String> _environment;
  final String _executable;
  final http.Client _client;
  final Future<AppVersion?> Function() _runningVersion;
  final DesktopIntegration _desktop;

  /// A download is running. The menu stays usable under the update dialog,
  /// so a second check or download can start meanwhile: neither may touch
  /// the file the first is writing.
  bool _downloading = false;

  /// The AppImage this process was started from, as its runtime named it,
  /// or null when this is not one.
  String? get appImage => runningAppImage(_environment, _executable);

  /// The file an update replaces: the copy in the app menu when it is this
  /// build, otherwise [appImage]. Null when neither is there.
  ///
  /// The menu's copy comes first because Add to Applications may have
  /// put it there in this run: `$APPIMAGE` still names where the file was,
  /// and when Add had to copy rather than move (a folder the file could not
  /// be taken out of, such as /opt), the original is still there and still
  /// cannot be written to. The menu's copy is also the one started next.
  ///
  /// So a second copy of the same build, run from `~/Downloads` say,
  /// updates the menu's copy and restarts that one. The copy that ran stays
  /// as it is, and when it is started again it offers to open the newer
  /// one in the app menu (the "another copy" question).
  Future<String?> liveAppImage() async {
    final started = appImage;
    if (started == null) return null;
    // Only the copy this one became: App Studio's entry names it and
    // records this build. Any other file there (one left after Remove,
    // perhaps newer) is not this App Studio's to replace.
    final added = _desktop.addedAppImagePath;
    final running = await _runningVersion();
    if (added != null &&
        running != null &&
        await File(added).exists() &&
        await _desktop.recordedVersionOf(added) == running) {
      return added;
    }
    if (await File(started).exists()) return started;
    return null;
  }

  Future<String> _requireLiveAppImage() async {
    final live = await liveAppImage();
    if (live == null) {
      throw const LinuxUpdateException(
        'The AppImage App Studio was started from is gone.',
      );
    }
    return live;
  }

  Future<AppVersion?> runningVersion() => _runningVersion();

  /// What the menu, About and the analytics read, in the same shape the
  /// macOS and Windows updaters report.
  Future<UpdateState> state() async {
    final prefs = await SharedPreferences.getInstance();
    final version = await _runningVersion();
    final lastCheck = prefs.getInt(lastCheckKey);
    return UpdateState(
      configured: config.isComplete && appImage != null,
      currentVersion: version?.version ?? '',
      currentBuild: version == null ? '' : '${version.build}',
      automaticallyChecks: prefs.getBool(automaticKey) ?? true,
      lastCheck: lastCheck == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheck),
    );
  }

  Future<void> setAutomaticallyChecks(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(automaticKey, enabled);
  }

  /// Whether the automatic check should look now: configured, switched on,
  /// and the last check at least [checkInterval] ago.
  Future<bool> isCheckDue(DateTime now) async {
    final state = await this.state();
    if (!state.canCheck || !state.automaticallyChecks) return false;
    final last = state.lastCheck;
    return last == null || now.difference(last) >= checkInterval;
  }

  /// The build the user chose to skip, which the automatic check leaves out.
  Future<int?> skippedBuild() async =>
      (await SharedPreferences.getInstance()).getInt(skippedBuildKey);

  Future<void> skip(AppcastItem item) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(skippedBuildKey, item.version.build);
  }

  /// Reads the feed and returns the newest release above the running build,
  /// or null when this one is the newest. Records the check either way, so a
  /// failing feed is not asked again every hour. Throws
  /// [LinuxUpdateException].
  Future<AppcastItem?> check() async {
    final running = await _runningVersion();
    if (!config.isComplete || appImage == null || running == null) {
      throw const LinuxUpdateException(
        'Updates are not available in this build.',
      );
    }
    final feed = Uri.tryParse(config.appcastUrl);
    if (feed == null || !isSecureUpdateUrl(feed)) {
      throw LinuxUpdateException(
        'The update feed ${config.appcastUrl} is not an https address.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    // A download a crash or a kill interrupted is ~140 MB nobody would find:
    // it is hidden. It can sit beside either copy, since which one an update
    // replaces depends on the app menu at the time. No download runs while
    // a check does.
    if (!_downloading) {
      final folders = {
        for (final path in [appImage, await liveAppImage()])
          if (path != null) p.dirname(path),
      };
      for (final folder in folders) {
        await discard(p.join(folder, partName));
      }
    }
    final http.Response response;
    try {
      response = await _client.get(feed).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const LinuxUpdateException('The update server did not answer.');
    } on Exception catch (e) {
      throw LinuxUpdateException('Could not reach the update server: $e');
    }
    if (response.statusCode != 200) {
      throw LinuxUpdateException(
        'The update server answered ${response.statusCode}.',
      );
    }
    try {
      return newestUpdate(
        utf8.decode(response.bodyBytes),
        current: running.build,
      );
    } on FormatException catch (e) {
      throw LinuxUpdateException(e.message);
    }
  }

  /// Downloads [item] beside the AppImage and checks its length and
  /// signature. [onProgress] gets the bytes so far and the total. Deletes
  /// what it wrote when anything fails or [cancellation] asks it to stop;
  /// a cancelled download returns null. Throws [LinuxUpdateException].
  Future<VerifiedUpdate?> download(
    AppcastItem item, {
    void Function(int received, int total)? onProgress,
    UpdateCancellation? cancellation,
  }) async {
    if (!isSecureUpdateUrl(item.url)) {
      throw LinuxUpdateException(
        'The update feed names ${item.url}, which is not an https address.',
      );
    }
    if (_downloading) {
      throw const LinuxUpdateException('An update is downloading already.');
    }
    _downloading = true;
    try {
      return await _download(
        item,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    } finally {
      _downloading = false;
    }
  }

  Future<VerifiedUpdate?> _download(
    AppcastItem item, {
    void Function(int received, int total)? onProgress,
    UpdateCancellation? cancellation,
  }) async {
    final target = await _requireLiveAppImage();
    final folder = p.dirname(target);
    final part = File(p.join(folder, partName));
    final IOSink sink;
    try {
      // Created anew, never opened through whatever is there: a link left
      // in its place would otherwise be followed.
      await discard(part.path);
      await part.create(exclusive: true);
      sink = part.openWrite();
    } on FileSystemException {
      throw LinuxUpdateException(
        'App Studio cannot replace itself in $folder. Move the AppImage to '
        'a folder of your own, such as ~/AppImages (Help → Add to '
        'Applications), then try again.',
      );
    }

    // One listener for the whole download, not one per chunk.
    final cancelled = cancellation?.whenCancelled.then<Null>((_) => null);
    var complete = false;
    try {
      final response = await _orCancelled(
        _client
            .send(http.Request('GET', item.url))
            .timeout(const Duration(seconds: 30)),
        cancelled,
        // A response that arrives after Cancel would hold its connection
        // open: nobody reads its body.
        dropLate: (late) => late.stream.listen(null).cancel(),
      );
      if (response == null) return null;
      if (response.statusCode != 200) {
        throw LinuxUpdateException(
          'The download answered ${response.statusCode}.',
        );
      }
      var received = 0;
      final chunks = StreamIterator(
        response.stream.timeout(const Duration(seconds: 60)),
      );
      try {
        while (await _orCancelled(chunks.moveNext(), cancelled) ?? false) {
          final chunk = chunks.current;
          received += chunk.length;
          if (received > item.length) break;
          sink.add(chunk);
          onProgress?.call(received, item.length);
        }
      } finally {
        await chunks.cancel();
      }
      await sink.close();
      if (cancellation?.isCancelled ?? false) return null;
      if (received != item.length) {
        throw LinuxUpdateException(
          'The download is $received bytes, not the ${item.length} the '
          'update feed names.',
        );
      }
      // Locals only: the closure is sent to the isolate, and this object
      // (its HTTP client) cannot be.
      final path = part.path;
      final signature = item.signature;
      final publicKey = config.publicKey;
      final valid = await Isolate.run(
        () => verifyEd25519File(path, signature, publicKey),
      );
      if (!valid) {
        throw const LinuxUpdateException(
          'The download does not carry a valid signature, so it was not '
          'installed.',
        );
      }
      final chmod = await Process.run('chmod', ['755', part.path]);
      if (chmod.exitCode != 0) {
        throw LinuxUpdateException(
          'Could not make the download executable: '
          '${(chmod.stderr as String).trim()}',
        );
      }
      complete = true;
      return VerifiedUpdate._(part.path, item);
    } on TimeoutException {
      if (cancellation?.isCancelled ?? false) return null;
      throw const LinuxUpdateException('The download stopped answering.');
    } on LinuxUpdateException {
      rethrow;
    } on Exception catch (e) {
      throw LinuxUpdateException('The download failed: $e');
    } finally {
      if (!complete) {
        try {
          await sink.close();
        } on Object {
          // Closed already, or never written.
        }
        await discard(part.path);
      }
    }
  }

  /// Replaces the running AppImage with [update], records the new version in
  /// App Studio's menu entry when it names this file, and starts the new
  /// file once this process has ended. The caller quits right after.
  ///
  /// Throws [LinuxUpdateException] when the replacement fails, which leaves
  /// the running file as it was, and [UpdateInstalledException] when only
  /// the restart fails, after it.
  Future<void> install(
    VerifiedUpdate update, {
    @visibleForTesting int? afterPid,
  }) async {
    final String target;
    try {
      target = await _requireLiveAppImage();
    } on LinuxUpdateException {
      await discard(update.path);
      rethrow;
    }
    try {
      await File(update.path).rename(target);
    } on FileSystemException catch (e) {
      await discard(update.path);
      throw LinuxUpdateException(
        'Could not replace $target: ${e.osError?.message ?? e.message}',
      );
    }
    await _desktop.recordUpdatedVersion(target, update.item.version);
    try {
      await startAfterExit(target, afterPid: afterPid);
    } on ProcessException catch (e) {
      throw UpdateInstalledException(
        update.item.version.version,
        'App Studio could not start it (${e.message}). Quit App Studio and '
        'start it again.',
      );
    }
  }

  /// Deletes a download that will not be installed.
  Future<void> discard(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Never written, or gone already.
    }
  }
}

/// Whether [signature] (base64) is a valid Ed25519 signature over the whole
/// file at [path] for [publicKey] (base64 of its 32 bytes). Runs in an
/// isolate: it reads the whole file, ~140 MB.
Future<bool> verifyEd25519File(
  String path,
  String signature,
  String publicKey,
) async {
  final List<int> signatureBytes;
  final List<int> keyBytes;
  try {
    signatureBytes = base64.decode(signature.trim());
    keyBytes = base64.decode(publicKey.trim());
  } on FormatException {
    return false;
  }
  if (signatureBytes.length != 64 || keyBytes.length != 32) return false;
  return DartEd25519().verify(
    await File(path).readAsBytes(),
    signature: Signature(
      signatureBytes,
      publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
    ),
  );
}

/// [future]'s value, or null as soon as [cancelled] completes. A value
/// [future] gives after that goes to [dropLate], and an error it raises is
/// dropped: nobody is waiting for either.
Future<T?> _orCancelled<T>(
  Future<T> future,
  Future<Null>? cancelled, {
  void Function(T late)? dropLate,
}) {
  if (cancelled == null) return future;
  var settled = false;
  // Registered before the race's own listeners, so a value that wins the
  // race arrives here first, while settled is still false.
  future.then<void>((value) {
    if (settled) dropLate?.call(value);
  }, onError: (Object _) {});
  return Future.any<T?>([future, cancelled]).whenComplete(() => settled = true);
}
