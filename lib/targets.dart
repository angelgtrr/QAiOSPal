import 'dart:convert';
import 'dart:io';

import 'android_tools.dart';

enum TargetKind { androidDevice, androidEmulator, androidAvd, iosDevice, iosSimulator, iosManual }

/// Something the user can pick in the device dropdown.
class Target {
  final TargetKind kind;
  final String id;
  final String name;
  const Target(this.kind, this.id, this.name);

  String get key => '${kind.name}:$id';
  bool get isAndroid => kind == TargetKind.androidDevice || kind == TargetKind.androidEmulator || kind == TargetKind.androidAvd;
  bool get isIos => !isAndroid;

  /// Emulators and simulators already show up in their own window, so the app does not stream them.
  bool get isVirtual => kind == TargetKind.androidEmulator || kind == TargetKind.androidAvd || kind == TargetKind.iosSimulator;

  String get label => switch (kind) {
        TargetKind.androidDevice => 'Android device: $name',
        TargetKind.androidEmulator => 'Android emulator: $name',
        TargetKind.androidAvd => 'Start Android emulator: $name',
        TargetKind.iosDevice => 'iOS device: $name',
        TargetKind.iosSimulator => 'iOS simulator: $name',
        TargetKind.iosManual => name,
      };
}

class TargetDetector {
  static const manualIos = Target(TargetKind.iosManual, '', 'iOS device (enter UDID / remote Appium)');

  static Future<List<Target>> detect() async {
    final targets = <Target>[];
    try {
      final runningAvds = <String>{};
      for (final d in await AndroidTools.listDevices()) {
        if (d.state != 'device') continue;
        if (d.isEmulator) {
          final avd = await AndroidTools.avdName(d.serial);
          if (avd != null) runningAvds.add(avd);
          targets.add(Target(TargetKind.androidEmulator, d.serial, avd ?? d.description));
        } else {
          targets.add(Target(TargetKind.androidDevice, d.serial, d.description));
        }
      }
      for (final avd in await AndroidTools.listAvds()) {
        if (!runningAvds.contains(avd)) targets.add(Target(TargetKind.androidAvd, avd, avd));
      }
    } catch (_) {}
    if (Platform.isMacOS) targets.addAll(await _detectIos());
    targets.add(manualIos);
    return targets;
  }

  static Future<List<Target>> _detectIos() async {
    final targets = <Target>[];
    try {
      final devices = await Process.run('xcrun', ['xctrace', 'list', 'devices']);
      final udid = RegExp(r'^(.*) \(([^()]+)\) \(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})\)\s*$');
      for (final line in (devices.stdout as String).split('\n')) {
        if (line.startsWith('== Simulators')) break;
        final m = udid.firstMatch(line.trim());
        if (m != null) targets.add(Target(TargetKind.iosDevice, m.group(3)!, '${m.group(1)} (iOS ${m.group(2)})'));
      }
    } catch (_) {}
    try {
      final sims = await Process.run('xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
      final json = jsonDecode(sims.stdout as String) as Map<String, dynamic>;
      for (final list in (json['devices'] as Map<String, dynamic>).values) {
        for (final d in list as List) {
          if (d['state'] == 'Booted') targets.add(Target(TargetKind.iosSimulator, d['udid'] as String, d['name'] as String));
        }
      }
    } catch (_) {}
    return targets;
  }

  /// Brings the emulator / simulator window to the front. Returns an error message, or null on success.
  static Future<String?> bringToFront(Target target) async {
    try {
      if (target.kind == TargetKind.iosSimulator) {
        await Process.run('open', ['-a', 'Simulator']);
        return null;
      }
      final port = RegExp(r'emulator-(\d+)').firstMatch(target.id)?.group(1);
      if (Platform.isWindows) {
        final script = '''
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class Win { [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int c); }'
\$p = Get-Process | Where-Object { \$_.MainWindowTitle -like "*Android Emulator*${port ?? ''}*" } | Select-Object -First 1
if (-not \$p) { exit 3 }
[Win]::ShowWindowAsync(\$p.MainWindowHandle, 9) | Out-Null
(New-Object -ComObject WScript.Shell).AppActivate(\$p.Id) | Out-Null
''';
        final encoded = base64.encode([for (final unit in script.codeUnits) ...[unit & 0xFF, unit >> 8]]);
        final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded]);
        if (result.exitCode == 3) return 'Emulator window not found (is it embedded in Android Studio?)';
        return result.exitCode == 0 ? null : '${result.stderr}'.trim();
      }
      if (Platform.isMacOS) {
        final result = await Process.run('osascript', [
          '-e',
          'tell application "System Events" to set frontmost of (first process whose name contains "qemu-system") to true',
        ]);
        return result.exitCode == 0 ? null : 'Emulator window not found';
      }
      final result = await Process.run('wmctrl', ['-a', 'Android Emulator']);
      return result.exitCode == 0 ? null : 'Could not focus the emulator window (needs wmctrl)';
    } catch (e) {
      return '$e';
    }
  }
}
