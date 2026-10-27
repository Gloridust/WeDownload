import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../src/rust/api/types.dart';
import '../state.dart';
import '../theme.dart';
import 'brand.dart';
import 'pages/downloads_page.dart';
import 'pages/parse_page.dart';
import 'pages/settings_page.dart';
import 'widgets.dart';

bool get isDesktop => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WindowListener {
  final _scaffold = GlobalKey<ScaffoldState>();
  bool _edgeToEdge = false;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      _syncWindowState();
    }
    AppState.I.notices.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
    });
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncWindowState() async {
    final edge = await windowManager.isMaximized() || await windowManager.isFullScreen();
    if (mounted && edge != _edgeToEdge) setState(() => _edgeToEdge = edge);
  }

  @override
  void onWindowMaximize() => _syncWindowState();
  @override
  void onWindowUnmaximize() => _syncWindowState();
  @override
  void onWindowFocus() => AppState.I.checkClipboard();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < 720;
        final borderColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.14)
            : p.textTertiary.withValues(alpha: 0.45);
        return Scaffold(
          key: _scaffold,
          backgroundColor: p.background,
          drawer: compact ? Drawer(width: 240, backgroundColor: p.sidebar, child: const Sidebar()) : null,
          body: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact) ...[
                    const SizedBox(width: Tokens.sidebarWidth, child: Sidebar()),
                    VerticalDivider(width: 1, color: p.divider),
                  ],
                  Expanded(
                    child: Column(
                      children: [
                        TopBar(onMenu: compact ? () => _scaffold.currentState?.openDrawer() : null),
                        Expanded(
                          child: ValueListenableBuilder(
                            valueListenable: AppState.I.page,
                            builder: (context, page, _) => AnimatedSwitcher(
                              duration: const Duration(milliseconds: 160),
                              child: KeyedSubtree(
                                key: ValueKey(page),
                                child: switch (page) {
                                  'downloading' => const DownloadsPage(finished: false),
                                  'finished' => const DownloadsPage(finished: true),
                                  'settings' => const SettingsPage(),
                                  _ => const ParsePage(),
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // 无边框窗口在 Linux 上加一圈细描边，避免和相邻白色窗口糊在一起
              if (Platform.isLinux && !_edgeToEdge)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: borderColor))),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 标题栏区域可拖动窗口、双击最大化（仅桌面端）
class DragArea extends StatelessWidget {
  const DragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async =>
          await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize(),
      child: child,
    );
  }
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, this.onMenu});

  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DragArea(
      child: SizedBox(
        height: Tokens.topBarHeight,
        child: Row(
          children: [
            const SizedBox(width: 16),
            if (onMenu != null) IconBtn(Icons.menu_rounded, onTap: onMenu),
            const Spacer(),
            if (isDesktop && !Platform.isMacOS) ...[
              Container(width: 1, height: 18, margin: const EdgeInsets.symmetric(horizontal: 10), color: p.divider),
              IconBtn(Icons.remove_rounded, onTap: windowManager.minimize, tooltip: '最小化'),
              IconBtn(
                Icons.crop_square_rounded,
                size: 18,
                tooltip: '最大化',
                onTap: () async =>
                    await windowManager.isMaximized() ? windowManager.unmaximize() : windowManager.maximize(),
              ),
              IconBtn(Icons.close_rounded, onTap: windowManager.close, tooltip: '关闭'),
            ],
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DragArea(
            child: SizedBox(
              height: Tokens.topBarHeight + 8,
              child: Row(
                children: [
                  SizedBox(width: Platform.isMacOS ? 80 : 22),
                  const AppLogo(size: 28),
                  const SizedBox(width: 10),
                  Text(kAppName, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: p.textPrimary)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: AppState.I.tasks,
              builder: (context, tasks, _) {
                final active = tasks
                    .where((t) => t.status == UiTaskStatus.running || t.status == UiTaskStatus.queued)
                    .length;
                final failed = tasks.where((t) => t.status == UiTaskStatus.failed).length;
                final done = tasks.where((t) => t.status == UiTaskStatus.done).length;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  children: [
                    const NavItem(icon: Icons.link_rounded, label: '解析下载', page: 'parse'),
                    NavItem(
                      icon: Icons.downloading_rounded,
                      label: '正在下载',
                      page: 'downloading',
                      badge: active > 0 ? '$active' : (failed > 0 ? '!' : null),
                    ),
                    NavItem(
                      icon: Icons.task_alt_rounded,
                      label: '已完成',
                      page: 'finished',
                      badge: done > 0 ? '$done' : null,
                      quietBadge: true,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                      child: Divider(height: 1, color: p.divider),
                    ),
                    const NavItem(icon: Icons.settings_rounded, label: '设置', page: 'settings'),
                  ],
                );
              },
            ),
          ),
          const _SupportedFooter(),
        ],
      ),
    );
  }
}

class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.page,
    this.badge,
    this.quietBadge = false,
  });

  final IconData icon;
  final String label;
  final String page;
  final String? badge;
  final bool quietBadge;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ValueListenableBuilder(
      valueListenable: AppState.I.page,
      builder: (context, cur, _) {
        final sel = cur == page;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Hover(
            onTap: () {
              Scaffold.maybeOf(context)?.closeDrawer();
              AppState.I.page.value = page;
            },
            builder: (_, h) => Container(
              height: 40,
              padding: const EdgeInsets.only(left: 12, right: 10),
              decoration: BoxDecoration(
                color: sel ? null : (h ? p.hover : null),
                gradient: sel ? Tokens.accentGradient : null,
                borderRadius: BorderRadius.circular(Tokens.radiusM),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: sel ? Colors.white : p.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        color: sel ? Colors.white : p.textPrimary.withValues(alpha: 0.85),
                        fontWeight: sel ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (badge != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(
                        color: sel
                            ? Colors.white.withValues(alpha: 0.25)
                            : (quietBadge ? p.hoverStrong : (badge == '!' ? Tokens.danger : Tokens.accent)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: sel || !quietBadge ? Colors.white : p.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 侧栏底部：支持的平台
class _SupportedFooter extends StatelessWidget {
  const _SupportedFooter();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const shown = [
      UiPlatform.douyin,
      UiPlatform.tiktok,
      UiPlatform.xiaohongshu,
      UiPlatform.instagram,
      UiPlatform.x,
      UiPlatform.bilibili,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('支持的平台', style: TextStyle(fontSize: 12, color: p.textTertiary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final s in shown) PlatformTag(s, dense: true)],
          ),
        ],
      ),
    );
  }
}
