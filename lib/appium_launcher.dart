import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class AppiumLauncher {
  Process? _process;
  final List<String> _output = [];

  static Future<bool> isUp(String baseUrl) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/status')).timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureRunning(String baseUrl, void Function(String) say) async {
    if (await isUp(baseUrl)) {
      say('Appium is already running');
      return;
    }
    final uri = Uri.parse(baseUrl);
    if (uri.host != '127.0.0.1' && uri.host != 'localhost') {
      throw Exception('Appium is not reachable at $baseUrl');
    }
    say('Appium is not running, starting it...');
    _output.clear();
    var exited = false;
    final process = await Process.start('/bin/zsh', ['-l', '-i', '-c', 'exec appium --port ${uri.port}']);
    _process = process;
    void collect(String line) {
      _output.add(line);
      if (_output.length > 20) _output.removeAt(0);
    }

    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(collect);
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(collect);
    unawaited(process.exitCode.then((_) {
      exited = true;
      _process = null;
    }));
    for (var i = 0; i < 120; i++) {
      if (await isUp(baseUrl)) {
        say('Appium started');
        return;
      }
      if (exited) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final tail = _output.isEmpty ? 'no output' : _output.last;
    stop();
    throw Exception('Could not start Appium ($tail). Is it installed? npm i -g appium');
  }

  void stop() {
    _process?.kill();
    _process = null;
  }
}
