import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'appium_launcher.dart';
import 'frame_source.dart';
import 'overlay.dart';
import 'recorder.dart';
import 'wda_client.dart';

void main() => runApp(const QaIosPalApp());

class QaIosPalApp extends StatelessWidget {
  const QaIosPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QA iOS Pal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true, brightness: Brightness.dark),
      home: const PalScreen(),
    );
  }
}

class PalScreen extends StatefulWidget {
  const PalScreen({super.key});

  @override
  State<PalScreen> createState() => _PalScreenState();
}

class _PalScreenState extends State<PalScreen> with SingleTickerProviderStateMixin {
  final _url = TextEditingController(text: 'http://127.0.0.1:4723');
  final _udid = TextEditingController(text: '00008120-001C3D8814E3601E');
  final _bundle = TextEditingController();
  final _typed = TextEditingController();
  final _log = <String>[];
  final _markers = <Marker>[];
  late final AnimationController _ticker;

  WdaClient? _client;
  FrameSource? _source;
  Recorder? _recorder;
  final _appium = AppiumLauncher();
  late final AppLifecycleListener _lifecycle;
  Uint8List? _frame;
  final List<({Offset local, int ms})> _touch = [];
  final Stopwatch _touchClock = Stopwatch();
  bool _connecting = false;
  Offset _scrollAcc = Offset.zero;
  Offset _scrollAt = Offset.zero;
  Timer? _scrollTimer;
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        _appium.stop();
        return ui.AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _ticker.dispose();
    _lifecycle.dispose();
    _appium.stop();
    _source?.stop();
    _client?.disconnect();
    super.dispose();
  }

  void _say(String message) {
    if (!mounted) return;
    setState(() {
      final t = DateTime.now().toIso8601String().substring(11, 19);
      _log.insert(0, '$t  $message');
      if (_log.length > 200) _log.removeLast();
    });
  }

  Future<void> _connect() async {
    if (_udid.text.trim().isEmpty) {
      _say('Enter the device UDID first');
      return;
    }
    setState(() => _connecting = true);
    final client = WdaClient(
      baseUrl: _url.text.trim(),
      udid: _udid.text.trim(),
      bundleId: _bundle.text.trim(),
    );
    try {
      await _appium.ensureRunning(_url.text.trim(), _say);
      _say('Creating session (this can take a minute)...');
      await client.connect();
      _client = client;
      _say('Connected ${client.size!.width.toInt()}x${client.size!.height.toInt()} pt');
      _source = FrameSource(
        client: client,
        onStatus: _say,
        onFrame: (frame) {
          if (mounted) setState(() => _frame = frame);
        },
      )..start();
    } catch (e) {
      _say('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    await _stopRecording();
    _source?.stop();
    _source = null;
    await _client?.disconnect();
    _appium.stop();
    setState(() {
      _client = null;
      _frame = null;
    });
    _say('Disconnected');
  }

  Future<void> _startRecording() async {
    try {
      final recorder = await Recorder.start(
        latestFrame: () => _frame,
        paintOverlay: (canvas, size) => paintMarkers(canvas, size, _markers, DateTime.now()),
      );
      setState(() => _recorder = recorder);
      _say('Recording started');
    } catch (e) {
      _say('Record failed: $e');
    }
  }

  Future<void> _stopRecording() async {
    final recorder = _recorder;
    if (recorder == null) return;
    setState(() => _recorder = null);
    _say('Saving recording...');
    try {
      final path = await recorder.stop();
      _say('Recording saved: $path');
    } catch (e) {
      _say('Recording failed: $e');
    }
  }

  void _enqueue(String label, Future<void> Function(WdaClient c) action) {
    final client = _client;
    if (client == null) return;
    _queue = _queue.then((_) async {
      try {
        await action(client);
      } catch (e) {
        _say('$label failed: $e');
      }
    });
  }

  Offset _toDevice(Offset local, Size view) {
    final s = _client!.size!;
    return Offset(local.dx / view.width * s.width, local.dy / view.height * s.height);
  }

  Offset _norm(Offset local, Size view) => Offset(local.dx / view.width, local.dy / view.height);

  void _onTouch(List<({Offset local, int ms})> path, Size view) {
    final start = path.first.local;
    final end = path.last.local;
    final held = path.last.ms;
    if ((end - start).distance <= 12) {
      final p = _toDevice(start, view);
      final isLong = held >= 400;
      setState(() => _markers.add(Marker.tap(_norm(start, view), hold: isLong ? Duration(milliseconds: held) : Duration.zero)));
      if (isLong) {
        _say('long press ${p.dx.round()}, ${p.dy.round()} (${held}ms)');
        _enqueue('long press', (c) => c.longPress(p.dx, p.dy, seconds: held / 1000));
      } else {
        _say('tap ${p.dx.round()}, ${p.dy.round()}');
        _enqueue('tap', (c) => c.tap(p.dx, p.dy));
      }
      return;
    }
    final points = [for (final s in path) (x: _toDevice(s.local, view).dx, y: _toDevice(s.local, view).dy, ms: s.ms)];
    final a = points.first;
    final b = points.last;
    setState(() => _markers.add(Marker.swipe(_norm(start, view), _norm(end, view), hold: Duration(milliseconds: held))));
    _say('swipe ${a.x.round()},${a.y.round()} -> ${b.x.round()},${b.y.round()} (${held}ms)');
    _enqueue('swipe', (c) => c.gesture(points));
  }

  void _scroll(Offset fingerDelta, Offset at, Size view) {
    _scrollAcc += fingerDelta;
    _scrollAt = at;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 90), () {
      final delta = _scrollAcc;
      _scrollAcc = Offset.zero;
      if (delta.distance < 4) return;
      final start = _scrollAt;
      final maxDy = view.height * 0.45;
      final maxDx = view.width * 0.45;
      final end = Offset(
        (start.dx + delta.dx.clamp(-maxDx, maxDx)).clamp(0.0, view.width),
        (start.dy + delta.dy.clamp(-maxDy, maxDy)).clamp(0.0, view.height),
      );
      final a = _toDevice(start, view);
      final b = _toDevice(end, view);
      setState(() => _markers.add(Marker.swipe(_norm(start, view), _norm(end, view))));
      _say('scroll ${a.dy.round()} -> ${b.dy.round()}');
      _enqueue('scroll', (c) => c.gesture([
            (x: a.dx, y: a.dy, ms: 0),
            (x: (a.dx + b.dx) / 2, y: (a.dy + b.dy) / 2, ms: 100),
            (x: b.dx, y: b.dy, ms: 200),
          ]));
    });
  }

  void _sendText() {
    final text = _typed.text;
    if (text.isEmpty) return;
    _typed.clear();
    _say('type "$text"');
    _enqueue('type', (c) async {
      await c.typeText(text);
      unawaited(_markField(c, text));
    });
  }

  Future<void> _markField(WdaClient c, String text) async {
    try {
      final rect = await c.focusedElementRect();
      if (rect != null) {
        final s = c.size!;
        final r = Rect.fromLTWH(
          (rect['x'] as num) / s.width,
          (rect['y'] as num) / s.height,
          (rect['width'] as num) / s.width,
          (rect['height'] as num) / s.height,
        );
        if (mounted) setState(() => _markers.add(Marker.field(r, text)));
      } else if (mounted) {
        setState(() => _markers.add(Marker.label('Typed: $text')));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final connected = _client != null;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 340, child: _panel(connected)),
          const VerticalDivider(width: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final s = _client?.size;
                final aspect = s == null ? 0.46 : s.width / s.height;
                final navH = (box.maxHeight * 0.08).clamp(44.0, 72.0);
                final availH = box.maxHeight - 32 - navH;
                final width = (availH * aspect).clamp(100.0, box.maxWidth - 32);
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(width: width, height: width / aspect, child: _deviceView(connected)),
                      SizedBox(width: width, height: navH, child: _navBar(connected, navH)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(bool connected) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('QA iOS Pal', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          TextField(controller: _url, enabled: !connected, decoration: const InputDecoration(labelText: 'Appium server', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: _udid, enabled: !connected, decoration: const InputDecoration(labelText: 'Device UDID', isDense: true)),
          const SizedBox(height: 8),
          TextField(controller: _bundle, enabled: !connected, decoration: const InputDecoration(labelText: 'Bundle ID (optional)', isDense: true)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _connecting ? null : (connected ? _disconnect : _connect),
                  child: Text(_connecting ? 'Connecting...' : (connected ? 'Disconnect' : 'Connect')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: connected ? (_recorder == null ? _startRecording : _stopRecording) : null,
                  icon: Icon(Icons.fiber_manual_record, color: _recorder == null ? null : Colors.red),
                  label: Text(_recorder == null ? 'Record' : 'Stop'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _typed,
                  enabled: connected,
                  onSubmitted: (_) => _sendText(),
                  decoration: const InputDecoration(labelText: 'Type into focused field', isDense: true),
                ),
              ),
              IconButton(onPressed: connected ? _sendText : null, icon: const Icon(Icons.send)),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(_log[i], style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navBar(bool connected, double height) {
    Widget navButton(IconData icon, String tip, String label, Future<void> Function(WdaClient c) action) {
      return IconButton(
        iconSize: height * 0.5,
        tooltip: tip,
        icon: Icon(icon),
        onPressed: connected
            ? () {
                setState(() => _markers.add(Marker.label(tip.split(' (').first)));
                _enqueue(label, action);
              }
            : null,
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        navButton(Icons.arrow_back_ios_new, 'Back', 'back', (c) => c.goBack()),
        navButton(Icons.circle_outlined, 'Home', 'home', (c) => c.goHome()),
        navButton(Icons.crop_square, 'App switcher', 'app switcher', (c) => c.appSwitcher()),
      ],
    );
  }

  Widget _deviceView(bool connected) {
    final frame = _frame;
    if (!connected || frame == null) {
      return Center(child: Text(connected ? 'Waiting for first frame...' : 'Not connected'));
    }
    return LayoutBuilder(
      builder: (context, box) {
        final view = Size(box.maxWidth, box.maxHeight);
        return Listener(
          onPointerDown: (e) {
            _touch.clear();
            _touchClock
              ..reset()
              ..start();
            _touch.add((local: e.localPosition, ms: 0));
          },
          onPointerMove: (e) {
            if (_touch.isNotEmpty) _touch.add((local: e.localPosition, ms: _touchClock.elapsedMilliseconds));
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) _scroll(-e.scrollDelta, e.localPosition, view);
          },
          onPointerPanZoomUpdate: (e) => _scroll(e.panDelta, e.localPosition, view),
          onPointerUp: (e) {
            if (_touch.isEmpty) return;
            _touch.add((local: e.localPosition, ms: _touchClock.elapsedMilliseconds));
            final path = List.of(_touch);
            _touch.clear();
            _onTouch(path, view);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(frame, gaplessPlayback: true, fit: BoxFit.fill),
              IgnorePointer(
                child: CustomPaint(painter: _OverlayPainter(_markers, _ticker)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OverlayPainter extends CustomPainter {
  final List<Marker> markers;
  _OverlayPainter(this.markers, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now();
    markers.removeWhere((m) => m.expired(now));
    paintMarkers(canvas, size, markers, now);
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
