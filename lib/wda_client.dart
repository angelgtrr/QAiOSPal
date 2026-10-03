import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class DeviceSize {
  final double width;
  final double height;
  const DeviceSize(this.width, this.height);
}

class WdaClient {
  final String baseUrl;
  final String udid;
  final String bundleId;
  final int mjpegPort;
  String? sessionId;
  DeviceSize? size;

  WdaClient({
    required this.baseUrl,
    required this.udid,
    this.bundleId = '',
    this.mjpegPort = 9100,
  });

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final request = http.Request(method, _uri(path));
    request.headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamed);
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode >= 400) {
      final value = decoded is Map ? decoded['value'] : null;
      final message = value is Map ? value['message'] : response.body;
      throw Exception('$method $path failed: $message');
    }
    return decoded is Map ? decoded['value'] : decoded;
  }

  Future<void> connect() async {
    final alwaysMatch = <String, dynamic>{
      'platformName': 'iOS',
      'appium:automationName': 'XCUITest',
      'appium:udid': udid,
      'appium:mjpegServerPort': mjpegPort,
      'appium:noReset': true,
      'appium:newCommandTimeout': 0,
      'appium:shouldTerminateApp': false,
      'appium:forceAppLaunch': false,
      'appium:waitForQuiescence': false,
      'appium:waitForIdleTimeout': 0,
      'appium:animationCoolOffTimeout': 0,
      'appium:mjpegServerFramerate': 30,
    };
    if (bundleId.isNotEmpty) alwaysMatch['appium:bundleId'] = bundleId;
    final value = await _send('POST', '/session', {
      'capabilities': {'alwaysMatch': alwaysMatch},
    });
    sessionId = value['sessionId'] as String;
    try {
      await _send('POST', '/session/$sessionId/appium/settings', {
        'settings': {'waitForIdleTimeout': 0, 'animationCoolOffTimeout': 0},
      });
    } catch (_) {}
    final rect = await _send('GET', '/session/$sessionId/window/rect');
    size = DeviceSize((rect['width'] as num).toDouble(), (rect['height'] as num).toDouble());
  }

  Future<void> disconnect() async {
    final id = sessionId;
    sessionId = null;
    if (id == null) return;
    try {
      await _send('DELETE', '/session/$id');
    } catch (_) {}
  }

  Future<Uint8List> screenshot() async {
    final value = await _send('GET', '/session/$sessionId/screenshot');
    return base64Decode(value as String);
  }

  Future<void> tap(double x, double y) => _script('mobile: tap', {'x': x, 'y': y});

  Future<void> doubleTap(double x, double y) => _script('mobile: doubleTap', {'x': x, 'y': y});

  Future<void> longPress(double x, double y, {double seconds = 1.0}) =>
      _script('mobile: touchAndHold', {'x': x, 'y': y, 'duration': seconds});

  Future<void> swipe(double x1, double y1, double x2, double y2, {double seconds = 0.15}) =>
      _script('mobile: dragFromToForDuration', {
        'fromX': x1,
        'fromY': y1,
        'toX': x2,
        'toY': y2,
        'duration': seconds,
      });

  Future<void> typeText(String text) async {
    final errors = <String>[];
    try {
      await _script('mobile: keys', {'keys': text.split('')});
      return;
    } catch (e) {
      errors.add('keys: $e');
    }
    try {
      final active = await _send('GET', '/session/$sessionId/element/active');
      final id = (active as Map).values.first as String;
      await _send('POST', '/session/$sessionId/element/$id/value', {'text': text, 'value': text.split('')});
      return;
    } catch (e) {
      errors.add('element: $e');
    }
    try {
      await _send('POST', '/session/$sessionId/wda/keys', {'value': text.split('')});
      return;
    } catch (e) {
      errors.add('wda: $e');
    }
    throw Exception(errors.join(' | '));
  }

  Future<void> gesture(List<({double x, double y, int ms})> path) async {
    final actions = <Map<String, dynamic>>[
      {'type': 'pointerMove', 'duration': 0, 'x': path.first.x.round(), 'y': path.first.y.round()},
      {'type': 'pointerDown', 'button': 0},
    ];
    for (var i = 1; i < path.length; i++) {
      actions.add({
        'type': 'pointerMove',
        'duration': (path[i].ms - path[i - 1].ms).clamp(0, 5000),
        'x': path[i].x.round(),
        'y': path[i].y.round(),
      });
    }
    actions.add({'type': 'pointerUp', 'button': 0});
    await _send('POST', '/session/$sessionId/actions', {
      'actions': [
        {
          'type': 'pointer',
          'id': 'finger',
          'parameters': {'pointerType': 'touch'},
          'actions': actions,
        },
      ],
    });
    try {
      await _send('DELETE', '/session/$sessionId/actions');
    } catch (_) {}
  }

  Future<void> appSwitcher() {
    final w = size!.width / 2;
    final h = size!.height;
    return gesture([
      (x: w, y: h - 2, ms: 0),
      (x: w, y: h * 0.55, ms: 250),
      (x: w, y: h * 0.55, ms: 500),
    ]);
  }

  Future<void> goHome() async {
    try {
      await _script('mobile: activateApp', {'bundleId': 'com.apple.springboard'});
    } catch (_) {
      await swipe(size!.width / 2, size!.height - 2, size!.width / 2, size!.height * 0.6, seconds: 0.1);
    }
  }

  Future<void> goBack() =>
      swipe(2, size!.height / 2, size!.width * 0.7, size!.height / 2, seconds: 0.2);

  Future<void> pressButton(String name) => _script('mobile: pressButton', {'name': name});

  Future<Map<String, dynamic>?> focusedElementRect() async {
    try {
      final active = await _send('GET', '/session/$sessionId/element/active');
      final id = (active as Map).values.first as String;
      final rect = await _send('GET', '/session/$sessionId/element/$id/rect');
      return Map<String, dynamic>.from(rect as Map);
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _script(String script, Map<String, dynamic> args) =>
      _send('POST', '/session/$sessionId/execute/sync', {
        'script': script,
        'args': [args],
      });
}
