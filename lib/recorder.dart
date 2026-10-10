import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'ffmpeg_tools.dart';

class Recorder {
  final Uint8List? Function() latestFrame;
  final void Function(ui.Canvas canvas, ui.Size size) paintOverlay;
  final String outputPath;
  Process? _ffmpeg;
  Timer? _timer;
  Uint8List? _lastJpeg;
  ui.Image? _image;
  int _width = 0;
  int _height = 0;
  int _count = 0;
  bool _busy = false;
  final StringBuffer _errors = StringBuffer();

  Recorder._(this.latestFrame, this.paintOverlay, this.outputPath);

  static const int _maxWidth = 720;
  static const Duration _interval = Duration(milliseconds: 70);

  int get frameCount => _count;

  static String? findFfmpeg() => findFfmpegBinary();

  static Future<Recorder> start({
    required Uint8List? Function() latestFrame,
    required void Function(ui.Canvas canvas, ui.Size size) paintOverlay,
  }) async {
    if (findFfmpeg() == null) throw Exception('ffmpeg not installed (macOS: brew install ffmpeg, Windows: winget install ffmpeg)');
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '.';
    final dir = Directory('$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}Recordings');
    await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final recorder = Recorder._(latestFrame, paintOverlay, '${dir.path}${Platform.pathSeparator}recording_$stamp.mp4');
    recorder._timer = Timer.periodic(_interval, (_) => recorder._tick());
    return recorder;
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final jpeg = latestFrame();
      if (jpeg == null) return;
      if (!identical(jpeg, _lastJpeg)) {
        final codec = await ui.instantiateImageCodec(jpeg, targetWidth: _width == 0 ? null : _width);
        var image = (await codec.getNextFrame()).image;
        if (_width == 0) {
          final scale = image.width > _maxWidth ? _maxWidth / image.width : 1.0;
          _width = ((image.width * scale) / 2).round() * 2;
          _height = ((image.height * scale) / 2).round() * 2;
          if (image.width != _width) {
            final scaled = await ui.instantiateImageCodec(jpeg, targetWidth: _width);
            image.dispose();
            image = (await scaled.getNextFrame()).image;
          }
        }
        _image?.dispose();
        _image = image;
        _lastJpeg = jpeg;
      }
      final image = _image;
      if (image == null) return;
      if (_ffmpeg == null) await _startFfmpeg();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final size = ui.Size(_width.toDouble(), _height.toDouble());
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, size.width, size.height),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      paintOverlay(canvas, size);
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(_width, _height);
      final data = await rendered.toByteData(format: ui.ImageByteFormat.rawRgba);
      rendered.dispose();
      picture.dispose();
      if (data != null && _ffmpeg != null) {
        _ffmpeg!.stdin.add(data.buffer.asUint8List());
        _count++;
      }
    } catch (e) {
      _errors.writeln(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> _startFfmpeg() async {
    final process = await Process.start(findFfmpeg()!, [
      '-y', '-loglevel', 'error',
      '-use_wallclock_as_timestamps', '1',
      '-f', 'rawvideo', '-pix_fmt', 'rgba', '-video_size', '${_width}x$_height', '-i', '-',
      '-vf', 'fps=15,format=yuv420p',
      '-c:v', 'libx264', '-preset', 'veryfast', '-movflags', '+faststart',
      outputPath,
    ]);
    process.stderr.transform(const SystemEncoding().decoder).listen(_errors.write);
    process.stdout.drain<void>();
    process.stdin.done.catchError((_) {});
    _ffmpeg = process;
  }

  Future<String> stop() async {
    _timer?.cancel();
    while (_busy) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _image?.dispose();
    _image = null;
    final process = _ffmpeg;
    if (process == null) throw Exception('No frames were received from the device');
    try {
      await process.stdin.close();
    } catch (_) {}
    final code = await process.exitCode;
    if (code != 0) {
      final lines = _errors.toString().trim().split('\n');
      throw Exception(lines.isEmpty || lines.last.isEmpty ? 'ffmpeg exited with $code' : lines.last);
    }
    return outputPath;
  }
}
