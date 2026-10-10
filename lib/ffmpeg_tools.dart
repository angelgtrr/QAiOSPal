import 'dart:io';

String? findFfmpegBinary() {
  final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final extra = Platform.isWindows ? <String>[] : ['/opt/homebrew/bin', '/usr/local/bin'];
  final separator = Platform.isWindows ? ';' : ':';
  final dirs = [...(Platform.environment['PATH'] ?? '').split(separator), ...extra];
  for (final dir in dirs) {
    if (dir.isEmpty) continue;
    final path = '$dir${Platform.pathSeparator}$name';
    if (File(path).existsSync()) return path;
  }
  return null;
}
