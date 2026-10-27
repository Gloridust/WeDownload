import 'package:flutter/material.dart';

import 'src/rust/api/types.dart';

/// 设计规范：颜色、圆角、尺寸集中在这里，页面里不写魔法数。
class Tokens {
  static const accent = Color(0xFFFC3D49);
  static const accentSoft = Color(0x1AFC3D49);

  /// 选中项、主按钮用的红色渐变（右侧偏橙红，左侧偏玫红），与网易云Yet 同一套
  static const accentGradient = LinearGradient(
    begin: Alignment.centerRight,
    end: Alignment.centerLeft,
    colors: [Color(0xFFFC3D49), Color(0xFFFC3D49), Color(0xFFFC3B5B)],
    stops: [0, 0.26, 0.99],
  );

  /// 悬停变化即时生效，只有少数需要过渡的地方用动画
  static const easeInOut = Cubic(0.65, 0, 0.35, 1);

  static const success = Color(0xFF1FB57A);
  static const danger = Color(0xFFF0484E);

  static const radiusS = 6.0;
  static const radiusM = 8.0;
  static const radiusRow = 10.0;
  static const radiusL = 14.0;

  static const pageGutter = 36.0;
  static const sidebarWidth = 228.0;
  static const topBarHeight = 64.0;
  static const statusBarHeight = 72.0;
  static const rowHeight = 64.0;
}

/// 随明暗主题变化的颜色
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.hover,
    required this.hoverStrong,
    required this.rowHover,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.field,
    required this.shadow,
  });

  final Color background;
  final Color sidebar;
  final Color surface;
  final Color hover;
  final Color hoverStrong;

  /// 列表行悬停：浅色主题下是白底卡片
  final Color rowHover;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color divider;
  final Color field;
  final Color shadow;

  // 浅色灰阶都是同一个蓝灰 #283248 叠不同透明度
  static const light = Palette(
    background: Color(0xFFF7F9FC),
    sidebar: Color(0xFFF1F3F7),
    surface: Colors.white,
    hover: Color(0x0F283248),
    hoverStrong: Color(0x1A283248),
    rowHover: Colors.white,
    textPrimary: Color(0xFF283248),
    textSecondary: Color(0x99283248),
    textTertiary: Color(0x80283248),
    divider: Color(0x0F283248),
    field: Color(0x0F283248),
    shadow: Color(0x14283248),
  );

  static const dark = Palette(
    background: Color(0xFF16171C),
    sidebar: Color(0xFF1C1D22),
    surface: Color(0xFF22232A),
    hover: Color(0x12FFFFFF),
    hoverStrong: Color(0x1FFFFFFF),
    rowHover: Color(0x12FFFFFF),
    textPrimary: Color(0xFFE9EAEE),
    textSecondary: Color(0x99FFFFFF),
    textTertiary: Color(0x73FFFFFF),
    divider: Color(0x14FFFFFF),
    field: Color(0x12FFFFFF),
    shadow: Color(0x40000000),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) {
    if (other is! Palette) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      background: l(background, other.background),
      sidebar: l(sidebar, other.sidebar),
      surface: l(surface, other.surface),
      hover: l(hover, other.hover),
      hoverStrong: l(hoverStrong, other.hoverStrong),
      rowHover: l(rowHover, other.rowHover),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      divider: l(divider, other.divider),
      field: l(field, other.field),
      shadow: l(shadow, other.shadow),
    );
  }
}

extension PaletteX on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}

/// Linux 上优先思源黑体（Noto Sans CJK），其他平台回落到系统中文字体
const _fontFallback = [
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'PingFang SC',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'sans-serif',
];

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.light ? Palette.light : Palette.dark;
  final base = ThemeData(
    brightness: b,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: Tokens.accent, brightness: b, primary: Tokens.accent, surface: p.surface),
    scaffoldBackgroundColor: p.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: p.hover,
    dividerColor: p.divider,
    fontFamilyFallback: _fontFallback,
    extensions: [p],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: p.textPrimary, displayColor: p.textPrimary, fontFamilyFallback: _fontFallback),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        color: p.textPrimary.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(Tokens.radiusS),
      ),
      textStyle: TextStyle(color: p.surface, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(p.textTertiary.withValues(alpha: 0.4)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.textPrimary,
      contentTextStyle: TextStyle(color: p.surface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusM)),
      width: 460,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Tokens.accent : null),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
  );
}

/// 平台的品牌色与名称
class PlatformStyle {
  const PlatformStyle(this.name, this.color, this.icon);
  final String name;
  final Color color;
  final IconData icon;

  static PlatformStyle of(UiPlatform p) => switch (p) {
    UiPlatform.douyin => const PlatformStyle('抖音', Color(0xFF1C1E26), Icons.music_note_rounded),
    UiPlatform.tiktok => const PlatformStyle('TikTok', Color(0xFF25F4EE), Icons.music_note_rounded),
    UiPlatform.xiaohongshu => const PlatformStyle('小红书', Color(0xFFFF2442), Icons.menu_book_rounded),
    UiPlatform.instagram => const PlatformStyle('Instagram', Color(0xFFE1306C), Icons.camera_alt_rounded),
    UiPlatform.x => const PlatformStyle('X', Color(0xFF14171A), Icons.close_rounded),
    UiPlatform.bilibili => const PlatformStyle('哔哩哔哩', Color(0xFF00A1D6), Icons.tv_rounded),
    UiPlatform.generic => const PlatformStyle('网页', Color(0xFF8A93A6), Icons.public_rounded),
  };

  /// 各平台图片 CDN 需要的 Referer
  static Map<String, String>? headers(UiPlatform p) => switch (p) {
    UiPlatform.douyin => const {'Referer': 'https://www.douyin.com/'},
    UiPlatform.tiktok => const {'Referer': 'https://www.tiktok.com/'},
    UiPlatform.xiaohongshu => const {'Referer': 'https://www.xiaohongshu.com/'},
    UiPlatform.bilibili => const {'Referer': 'https://www.bilibili.com/'},
    UiPlatform.instagram => const {'Referer': 'https://www.instagram.com/'},
    _ => null,
  };
}

String formatBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i <= 1 ? 0 : 1)} ${units[i]}';
}

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '${m.toString().padLeft(2, '0')}:$sec';
}
