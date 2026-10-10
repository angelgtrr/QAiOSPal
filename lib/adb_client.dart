import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'android_tools.dart';
import 'device_client.dart';
import 'ffmpeg_tools.dart';

/// Android backend: screenshots and input through adb (real devices and emulators).
class AdbClient implements DeviceClient {
  final String serial;
  @override
  DeviceSize? size;

  AdbClient({required this.serial});

  @override
  Uri? get mjpegUri => null;

  @override
  Duration get pollInterval => Duration.zero;

  @override
  Future<void> connect() async {
    final state = await AndroidTools.runAdb(['get-state'], serial: serial);
    if (state.exitCode != 0 || (state.stdout as String).trim() != 'device') {
      final detail = '${state.stderr}${state.stdout}'.trim();
      throw Exception('Device $serial is not ready${detail.isEmpty ? '' : ': $detail'}');
    }
    await screenshot();
  }

  @override
  Future<void> disconnect() => closeFrameStream();

  Process? _adbStream;
  Process? _ffmpegStream;

  /// screenrecord (h264) piped through ffmpeg into MJPEG, which is much faster than polling screencap.
  @override
  Future<Stream<List<int>>?> openFrameStream() async {
    await closeFrameStream();
    final ffmpeg = findFfmpegBinary();
    if (ffmpeg == null) throw Exception('ffmpeg not found (needed for the fast stream)');
    final adb = await Process.start(AndroidTools.adb(), [
      '-s', serial, 'exec-out', 'screenrecord', '--output-format=h264', '--bit-rate', '8000000', '-',
    ]);
    final enc = await Process.start(ffmpeg, [
      '-loglevel', 'error',
      '-flags', 'low_delay', '-probesize', '32', '-analyzeduration', '0',
      '-f', 'h264', '-i', '-',
      '-vf', 'scale=720:-2,format=yuvj420p',
      '-flush_packets', '1', '-f', 'image2pipe', '-c:v', 'mjpeg', '-q:v', '7', '-',
    ]);
    _adbStream = adb;
    _ffmpegStream = enc;
    adb.stderr.drain<void>();
    enc.stderr.drain<void>();
    adb.stdout.pipe(enc.stdin).catchError((_) {});
    return enc.stdout;
  }

  @override
  Future<void> closeFrameStream() async {
    _adbStream?.kill();
    _ffmpegStream?.kill();
    _adbStream = null;
    _ffmpegStream = null;
  }

  /// Keeps [size] pointing the right way when the device rotates (the stream is scaled, so only the ratio matters).
  @override
  void frameReceived(Uint8List jpeg) {
    final current = size;
    if (current == null) return;
    for (var i = 2; i + 9 < jpeg.length;) {
      if (jpeg[i] != 0xFF) return;
      final marker = jpeg[i + 1];
      if (marker >= 0xC0 && marker <= 0xC2) {
        final h = (jpeg[i + 5] << 8) | jpeg[i + 6];
        final w = (jpeg[i + 7] << 8) | jpeg[i + 8];
        if ((w > h) != (current.width > current.height)) size = DeviceSize(current.height, current.width);
        return;
      }
      i += 2 + ((jpeg[i + 2] << 8) | jpeg[i + 3]);
    }
  }

  @override
  Future<Uint8List> screenshot() async {
    final result = await Process.run(
      AndroidTools.adb(),
      ['-s', serial, 'exec-out', 'screencap', '-p'],
      stdoutEncoding: null,
    );
    final bytes = result.stdout as List<int>;
    if (result.exitCode != 0 || bytes.length < 24 || bytes[1] != 0x50) {
      throw Exception('screencap failed: ${result.stderr}');
    }
    final data = Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);
    final w = view.getUint32(16).toDouble();
    final h = view.getUint32(20).toDouble();
    if (size == null || size!.width != w || size!.height != h) size = DeviceSize(w, h);
    return data;
  }

  Future<void> _shell(String command) async {
    final result = await AndroidTools.runAdb(['shell', command], serial: serial);
    if (result.exitCode != 0) throw Exception('${result.stderr}${result.stdout}'.trim());
  }

  @override
  Future<void> tap(double x, double y) => _shell('input tap ${x.round()} ${y.round()}');

  @override
  Future<void> longPress(double x, double y, {double seconds = 1.0}) =>
      _shell('input swipe ${x.round()} ${y.round()} ${x.round()} ${y.round()} ${(seconds * 1000).round()}');

  /// adb can only do straight swipes, so the path is reduced to its first and last point.
  @override
  Future<void> gesture(List<({double x, double y, int ms})> path) {
    final a = path.first;
    final b = path.last;
    final ms = (b.ms - a.ms).clamp(50, 5000);
    return _shell('input swipe ${a.x.round()} ${a.y.round()} ${b.x.round()} ${b.y.round()} $ms');
  }

  @override
  Future<void> typeText(String text) {
    if (text.runes.any((r) => r > 126 || r < 32)) {
      throw Exception('adb can only type plain ASCII text');
    }
    final escaped = text.replaceAll('%', '%25').replaceAll(' ', '%s').replaceAll("'", "'\\''");
    return _shell("input text '$escaped'");
  }

  @override
  Future<void> goHome() => _shell('input keyevent KEYCODE_HOME');

  @override
  Future<void> goBack() => _shell('input keyevent KEYCODE_BACK');

  @override
  Future<void> appSwitcher() => _shell('input keyevent KEYCODE_APP_SWITCH');

  @override
  Future<Map<String, dynamic>?> focusedElementRect() async => null;
}
