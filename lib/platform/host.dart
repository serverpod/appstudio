import 'dart:io';

import 'package:path/path.dart' as p;

import 'host_platform.dart';

export 'host_platform.dart';

/// The host this process runs on. Code that needs a decision about the
/// machine takes a [HostPlatform] parameter defaulting to this, so tests can
/// hand it the other one.
///
/// Its [HostPlatform.path] is `package:path`'s own context, so on the machine
/// itself `currentHost.path.join` is exactly `p.join`.
final HostPlatform currentHost = HostPlatform.native(
  HostPlatform.fromOperatingSystem(Platform.operatingSystem).os,
  p.context,
);
