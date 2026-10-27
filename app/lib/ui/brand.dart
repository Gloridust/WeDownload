import 'package:flutter/material.dart';

const kAppName = 'WeDownload';

/// 应用图标：红色渐变圆角方形，白色向下箭头落进托盘。
/// 改动时同步 tools/icons/logo.svg，再重新生成各平台图标。
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const LogoPainter());
}

class LogoPainter extends CustomPainter {
  const LogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(w * 0.22)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF5A64), Color(0xFFEC2F45)],
        ).createShader(rect),
    );
    // 图形按 0–100 的坐标画
    canvas.save();
    canvas.scale(w / 100);
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w <= 40 ? 10 : 8.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 箭头
    canvas.drawLine(const Offset(50, 22), const Offset(50, 58), stroke);
    canvas.drawPath(
      Path()
        ..moveTo(34, 44)
        ..lineTo(50, 60)
        ..lineTo(66, 44),
      stroke,
    );
    // 托盘
    canvas.drawPath(
      Path()
        ..moveTo(24, 64)
        ..lineTo(24, 76)
        ..lineTo(76, 76)
        ..lineTo(76, 64),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
