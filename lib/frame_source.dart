import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'wda_client.dart';

class FrameSource {
  final WdaClient client;
  final void Function(Uint8List frame) onFrame;
  final void Function(String message) onStatus;
  bool _running = false;
  HttpClient? _http;

  FrameSource({required this.client, required this.onFrame, required this.onStatus});

  Future<void> start() async {
    _running = true;
    final gotMjpeg = await _runMjpeg();
    if (_running && !gotMjpeg) {
      onStatus('MJPEG stream unavailable, polling screenshots');
      await _runPolling();
    }
  }

  void stop() {
    _running = false;
    _http?.close(force: true);
    _http = null;
  }

  Future<bool> _runMjpeg() async {
    var received = false;
    try {
      _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await _http!.getUrl(Uri.parse('http://127.0.0.1:${client.mjpegPort}'));
      final response = await request.close().timeout(const Duration(seconds: 5));
      var buffer = BytesBuilder(copy: false);
      var bytes = Uint8List(0);
      await for (final chunk in response) {
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
          onFrame(Uint8List.fromList(Uint8List.sublistView(bytes, start, end + 2)));
          bytes = Uint8List.sublistView(bytes, end + 2);
        }
      }
      buffer.clear();
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
      final wait = const Duration(milliseconds: 200) - elapsed;
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
