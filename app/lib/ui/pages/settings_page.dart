import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../src/rust/api/core.dart' as core;
import '../../src/rust/api/types.dart';
import '../../state.dart';
import '../../theme.dart';
import '../widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return ListenableBuilder(
      listenable: Listenable.merge([app.settings, app.env]),
      builder: (context, _) {
        final s = app.settings.value;
        final env = app.env.value;
        if (s == null) return const SizedBox.shrink();
        return ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            const PageHeader(title: '设置'),
            _Section(
              title: '下载',
              children: [
                _Row(
                  title: '保存位置',
                  subtitle: s.downloadDir,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PillButton(label: '打开', onTap: () => core.openPath(path: s.downloadDir).catchError((_) {})),
                      const SizedBox(width: 8),
                      PillButton(
                        label: '更改',
                        onTap: () async {
                          final dir = await getDirectoryPath(initialDirectory: s.downloadDir, confirmButtonText: '选择');
                          if (dir != null) app.updateSettings((s) => _copy(s, downloadDir: dir));
                        },
                      ),
                    ],
                  ),
                ),
                _Row(
                  title: '按平台分文件夹',
                  subtitle: '抖音、小红书等各自保存到单独的子文件夹',
                  trailing: Switch(
                    value: s.perPlatformDir,
                    onChanged: (v) => app.updateSettings((s) => _copy(s, perPlatformDir: v)),
                  ),
                ),
                _Row(
                  title: '同时下载数',
                  subtitle: '同时进行的下载任务数量',
                  trailing: _Stepper(
                    value: s.maxConcurrent,
                    min: 1,
                    max: 8,
                    onChanged: (v) => app.updateSettings((s) => _copy(s, maxConcurrent: v)),
                  ),
                ),
                _Row(
                  title: '自动识别剪贴板',
                  subtitle: '窗口回到前台时，剪贴板里有支持的链接就自动解析',
                  trailing: Switch(
                    value: s.watchClipboard,
                    onChanged: (v) => app.updateSettings((s) => _copy(s, watchClipboard: v)),
                  ),
                ),
              ],
            ),
            _Section(
              title: '解析',
              children: [
                _Row(
                  title: '解析用的浏览器',
                  subtitle: env?.browserPath ??
                      '没有找到 Chrome / Edge / Chromium。抖音、小红书、Instagram 需要借助本机浏览器解析，请安装其中一款，或在下方指定路径',
                  subtitleColor: env?.browserPath == null ? Tokens.danger : null,
                  trailing: env?.browserPath == null
                      ? const Icon(Icons.error_outline_rounded, color: Tokens.danger)
                      : const Icon(Icons.check_circle_rounded, color: Tokens.success),
                ),
                _Row(
                  title: '指定浏览器路径',
                  subtitle: s.browserPath.isEmpty ? '自动查找' : s.browserPath,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (s.browserPath.isNotEmpty) ...[
                        PillButton(label: '恢复自动', onTap: () => app.updateSettings((s) => _copy(s, browserPath: ''))),
                        const SizedBox(width: 8),
                      ],
                      PillButton(
                        label: '选择…',
                        onTap: () async {
                          final f = await openFile(confirmButtonText: '选择');
                          if (f != null) app.updateSettings((s) => _copy(s, browserPath: f.path));
                        },
                      ),
                    ],
                  ),
                ),
                _Row(
                  title: '显示解析浏览器窗口',
                  subtitle: '默认在后台无窗口运行；遇到验证码或需要登录时打开，在弹出的浏览器里手动处理一次即可',
                  trailing: Switch(
                    value: !s.browserHeadless,
                    onChanged: (v) => app.updateSettings((s) => _copy(s, browserHeadless: !v)),
                  ),
                ),
                _Row(
                  title: 'yt-dlp（可选）',
                  subtitle: env?.ytdlpPath ?? '未安装。安装后，不在支持列表里的网站会交给它解析',
                  trailing: env?.ytdlpPath == null
                      ? Icon(Icons.remove_circle_outline_rounded, color: context.palette.textTertiary)
                      : const Icon(Icons.check_circle_rounded, color: Tokens.success),
                ),
              ],
            ),
            _Section(
              title: '外观',
              children: [
                _Row(
                  title: '主题',
                  trailing: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      selectedBackgroundColor: Tokens.accentSoft,
                      selectedForegroundColor: Tokens.accent,
                    ),
                    segments: const [
                      ButtonSegment(value: 'system', label: Text('跟随系统')),
                      ButtonSegment(value: 'light', label: Text('浅色')),
                      ButtonSegment(value: 'dark', label: Text('深色')),
                    ],
                    selected: {s.theme},
                    onSelectionChanged: (v) => app.updateSettings((s) => _copy(s, theme: v.first)),
                  ),
                ),
              ],
            ),
            _Section(
              title: '关于',
              children: [
                _Row(title: 'WeDownload', subtitle: '版本 ${env?.version ?? '-'} · 无服务器，所有解析都在本机完成'),
                _Row(
                  title: '数据目录',
                  subtitle: env?.dataDir ?? '',
                  trailing: PillButton(label: '打开', onTap: () => core.openPath(path: env?.dataDir ?? '').catchError((_) {})),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

UiSettings _copy(
  UiSettings s, {
  String? downloadDir,
  bool? perPlatformDir,
  int? maxConcurrent,
  bool? browserHeadless,
  String? browserPath,
  String? theme,
  bool? watchClipboard,
}) => UiSettings(
  downloadDir: downloadDir ?? s.downloadDir,
  perPlatformDir: perPlatformDir ?? s.perPlatformDir,
  maxConcurrent: maxConcurrent ?? s.maxConcurrent,
  browserHeadless: browserHeadless ?? s.browserHeadless,
  browserPath: browserPath ?? s.browserPath,
  theme: theme ?? s.theme,
  watchClipboard: watchClipboard ?? s.watchClipboard,
  uiScale: s.uiScale,
);

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.pageGutter, 0, Tokens.pageGutter, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.textSecondary)),
          ),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: p.divider),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, this.trailing, this.subtitleColor});

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, color: p.textPrimary)),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: TextStyle(fontSize: 12, height: 1.4, color: subtitleColor ?? p.textTertiary)),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 16), trailing!],
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.min, required this.max, required this.onChanged});

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(color: p.field, borderRadius: BorderRadius.circular(Tokens.radiusM)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconBtn(Icons.remove_rounded, size: 18, onTap: value > min ? () => onChanged(value - 1) : null),
          SizedBox(
            width: 28,
            child: Text('$value', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: p.textPrimary)),
          ),
          IconBtn(Icons.add_rounded, size: 18, onTap: value < max ? () => onChanged(value + 1) : null),
        ],
      ),
    );
  }
}
