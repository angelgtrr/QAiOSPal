import 'dart:async';
import 'dart:io';

class AndroidDevice {
  final String serial;
  final String state;
  final String description;
  final bool isEmulator;
  const AndroidDevice(this.serial, this.state, this.description, this.isEmulator);

  String get label => '${isEmulator ? 'Emulator' : 'Device'}: $description';
}

class AndroidTools {
  static String? _adb;
  static String? _emulator;

  static List<String> _sdkRoots() {
    final env = Platform.environment;
    return [
      if (env['ANDROID_HOME'] != null) env['ANDROID_HOME']!,
      if (env['ANDROID_SDK_ROOT'] != null) env['ANDROID_SDK_ROOT']!,
      if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Android\\Sdk',
      if (env['HOME'] != null) '${env['HOME']}/Library/Android/sdk',
      if (env['HOME'] != null) '${env['HOME']}/Android/Sdk',
    ];
  }

  static String? _find(String name, String subDir) {
    final exe = Platform.isWindows ? '$name.exe' : name;
    final sep = Platform.isWindows ? ';' : ':';
    final dirs = [
      ...(Platform.environment['PATH'] ?? '').split(sep),
      for (final root in _sdkRoots()) '$root${Platform.pathSeparator}$subDir',
    ];
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final path = '$dir${Platform.pathSeparator}$exe';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static String adb() {
    final path = _adb ??= _find('adb', 'platform-tools');
    if (path == null) {
      throw Exception('adb not found. Install Android platform-tools and add it to PATH (or set ANDROID_HOME)');
    }
    return path;
  }

  static String? emulatorPath() => _emulator ??= _find('emulator', 'emulator');

  static Future<ProcessResult> runAdb(List<String> args, {String? serial}) =>
      Process.run(adb(), [if (serial != null) ...['-s', serial], ...args]);

  static Future<List<AndroidDevice>> listDevices() async {
    final result = await runAdb(['devices', '-l']);
    final devices = <AndroidDevice>[];
    for (final line in (result.stdout as String).split('\n').skip(1)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final serial = parts[0];
      final state = parts[1];
      final props = {
        for (final p in parts.skip(2).where((p) => p.contains(':'))) p.split(':').first: p.split(':').skip(1).join(':'),
      };
      final name = props['model'] ?? props['device'] ?? serial;
      devices.add(AndroidDevice(serial, state, '${name.replaceAll('_', ' ')} ($serial)', serial.startsWith('emulator-')));
    }
    return devices;
  }

  static Future<List<String>> listAvds() async {
    final path = emulatorPath();
    if (path == null) return [];
    final result = await Process.run(path, ['-list-avds']);
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('INFO'))
        .toList();
  }

  /// Starts an AVD and returns its adb serial once Android has finished booting.
  static Future<String> launchAvd(String avd, void Function(String) say) async {
    final path = emulatorPath();
    if (path == null) throw Exception('Android emulator not found. Install it with the Android SDK (ANDROID_HOME)');
    final running = (await listDevices()).where((d) => d.isEmulator).map((d) => d.serial).toSet();
    var port = 5554;
    while (running.contains('emulator-$port')) {
      port += 2;
    }
    say('Starting emulator $avd...');
    await Process.start(path, ['-avd', avd, '-port', '$port'], mode: ProcessStartMode.detached);
    final serial = 'emulator-$port';
    for (var i = 0; i < 180; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final result = await runAdb(['shell', 'getprop', 'sys.boot_completed'], serial: serial);
      if (result.exitCode == 0 && (result.stdout as String).trim() == '1') return serial;
    }
    throw Exception('Emulator $avd did not finish booting in 3 minutes');
  }
}
