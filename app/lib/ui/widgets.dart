import 'package:flutter/material.dart';

import '../src/rust/api/types.dart';
import '../theme.dart';

/// 悬停状态构建器（桌面端大量用到）
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.onTap, this.cursor = SystemMouseCursors.click});

  final Widget Function(BuildContext, bool hovered) builder;
  final VoidCallback? onTap;
  final MouseCursor cursor;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : widget.cursor,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _h),
      ),
    );
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.size = 20, this.color, this.tooltip, this.box = 32});

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double box;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final btn = Hover(
      onTap: onTap,
      builder: (_, h) => Container(
        width: box,
        height: box,
        decoration: BoxDecoration(
          color: h && onTap != null ? (color ?? p.textSecondary).withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(Tokens.radiusS),
        ),
        child: Icon(
          icon,
          size: size,
          color: onTap == null ? p.textTertiary.withValues(alpha: 0.5) : color ?? (h ? p.textPrimary : p.textSecondary),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
    this.height = 36,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  final double height;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onTap != null && !busy;
    return Hover(
      onTap: enabled ? onTap : null,
      builder: (_, h) {
        final fg = primary ? Colors.white : p.textPrimary.withValues(alpha: 0.9);
        return Opacity(
          opacity: onTap == null ? 0.5 : 1,
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: height / 2.2),
            foregroundDecoration: primary && h && enabled
                ? BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(Tokens.radiusM),
                  )
                : null,
            decoration: BoxDecoration(
              color: primary ? null : (h && enabled ? p.hoverStrong : p.field),
              gradient: primary ? Tokens.accentGradient : null,
              borderRadius: BorderRadius.circular(Tokens.radiusM),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    ),
                  )
                else if (icon != null) ...[
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 网络图片：圆角、按平台带 Referer、加载中 / 失败时显示占位
class NetImage extends StatelessWidget {
  const NetImage({
    super.key,
    required this.url,
    required this.platform,
    this.width,
    this.height,
    this.radius = Tokens.radiusM,
    this.icon = Icons.movie_rounded,
    this.fit = BoxFit.cover,
  });

  final String? url;
  final UiPlatform platform;
  final double? width;
  final double? height;
  final double radius;
  final IconData icon;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final placeholder = Container(
      color: p.hover,
      alignment: Alignment.center,
      child: Icon(icon, color: p.textTertiary, size: 28),
    );
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheW = width == null ? null : (width! * dpr).round().clamp(32, 1600);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: url == null || url!.isEmpty
            ? placeholder
            : Image.network(
                url!,
                headers: PlatformStyle.headers(platform),
                fit: fit,
                cacheWidth: cacheW,
                gaplessPlayback: true,
                frameBuilder: (_, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 220),
                        child: child,
                      ),
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// 平台小标签：品牌色圆点 + 名称
class PlatformTag extends StatelessWidget {
  const PlatformTag(this.platform, {super.key, this.dense = false});

  final UiPlatform platform;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = PlatformStyle.of(platform);
    final p = context.palette;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 1 : 3),
      decoration: BoxDecoration(
        color: p.field,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(s.name, style: TextStyle(fontSize: dense ? 11 : 12, color: p.textSecondary)),
        ],
      ),
    );
  }
}

/// 白底卡片
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Tokens.radiusL),
        boxShadow: [BoxShadow(color: p.shadow, blurRadius: 18, offset: const Offset(0, 4))],
      ),
      child: child,
    );
  }
}

/// 页面标题
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.pageGutter, 8, Tokens.pageGutter, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: p.textPrimary)),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(subtitle!, style: TextStyle(fontSize: 13, color: p.textSecondary)),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 空状态
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: p.textTertiary.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: p.textTertiary, fontSize: 14)),
        ],
      ),
    );
  }
}
