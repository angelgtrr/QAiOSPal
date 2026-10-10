import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'device_client.dart';

class FrameSource {
  final DeviceClient client;
  final void Function(Uint8List frame) onFrame;
  final void Function(String message) onStatus;
  bool _running = false;
  HttpClient? _http;

  FrameSource({required this.client, required this.onFrame, required this.onStatus});

  Future<void> start() async {
    _running = true;
    final gotMjpeg = client.mjpegUri != null ? await _runMjpeg() : await _runStream();
    if (_running && !gotMjpeg) {
      onStatus('Video stream unavailable, polling screenshots');
      await _runPolling();
    }
  }

  void stop() {
    _running = false;
    _http?.close(force: true);
    _http = null;
    client.closeFrameStream();
  }

  Future<bool> _runMjpeg() async {
    try {
      _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await _http!.getUrl(client.mjpegUri!);
      final response = await request.close().timeout(const Duration(seconds: 5));
      return await _consume(response);
    } catch (_) {
      return false;
    }
  }

  /// Streams from the backend (adb screenrecord). screenrecord stops after 3 minutes, so reopen while it keeps producing frames.
  Future<bool> _runStream() async {
    var received = false;
    while (_running) {
      Stream<List<int>>? stream;
      try {
        stream = await client.openFrameStream();
      } catch (e) {
        onStatus('Video stream unavailable: $e');
        break;
      }
      if (stream == null) break;
      final got = await _consume(stream);
      await client.closeFrameStream();
      if (!got) break;
      received = true;
    }
    return received;
  }

  Future<bool> _consume(Stream<List<int>> stream) async {
    var received = false;
    var bytes = Uint8List(0);
    try {
      await for (final chunk in stream) {
        if (!_running) break;
        final merged = Uint8List(bytes.length + chunk.length)
          ..setRange(0, bytes.length, bytes)
          ..setRange(bytes.length, bytes.length + chunk.length, chunk);
        bytes = merged;
        while (true) {
          final start = _indexOf(bytes, 0xFF, 0xD8, 0);
          if (start < 0) {
            bytes = Uint8List(0);
            break;
          }
          final end = _indexOf(bytes, 0xFF, 0xD9, start + 2);
          if (end < 0) {
            if (start > 0) bytes = Uint8List.sublistView(bytes, start);
            break;
          }
          received = true;
          final frame = Uint8List.fromList(Uint8List.sublistView(bytes, start, end + 2));
          client.frameReceived(frame);
          onFrame(frame);
          bytes = Uint8List.sublistView(bytes, end + 2);
        }
      }
    } catch (_) {}
    return received;
  }

  Future<void> _runPolling() async {
    while (_running) {
      final started = DateTime.now();
      try {
        onFrame(await client.screenshot());
      } catch (_) {}
      final elapsed = DateTime.now().difference(started);
      final wait = client.pollInterval - elapsed;
      if (wait > Duration.zero) await Future.delayed(wait);
    }
  }

  int _indexOf(Uint8List data, int a, int b, int from) {
    for (var i = from; i < data.length - 1; i++) {
      if (data[i] == a && data[i + 1] == b) return i;
    }
    return -1;
  }
}
