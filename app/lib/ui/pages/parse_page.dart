import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/rust/api/core.dart' as core;
import '../../src/rust/api/types.dart';
import '../../state.dart';
import '../../theme.dart';
import '../widgets.dart';

/// 解析页：粘贴链接 → 解析 → 勾选条目和清晰度 → 下载
class ParsePage extends StatefulWidget {
  const ParsePage({super.key});

  @override
  State<ParsePage> createState() => _ParsePageState();
}

/// 页面切走再回来时保留上一次的解析结果
class _ParseMemory {
  static String input = '';
  static UiMediaInfo? result;
  static String? error;
  static Set<int> selected = {};
  static Map<int, int> variant = {};
  static bool added = false;
}

class _ParsePageState extends State<ParsePage> {
  final _input = TextEditingController(text: _ParseMemory.input);
  final _focus = FocusNode();
  bool _busy = false;
  int _seq = 0;

  UiMediaInfo? get _result => _ParseMemory.result;

  @override
  void initState() {
    super.initState();
    AppState.I.clipboardLink.addListener(_onClipboard);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onClipboard());
  }

  @override
  void dispose() {
    AppState.I.clipboardLink.removeListener(_onClipboard);
    _ParseMemory.input = _input.text;
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onClipboard() {
    final text = AppState.I.clipboardLink.value;
    if (text == null || _busy || !mounted) return;
    AppState.I.clipboardLink.value = null;
    _input.text = text;
    _parse();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      AppState.I.notify('剪贴板是空的');
      return;
    }
    AppState.I.ignoreClipboard(text);
    _input.text = text;
    _parse();
  }

  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (core.findLink(text: text) == null) {
      setState(() => _ParseMemory.error = '没有在输入里找到链接');
      return;
    }
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _ParseMemory.error = null;
    });
    try {
      final r = await core.extract(input: text);
      if (seq != _seq || !mounted) return;
      setState(() {
        _ParseMemory.result = r;
        _ParseMemory.added = false;
        _ParseMemory.variant = {};
        _ParseMemory.selected = {
          for (var i = 0; i < r.items.length; i++)
            if (r.items[i].kind != UiMediaKind.audio) i,
        };
      });
    } catch (e) {
      if (seq != _seq || !mounted) return;
      setState(() => _ParseMemory.error = _cleanError(e));
    } finally {
      if (seq == _seq && mounted) {
        setState(() => _busy = false);
        // 解析期间剪贴板里又来了新链接：接着解析它
        if (AppState.I.clipboardLink.value != null) _onClipboard();
      }
    }
  }

  Future<void> _download() async {
    final r = _result;
    if (r == null || _ParseMemory.selected.isEmpty) return;
    final picks = [
      for (final i in _ParseMemory.selected.toList()..sort()) UiPick(item: i, variant: _ParseMemory.variant[i] ?? 0),
    ];
    try {
      await core.enqueue(key: r.key, picks: picks);
      setState(() => _ParseMemory.added = true);
      AppState.I.notify('已加入下载队列（${picks.length} 项）');
    } catch (e) {
      AppState.I.notify(_cleanError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        const PageHeader(title: '解析下载', subtitle: '粘贴抖音、TikTok、小红书、Instagram、X、哔哩哔哩的分享链接或整段分享文案'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.pageGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _inputBox(context),
              const SizedBox(height: 20),
              if (_busy)
                const _Parsing()
              else if (_ParseMemory.error != null)
                _ErrorPanel(message: _ParseMemory.error!, onRetry: _parse)
              else if (_result != null)
                _ResultPanel(
                  info: _result!,
                  added: _ParseMemory.added,
                  onChanged: () => setState(() => _ParseMemory.added = false),
                  onDownload: _download,
                )
              else
                const _Intro(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _inputBox(BuildContext context) {
    final p = context.palette;
    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Icon(Icons.link_rounded, color: p.textTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              onSubmitted: (_) => _parse(),
              style: TextStyle(fontSize: 15, color: p.textPrimary),
              cursorColor: Tokens.accent,
              decoration: InputDecoration(
                hintText: '在这里粘贴链接，回车解析',
                hintStyle: TextStyle(color: p.textTertiary, fontSize: 15),
                border: InputBorder.none,
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: _input,
            builder: (context, v, _) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconBtn(
                    Icons.close_rounded,
                    size: 18,
                    tooltip: '清空',
                    onTap: () {
                      _input.clear();
                      _focus.requestFocus();
                    },
                  ),
          ),
          const SizedBox(width: 8),
          PillButton(label: '粘贴并解析', icon: Icons.content_paste_rounded, onTap: _busy ? null : _paste),
          const SizedBox(width: 8),
          PillButton(label: '解析', primary: true, busy: _busy, onTap: _parse),
        ],
      ),
    );
  }
}

String _cleanError(Object e) {
  var s = e.toString();
  for (final prefix in ['AnyhowException(', 'Exception: ']) {
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
  }
  if (s.endsWith(')') && e.toString().startsWith('AnyhowException(')) s = s.substring(0, s.length - 1);
  // anyhow 的回溯信息只留第一行
  return s.split('\n\nStack backtrace').first.split('\n').first.trim();
}

class _Parsing extends StatelessWidget {
  const _Parsing();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Panel(
      child: Row(
        children: [
          const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正在解析…', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.textPrimary)),
                const SizedBox(height: 4),
                Text(
                  '抖音、小红书、Instagram 需要在后台用浏览器打开作品页，通常要 5–20 秒',
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Panel(
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: Tokens.danger, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('解析失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.textPrimary)),
                const SizedBox(height: 4),
                SelectableText(message, style: TextStyle(fontSize: 13, color: p.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          PillButton(label: '重试', icon: Icons.refresh_rounded, onTap: onRetry),
        ],
      ),
    );
  }
}

/// 还没有解析时：三步说明
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget step(IconData icon, String title, String desc) => Expanded(
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: Tokens.accentSoft, borderRadius: BorderRadius.circular(Tokens.radiusRow)),
              child: Icon(icon, color: Tokens.accent),
            ),
            const SizedBox(height: 14),
            Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.textPrimary)),
            const SizedBox(height: 6),
            Text(desc, style: TextStyle(fontSize: 13, height: 1.5, color: p.textSecondary)),
          ],
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        step(Icons.ios_share_rounded, '复制分享链接', '在 App 里点「分享 → 复制链接」，整段分享文案也可以直接粘贴'),
        const SizedBox(width: 16),
        step(Icons.auto_awesome_rounded, '自动识别', '窗口回到前台时会读取剪贴板，识别到支持的链接就自动解析'),
        const SizedBox(width: 16),
        step(Icons.download_rounded, '选好就下', '视频默认最高画质、无水印；图文可以按张勾选，实况图一起保存'),
      ],
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.info, required this.added, required this.onChanged, required this.onDownload});

  final UiMediaInfo info;
  final bool added;
  final VoidCallback onChanged;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sel = _ParseMemory.selected;
    final counts = <UiMediaKind, int>{};
    for (final it in info.items) {
      counts[it.kind] = (counts[it.kind] ?? 0) + 1;
    }
    final summary = [
      if ((counts[UiMediaKind.video] ?? 0) > 0) '${counts[UiMediaKind.video]} 个视频',
      if ((counts[UiMediaKind.image] ?? 0) > 0) '${counts[UiMediaKind.image]} 张图片',
      if ((counts[UiMediaKind.livePhoto] ?? 0) > 0) '${counts[UiMediaKind.livePhoto]} 段实况',
      if ((counts[UiMediaKind.audio] ?? 0) > 0) '背景音乐',
    ].join(' · ');
    final allSelected = sel.length == info.items.length;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NetImage(url: info.cover, platform: info.platform, width: 96, height: 128, radius: Tokens.radiusRow),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PlatformTag(info.platform),
                        if (info.durationMs != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            formatDuration(info.durationMs!.toInt()),
                            style: TextStyle(fontSize: 12, color: p.textTertiary),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      info.title,
                      maxLines: 3,
                      style: TextStyle(fontSize: 17, height: 1.4, fontWeight: FontWeight.w600, color: p.textPrimary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [if (info.author != null) info.author!, summary].join('  ·  '),
                      style: TextStyle(fontSize: 13, color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (var i = 0; i < info.items.length; i++)
                _ItemTile(
                  platform: info.platform,
                  item: info.items[i],
                  index: i,
                  selected: sel.contains(i),
                  variant: _ParseMemory.variant[i] ?? 0,
                  onToggle: () {
                    sel.contains(i) ? sel.remove(i) : sel.add(i);
                    onChanged();
                  },
                  onVariant: (v) {
                    _ParseMemory.variant[i] = v;
                    onChanged();
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              if (info.items.length > 1)
                PillButton(
                  label: allSelected ? '全不选' : '全选',
                  icon: allSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                  onTap: () {
                    if (allSelected) {
                      sel.clear();
                    } else {
                      sel.addAll(List.generate(info.items.length, (i) => i));
                    }
                    onChanged();
                  },
                ),
              const Spacer(),
              if (added) ...[
                PillButton(
                  label: '查看下载',
                  icon: Icons.downloading_rounded,
                  onTap: () => AppState.I.page.value = 'downloading',
                ),
                const SizedBox(width: 10),
              ],
              PillButton(
                label: added ? '已加入队列' : '下载选中的 ${sel.length} 项',
                icon: added ? Icons.check_rounded : Icons.download_rounded,
                primary: true,
                height: 40,
                onTap: sel.isEmpty || added ? null : onDownload,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.platform,
    required this.item,
    required this.index,
    required this.selected,
    required this.variant,
    required this.onToggle,
    required this.onVariant,
  });

  final UiPlatform platform;
  final UiMediaItem item;
  final int index;
  final bool selected;
  final int variant;
  final VoidCallback onToggle;
  final ValueChanged<int> onVariant;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (icon, label) = switch (item.kind) {
      UiMediaKind.video => (Icons.play_arrow_rounded, '视频'),
      UiMediaKind.image => (Icons.image_rounded, '图片'),
      UiMediaKind.livePhoto => (Icons.motion_photos_on_rounded, '实况'),
      UiMediaKind.audio => (Icons.music_note_rounded, '音乐'),
    };
    final v = item.variants.isEmpty ? null : item.variants[variant.clamp(0, item.variants.length - 1)];
    const w = 172.0;
    return SizedBox(
      width: w,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Hover(
            onTap: onToggle,
            builder: (_, h) => Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Tokens.radiusRow + 2),
                border: Border.all(color: selected ? Tokens.accent : Colors.transparent, width: 2),
              ),
              child: Stack(
                children: [
                  NetImage(
                    url: item.thumbnail,
                    platform: platform,
                    width: w - 4,
                    height: (w - 4) * 4 / 3,
                    radius: Tokens.radiusRow,
                    icon: icon,
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 13, color: Colors.white),
                          const SizedBox(width: 3),
                          Text('$label ${index + 1}', style: const TextStyle(fontSize: 11, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: selected ? Tokens.accent : Colors.black.withValues(alpha: h ? 0.5 : 0.35),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: selected ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (v != null)
            item.variants.length > 1
                ? _VariantMenu(item: item, selected: variant, onSelected: onVariant)
                : Text(
                    _variantText(v),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: p.textSecondary),
                  ),
        ],
      ),
    );
  }
}

String _variantText(UiVariant v) {
  final size = v.size == null ? '' : ' · ${formatBytes(v.size!.toInt())}';
  return '${v.label}$size';
}

class _VariantMenu extends StatelessWidget {
  const _VariantMenu({required this.item, required this.selected, required this.onSelected});

  final UiMediaItem item;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PopupMenuButton<int>(
      tooltip: '选择清晰度',
      position: PopupMenuPosition.under,
      color: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusM)),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (var i = 0; i < item.variants.length; i++)
          PopupMenuItem(
            value: i,
            height: 36,
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: i == selected ? const Icon(Icons.check_rounded, size: 16, color: Tokens.accent) : null,
                ),
                Text(_variantText(item.variants[i]), style: TextStyle(fontSize: 13, color: p.textPrimary)),
              ],
            ),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: p.field, borderRadius: BorderRadius.circular(Tokens.radiusS)),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _variantText(item.variants[selected.clamp(0, item.variants.length - 1)]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.textPrimary),
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: p.textSecondary),
          ],
        ),
      ),
    );
  }
}
