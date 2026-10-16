import 'dart:io';

import '../platform/host.dart';

String? homeDirectory() => currentHost.homeFrom(Platform.environment);
