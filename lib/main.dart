import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'adb_client.dart';
import 'android_tools.dart';
import 'apps_dialog.dart';
import 'appium_launcher.dart';
import 'device_client.dart';
import 'frame_source.dart';
import 'overlay.dart';
import 'recorder.dart';
import 'targets.dart';
import 'wda_client.dart';

void main() => runApp(const QaIosPalApp());

class QaIosPalApp extends StatelessWidget {
  const QaIosPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QA Mobile Pal',
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

  DeviceClient? _client;
  FrameSource? _source;
  Recorder? _recorder;
  FrameSource? _recSource;
  Uint8List? _recFrame;
  final _appium = AppiumLauncher();
  late final AppLifecycleListener _lifecycle;
  Uint8List? _frame;
  final List<({Offset local, int ms})> _touch = [];
  final Stopwatch _touchClock = Stopwatch();
  bool _connecting = false;
  List<Target> _targets = [TargetDetector.manualIos];
  Target _target = TargetDetector.manualIos;
  Timer? _detectTimer;
  bool _detecting = false;
  bool? _showTouches;
  bool? _dark;
  Offset _scrollAcc = Offset.zero;
  Offset _scrollAt = Offset.zero;
  Timer? _scrollTimer;
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();
    _refreshTargets();
    _detectTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_client == null && !_connecting) _refreshTargets();
    });
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
    _detectTimer?.cancel();
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

  Future<void> _refreshTargets() async {
    if (_detecting) return;
    _detecting = true;
    try {
      final found = await TargetDetector.detect();
      if (!mounted) return;
      setState(() {
        _targets = found;
        _target = found.firstWhere((t) => t.key == _target.key, orElse: () => found.first);
        if (_target.kind == TargetKind.iosDevice || _target.kind == TargetKind.iosSimulator) _udid.text = _target.id;
      });
    } finally {
      _detecting = false;
    }
  }

  void _selectTarget(Target target) {
    setState(() {
      _target = target;
      if (target.kind == TargetKind.iosDevice || target.kind == TargetKind.iosSimulator) _udid.text = target.id;
    });
  }

  Future<void> _connect() async {
    if (_target.isAndroid) {
      await _connectAndroid();
    } else {
      await _connectIos();
    }
  }

  void _startFrames(DeviceClient client) {
    _client = client;
    _say('Connected ${client.size!.width.toInt()}x${client.size!.height.toInt()}');
    unawaited(_loadToggles(client));
    if (_target.isVirtual) {
      _say('${_target.name} is shown in its own window, so the screen is not streamed here');
      return;
    }
    _source = FrameSource(
      client: client,
      onStatus: _say,
      onFrame: (frame) {
        if (mounted) setState(() => _frame = frame);
      },
    )..start();
  }

  Future<void> _loadToggles(DeviceClient client) async {
    bool? touches;
    bool? dark;
    try {
      touches = await client.showTouches();
    } catch (_) {}
    try {
      dark = await client.darkMode();
    } catch (_) {}
    if (mounted && _client == client) {
      setState(() {
        _showTouches = touches;
        _dark = dark;
      });
    }
  }

  Future<void> _toggleTouches() async {
    final client = _client;
    if (client == null) return;
    final next = !(_showTouches ?? false);
    try {
      await client.setShowTouches(next);
      setState(() => _showTouches = next);
      _say('Show taps on device: ${next ? 'on' : 'off'}');
    } catch (e) {
      _say('Show taps failed: $e');
    }
  }

  Future<void> _toggleTheme() async {
    final client = _client;
    if (client == null) return;
    final next = !(_dark ?? false);
    try {
      await client.setDarkMode(next);
      setState(() => _dark = next);
      _say('Device theme: ${next ? 'dark' : 'light'}');
    } catch (e) {
      _say('Theme change failed: $e');
    }
  }

  Future<void> _bringToFront() async {
    final error = await TargetDetector.bringToFront(_target);
    if (error != null) _say('Bring to front failed: $error');
  }

  Future<void> _connectAndroid() async {
    setState(() => _connecting = true);
    try {
      var target = _target;
      if (target.kind == TargetKind.androidAvd) {
        final serial = await AndroidTools.launchAvd(target.id, _say);
        target = Target(TargetKind.androidEmulator, serial, target.name);
        if (mounted) setState(() => _target = target);
      }
      final client = AdbClient(serial: target.id);
      await client.connect();
      _startFrames(client);
    } catch (e) {
      _say('Connect failed: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
      unawaited(_refreshTargets());
    }
  }

  Future<void> _connectIos() async {
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
      _startFrames(client);
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
      _showTouches = null;
      _dark = null;
    });
    _say('Disconnected');
  }

  Future<void> _startRecording() async {
    try {
      final viaHiddenStream = _target.isVirtual;
      final recorder = await Recorder.start(
        latestFrame: () => viaHiddenStream ? _recFrame : _frame,
        paintOverlay: (canvas, size) => paintMarkers(canvas, size, _markers, DateTime.now()),
      );
      if (viaHiddenStream) {
        // Emulators are not streamed to the UI, so pull frames just for the recording.
        _recFrame = null;
        _recSource = FrameSource(client: _client!, onStatus: _say, onFrame: (frame) => _recFrame = frame);
        unawaited(_recSource!.start());
      }
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
    _recSource?.stop();
    _recSource = null;
    _say('Saving recording...');
    try {
      final path = await recorder.stop();
      _say('Recording saved: $path');
    } catch (e) {
      _say('Recording failed: $e');
    }
  }

  void _enqueue(String label, Future<void> Function(DeviceClient c) action) {
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

  Future<void> _markField(DeviceClient c, String text) async {
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
      body: Stack(
        children: [
          Row(
        children: [
          SizedBox(width: 340, child: _panel(connected)),
          const VerticalDivider(width: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                if (_target.isVirtual) return _virtualPane(connected);
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
          Positioned(top: 8, right: 8, child: _topButtons(connected)),
        ],
      ),
    );
  }

  Widget _topButtons(bool connected) {
    final canTouch = connected && (_client?.supportsShowTouches ?? false);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: canTouch || !connected ? 'Show taps on device: ${_showTouches == true ? 'on' : 'off'}' : 'Not supported on iOS',
          isSelected: _showTouches == true,
          onPressed: canTouch ? _toggleTouches : null,
          icon: const Icon(Icons.touch_app_outlined),
          selectedIcon: const Icon(Icons.touch_app),
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          tooltip: 'Device theme: ${_dark == true ? 'dark' : 'light'} (click to switch)',
          isSelected: _dark == true,
          onPressed: connected ? _toggleTheme : null,
          icon: const Icon(Icons.light_mode),
          selectedIcon: const Icon(Icons.dark_mode),
        ),
      ],
    );
  }

  /// Emulators and simulators are not streamed: they already have their own window.
  Widget _virtualPane(bool connected) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_target.isAndroid ? Icons.android : Icons.phone_iphone, size: 56),
            const SizedBox(height: 12),
            Text(_target.name, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              connected ? 'Control it in its own window.' : 'Connect to use the controls below.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _bringToFront,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Bring to front'),
            ),
            const SizedBox(height: 16),
            SizedBox(width: 280, height: 56, child: _navBar(connected, 56)),
          ],
        ),
      ),
    );
  }

  Widget _panel(bool connected) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('QA Mobile Pal', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('${_target.key}/${_targets.length}'),
                  initialValue: _target.key,
                  decoration: const InputDecoration(labelText: 'Device', isDense: true),
                  items: [
                    for (final t in _targets) DropdownMenuItem(value: t.key, child: Text(t.label, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: connected || _connecting ? null : (v) => _selectTarget(_targets.firstWhere((t) => t.key == v)),
                ),
              ),
              IconButton(tooltip: 'Refresh devices', onPressed: connected ? null : _refreshTargets, icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 12),
          if (_target.isIos) ..._iosFields(connected),
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
                  onPressed: connected && (!_target.isVirtual || _target.isAndroid) ? (_recorder == null ? _startRecording : _stopRecording) : null,
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
          if (_client is AdbClient) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AppsDialog(serial: (_client as AdbClient).serial, say: _say),
              ),
              icon: const Icon(Icons.apps),
              label: const Text('Apps: save / install APK'),
            ),
          ],
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

  List<Widget> _iosFields(bool connected) => [
        TextField(controller: _url, enabled: !connected, decoration: const InputDecoration(labelText: 'Appium server', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: _udid, enabled: !connected, readOnly: _target.kind != TargetKind.iosManual, decoration: const InputDecoration(labelText: 'Device UDID', isDense: true)),
        const SizedBox(height: 8),
        TextField(controller: _bundle, enabled: !connected, decoration: const InputDecoration(labelText: 'Bundle ID (optional)', isDense: true)),
      ];

  Widget _navBar(bool connected, double height) {
    Widget navButton(IconData icon, String tip, String label, Future<void> Function(DeviceClient c) action) {
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
