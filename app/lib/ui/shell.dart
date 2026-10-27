import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../src/rust/api/core.dart' as core;
import '../src/rust/api/types.dart';
import '../state.dart';
import '../theme.dart';
import 'brand.dart';
import 'pages/downloads_page.dart';
import 'pages/parse_page.dart';
import 'pages/settings_page.dart';
import 'status_bar.dart';
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
        ..showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
            // 抬到底部状态栏上方
            margin: const EdgeInsets.only(bottom: Tokens.statusBarHeight + 12),
          ),
        );
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
        final compact = c.maxWidth < 760;
        final borderColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.14)
            : p.textTertiary.withValues(alpha: 0.45);
        return Scaffold(
          key: _scaffold,
          backgroundColor: p.background,
          drawer: compact ? Drawer(width: 240, backgroundColor: p.sidebar, child: const Sidebar()) : null,
          body: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!compact)
                          Container(
                            width: Tokens.sidebarWidth,
                            decoration: BoxDecoration(border: Border(right: BorderSide(color: p.divider))),
                            child: const Sidebar(),
                          ),
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
                  ),
                  const StatusBar(),
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

class TopBar extends StatefulWidget {
  const TopBar({super.key, this.onMenu});

  final VoidCallback? onMenu;

  @override
  State<TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<TopBar> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (text.isEmpty) {
      AppState.I.notify('剪贴板是空的');
      return;
    }
    AppState.I.ignoreClipboard(text);
    AppState.I.parseText(text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final parse = AppState.I.parse;
    return DragArea(
      child: SizedBox(
        height: Tokens.topBarHeight + 8,
        child: Row(
          children: [
            const SizedBox(width: 20),
            if (widget.onMenu != null) ...[IconBtn(Icons.menu_rounded, onTap: widget.onMenu), const SizedBox(width: 8)],
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  // 淡淡的粉—紫—蓝渐变底 + 细边框
                  child: ListenableBuilder(
                    listenable: _focus,
                    builder: (context, _) => Container(
                      height: 36,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.centerRight,
                          end: Alignment.centerLeft,
                          colors: [Color(0x14F574BA), Color(0x14BD8CFF), Color(0x144E8CEA)],
                          stops: [0.07, 0.49, 0.99],
                        ),
                        border: Border.all(
                          color: _focus.hasFocus ? Tokens.accent.withValues(alpha: 0.4) : p.hoverStrong,
                        ),
                        borderRadius: BorderRadius.circular(Tokens.radiusM),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: parse.input,
                              focusNode: _focus,
                              onSubmitted: AppState.I.parseText,
                              style: TextStyle(fontSize: 14, color: p.textPrimary),
                              cursorColor: p.textPrimary,
                              decoration: InputDecoration(
                                hintText: '粘贴分享链接或整段分享文案，回车解析',
                                hintStyle: TextStyle(color: p.textPrimary.withValues(alpha: 0.4), fontSize: 14),
                                prefixIcon: Padding(
                                  padding: const EdgeInsets.only(left: 14, right: 8),
                                  child: Icon(Icons.link_rounded, size: 18, color: p.textPrimary.withValues(alpha: 0.4)),
                                ),
                                prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                                isCollapsed: true,
                                contentPadding: const EdgeInsets.only(right: 8, top: 9, bottom: 9),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: '粘贴并解析',
                            child: Hover(
                              onTap: _paste,
                              builder: (_, h) => Container(
                                height: 36,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  border: Border(left: BorderSide(color: p.hoverStrong)),
                                  color: h ? p.hover : null,
                                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(Tokens.radiusM)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.content_paste_rounded, size: 16, color: p.textSecondary),
                                    const SizedBox(width: 4),
                                    Text('粘贴', style: TextStyle(fontSize: 13, color: p.textSecondary)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconBtn(Icons.folder_open_outlined, tooltip: '打开下载文件夹', onTap: () {
              final dir = AppState.I.settings.value?.downloadDir;
              if (dir != null) core.openPath(path: dir).catchError((_) => AppState.I.notify('下载文件夹还不存在'));
            }),
            IconBtn(Icons.settings_outlined, tooltip: '设置', onTap: () => AppState.I.page.value = 'settings'),
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

/// 左侧导航：解析 / 下载 两组，再按平台列出已下载的内容
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
                  SizedBox(width: Platform.isMacOS ? 80 : 24),
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
                final done = tasks.where((t) => t.status == UiTaskStatus.done).toList();
                final perPlatform = <UiPlatform, int>{};
                for (final t in done) {
                  perPlatform[t.platform] = (perPlatform[t.platform] ?? 0) + 1;
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 16, 16),
                  children: [
                    const NavItem(icon: Icons.link_rounded, label: '解析', page: 'parse'),
                    NavItem(
                      icon: Icons.downloading_rounded,
                      label: '正在下载',
                      page: 'downloading',
                      trailing: active > 0 ? '$active' : (failed > 0 ? '$failed 失败' : null),
                      trailingHot: active > 0 || failed > 0,
                    ),
                    NavItem(
                      icon: Icons.task_alt_rounded,
                      label: '已下载',
                      page: 'finished',
                      filter: null,
                      trailing: done.isEmpty ? null : '${done.length}',
                    ),
                    const _Divider(),
                    const _GroupHeader('按平台'),
                    for (final pl in UiPlatform.values)
                      if (perPlatform[pl] != null)
                        NavItem(
                          icon: null,
                          dotColor: PlatformStyle.of(pl).color,
                          label: PlatformStyle.of(pl).name,
                          page: 'finished',
                          filter: pl,
                          trailing: '${perPlatform[pl]}',
                        ),
                    if (perPlatform.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                        child: Text(
                          '下载过的作品会按平台列在这里',
                          style: TextStyle(fontSize: 12, height: 1.5, color: p.textTertiary),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
    child: Divider(height: 1, color: context.palette.divider),
  );
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Text(text, style: TextStyle(fontSize: 12, color: context.palette.textTertiary)),
  );
}

class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.page,
    this.filter,
    this.dotColor,
    this.trailing,
    this.trailingHot = false,
  });

  /// 为空时显示 [dotColor] 色的圆点（平台分组用）
  final IconData? icon;
  final String label;
  final String page;

  /// 已下载页的平台筛选；null 表示全部
  final UiPlatform? filter;
  final Color? dotColor;
  final String? trailing;
  final bool trailingHot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final app = AppState.I;
    return ListenableBuilder(
      listenable: Listenable.merge([app.page, app.platformFilter]),
      builder: (context, _) {
        final sel = app.page.value == page && (page != 'finished' || app.platformFilter.value == filter);
        // 悬停底色即时出现、即时消失，不做渐变（渐变在快速划过时会拖出残影）
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Hover(
            onTap: () {
              Scaffold.maybeOf(context)?.closeDrawer();
              app.platformFilter.value = filter;
              app.page.value = page;
            },
            builder: (_, h) => Container(
              height: 36,
              padding: const EdgeInsets.only(left: 8, right: 8),
              decoration: BoxDecoration(
                color: sel ? null : (h ? p.hover : null),
                gradient: sel ? Tokens.accentGradient : null,
                borderRadius: BorderRadius.circular(Tokens.radiusM),
              ),
              child: Row(
                children: [
                  icon != null
                      ? Icon(icon, size: 20, color: sel ? Colors.white : p.textSecondary)
                      : SizedBox(
                          width: 20,
                          child: Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: sel ? Colors.white : dotColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 0.5),
                              ),
                            ),
                          ),
                        ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 18 / 14,
                        color: sel ? Colors.white : p.textPrimary.withValues(alpha: 0.8),
                        fontWeight: sel ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: trailingHot ? FontWeight.w600 : FontWeight.w400,
                        color: sel ? Colors.white : (trailingHot ? Tokens.accent : p.textTertiary),
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
