import 'dart:async';
import 'dart:io';

import 'android_tools.dart';

class SavedApk {
  final Directory dir;
  final List<File> files;
  const SavedApk(this.dir, this.files);

  String get name => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
}

/// Pull installed apps off an Android device as APKs and install saved ones elsewhere.
class ApkTools {
  static Directory saveRoot() {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';
    return Directory('$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}Apks');
  }

  static Future<List<String>> listPackages(String serial, {bool includeSystem = false}) async {
    final result = await AndroidTools.runAdb(['shell', 'pm', 'list', 'packages', if (!includeSystem) '-3'], serial: serial);
    if (result.exitCode != 0) throw Exception('${result.stderr}${result.stdout}'.trim());
    final packages = (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8))
        .toList()
      ..sort();
    return packages;
  }

  /// Saves every APK of [package] (base plus splits) and returns the folder.
  static Future<SavedApk> save(String serial, String package) async {
    final paths = await AndroidTools.runAdb(['shell', 'pm', 'path', package], serial: serial);
    final remote = (paths.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8))
        .toList();
    if (remote.isEmpty) throw Exception('No APK found for $package');

    final dump = await AndroidTools.runAdb(['shell', 'dumpsys', 'package', package], serial: serial);
    final version = RegExp(r'versionName=(\S+)').firstMatch(dump.stdout as String)?.group(1);
    final folder = '$package${version == null ? '' : '_$version'}'.replaceAll(RegExp(r'[^\w.\-]'), '_');
    final dir = Directory('${saveRoot().path}${Platform.pathSeparator}$folder');
    await dir.create(recursive: true);

    final files = <File>[];
    for (final path in remote) {
      final name = path.split('/').last;
      final target = '${dir.path}${Platform.pathSeparator}$name';
      final pulled = await AndroidTools.runAdb(['pull', path, target], serial: serial);
      if (pulled.exitCode != 0) throw Exception('Pull failed for $name: ${pulled.stderr}${pulled.stdout}'.trim());
      files.add(File(target));
    }
    return SavedApk(dir, files);
  }

  static Future<List<SavedApk>> listSaved() async {
    final root = saveRoot();
    if (!await root.exists()) return [];
    final saved = <SavedApk>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final files = await entity.list().where((e) => e is File && e.path.toLowerCase().endsWith('.apk')).cast<File>().toList();
      if (files.isNotEmpty) saved.add(SavedApk(entity, files..sort((a, b) => a.path.compareTo(b.path))));
    }
    saved.sort((a, b) => a.name.compareTo(b.name));
    return saved;
  }

  static Future<void> install(String serial, SavedApk apk) async {
    final result = await AndroidTools.runAdb([
      'install-multiple',
      '-r',
      '-d',
      ...apk.files.map((f) => f.path),
    ], serial: serial);
    final output = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0 || !output.contains('Success')) {
      throw Exception(output.isEmpty ? 'install failed' : output.split('\n').last);
    }
  }
}
