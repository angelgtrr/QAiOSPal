import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MarkerKind { tap, swipe, field, label }

class Marker {
  final MarkerKind kind;
  final Offset from;
  final Offset? to;
  final Rect? rect;
  final String? text;
  final DateTime created = DateTime.now();
  final Duration life;
  final Duration hold;

  Marker.tap(this.from, {this.hold = Duration.zero})
      : kind = MarkerKind.tap,
        to = null,
        rect = null,
        text = null,
        life = const Duration(milliseconds: 450) + hold;

  Marker.swipe(this.from, Offset this.to, {this.hold = Duration.zero})
      : kind = MarkerKind.swipe,
        rect = null,
        text = null,
        life = const Duration(milliseconds: 1000) + hold;

  Marker.field(Rect this.rect, String this.text)
      : kind = MarkerKind.field,
        from = Offset.zero,
        to = null,
        hold = Duration.zero,
        life = const Duration(milliseconds: 1000);

  Marker.label(String this.text)
      : kind = MarkerKind.label,
        from = Offset.zero,
        to = null,
        rect = null,
        hold = Duration.zero,
        life = const Duration(milliseconds: 1400);

  bool expired(DateTime now) => now.difference(created) > life;
}

void paintMarkers(Canvas canvas, Size size, List<Marker> markers, DateTime now) {
  for (final m in markers) {
    final age = now.difference(m.created).inMilliseconds;
    final remaining = m.life.inMilliseconds - age;
    if (remaining <= 0) continue;
    final fade = remaining < 200 ? remaining / 200 : 1.0;
    switch (m.kind) {
      case MarkerKind.tap:
        _paintTap(canvas, size, m, age, fade);
      case MarkerKind.swipe:
        _paintSwipe(canvas, size, m, age, fade);
      case MarkerKind.field:
        _paintField(canvas, size, m, fade);
      case MarkerKind.label:
        _paintPill(canvas, size, m.text!, Offset(size.width / 2, size.height * 0.9), fade, Colors.blueGrey);
    }
  }
}

void _paintTap(Canvas canvas, Size size, Marker m, int age, double fade) {
  final c = Offset(m.from.dx * size.width, m.from.dy * size.height);
  final radius = size.width * 0.025;
  canvas.drawCircle(c, radius, Paint()..color = Colors.redAccent.withValues(alpha: 0.75 * fade));
}

void _paintSwipe(Canvas canvas, Size size, Marker m, int age, double fade) {
  final a = Offset(m.from.dx * size.width, m.from.dy * size.height);
  final b = Offset(m.to!.dx * size.width, m.to!.dy * size.height);
  final travel = math.max(250, m.hold.inMilliseconds);
  final p = (age / travel).clamp(0.0, 1.0);
  final head = Offset.lerp(a, b, Curves.easeOut.transform(p))!;
  final base = size.width * 0.04;
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(3, base * 0.4)
    ..strokeCap = StrokeCap.round
    ..color = Colors.orangeAccent.withValues(alpha: 0.85 * fade);
  canvas.drawCircle(a, base * 0.5, Paint()..color = Colors.orangeAccent.withValues(alpha: 0.5 * fade));
  canvas.drawLine(a, head, line);
  canvas.drawCircle(head, base * 0.9, Paint()..color = Colors.orangeAccent.withValues(alpha: 0.9 * fade));
  canvas.drawCircle(
    head,
    base * 1.4,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.orangeAccent.withValues(alpha: 0.6 * fade),
  );
}

void _paintField(Canvas canvas, Size size, Marker m, double fade) {
  final r = Rect.fromLTWH(m.rect!.left * size.width, m.rect!.top * size.height, m.rect!.width * size.width,
      m.rect!.height * size.height);
  canvas.drawRRect(
    RRect.fromRectAndRadius(r.inflate(4), const Radius.circular(8)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.greenAccent.withValues(alpha: fade),
  );
  final y = r.top - 22 < 20 ? r.bottom + 24 : r.top - 22;
  _paintPill(canvas, size, 'Typed: ${m.text}', Offset(r.center.dx.clamp(size.width * 0.2, size.width * 0.8), y), fade,
      Colors.green.shade700);
}

void _paintPill(Canvas canvas, Size size, String text, Offset center, double fade, Color color) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: Colors.white.withValues(alpha: fade), fontSize: size.width * 0.04, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '...',
  )..layout(maxWidth: size.width * 0.8);
  final box = Rect.fromCenter(center: center, width: painter.width + 24, height: painter.height + 12);
  canvas.drawRRect(
    RRect.fromRectAndRadius(box, Radius.circular(box.height / 2)),
    Paint()..color = color.withValues(alpha: 0.9 * fade),
  );
  painter.paint(canvas, Offset(box.left + 12, box.top + 6));
}
