import 'dart:typed_data';

class DeviceSize {
  final double width;
  final double height;
  const DeviceSize(this.width, this.height);
}

/// What the UI needs from a device backend (iOS via Appium, Android via adb).
abstract class DeviceClient {
  /// Device coordinate space used by tap/gesture; null until connected.
  DeviceSize? get size;

  /// MJPEG stream to read frames from, or null to poll [screenshot].
  Uri? get mjpegUri;

  Duration get pollInterval;

  /// Opens a continuous stream of MJPEG bytes when the backend can make one (null otherwise).
  Future<Stream<List<int>>?> openFrameStream();
  Future<void> closeFrameStream();

  /// Called with each JPEG the frame source extracts, so the backend can track the real frame size.
  void frameReceived(Uint8List jpeg);

  Future<void> connect();
  Future<void> disconnect();
  Future<Uint8List> screenshot();
  Future<void> tap(double x, double y);
  Future<void> longPress(double x, double y, {double seconds = 1.0});
  Future<void> gesture(List<({double x, double y, int ms})> path);
  Future<void> typeText(String text);
  Future<void> goHome();
  Future<void> goBack();
  Future<void> appSwitcher();
  Future<Map<String, dynamic>?> focusedElementRect();
}
