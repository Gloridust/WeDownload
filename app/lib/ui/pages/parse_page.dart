import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../src/rust/api/types.dart';
import '../../state.dart';
import '../../theme.dart';
import '../widgets.dart';

/// 解析页：空闲时是粘贴入口和最近解析；有结果时像歌单详情——上面是作品信息，下面一行一条媒体。
class ParsePage extends StatelessWidget {
  const ParsePage({super.key});

  @override
  Widget build(BuildContext context) {
    final parse = AppState.I.parse;
    return ListenableBuilder(
      listenable: Listenable.merge([parse, parse.busy]),
      builder: (context, _) {
        if (parse.busy.value) return const _Parsing();
        if (parse.error != null) return _ErrorView(message: parse.error!);
        final r = parse.result;
        if (r != null) return _ResultView(info: r);
        return const _Welcome();
      },
    );
  }
}

// ---------------- 空闲 ----------------

class _Welcome extends StatelessWidget {
  const _Welcome();

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
    final history = AppState.I.parse.history;
    return ListView(
      padding: const EdgeInsets.fromLTRB(Tokens.pageGutter, 16, Tokens.pageGutter, 32),
      children: [
        // 粘贴区：虚线框，点击即粘贴解析
        Hover(
          onTap: _paste,
          builder: (_, h) => CustomPaint(
            painter: _DashedBorder(color: h ? Tokens.accent : p.textTertiary.withValues(alpha: 0.5)),
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                color: h ? Tokens.accentSoft.withValues(alpha: 0.05) : null,
                borderRadius: BorderRadius.circular(Tokens.radiusL),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.content_paste_go_rounded, size: 40, color: h ? Tokens.accent : p.textTertiary),
                  const SizedBox(height: 14),
                  Text(
                    '点击这里粘贴并解析',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: p.textPrimary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '在 App 里点「分享 → 复制链接」，整段分享文案也行；窗口回到前台时会自动识别剪贴板',
                    style: TextStyle(fontSize: 13, color: p.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final pl in UiPlatform.values)
                        if (pl != UiPlatform.generic) PlatformTag(pl),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('最近解析', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: p.textPrimary)),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text('这次打开后还没有解析过作品', style: TextStyle(fontSize: 13, color: p.textTertiary)),
          )
        else
          for (final h in history) _HistoryRow(info: h),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.info});

  final UiMediaInfo info;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Hover(
      onTap: () => AppState.I.parse.show(info),
      builder: (_, h) => Container(
        height: Tokens.rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: h ? p.rowHover : null,
          borderRadius: BorderRadius.circular(Tokens.radiusRow),
        ),
        child: Row(
          children: [
            NetImage(url: info.cover, platform: info.platform, width: 44, height: 44, radius: Tokens.radiusS),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: p.textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(info.author ?? '', style: TextStyle(fontSize: 12, color: p.textTertiary)),
                ],
              ),
            ),
            PlatformTag(info.platform, dense: true),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: Text(
                _summary(info),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: p.textTertiary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _summary(UiMediaInfo info) {
  final v = info.items.where((i) => i.kind == UiMediaKind.video).length;
  final img = info.items.where((i) => i.kind == UiMediaKind.image).length;
  return [if (v > 0) '$v 个视频', if (img > 0) '$img 张图'].join(' · ');
}

class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(Tokens.radiusL));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

// ---------------- 解析中 / 出错 ----------------

class _Parsing extends StatelessWidget {
  const _Parsing();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.6, color: Tokens.accent)),
          const SizedBox(height: 18),
          Text('正在解析…', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: p.textPrimary)),
          const SizedBox(height: 6),
          Text(
            '抖音、小红书、Instagram 会在后台用浏览器打开作品页，一般 5–20 秒',
            style: TextStyle(fontSize: 13, color: p.textTertiary),
          ),
          const SizedBox(height: 18),
          PillButton(label: '取消', onTap: AppState.I.parse.clear),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final parse = AppState.I.parse;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded, size: 44, color: p.textTertiary),
            const SizedBox(height: 14),
            Text('没能解析这个链接', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: p.textPrimary)),
            const SizedBox(height: 8),
            SelectableText(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: p.textSecondary),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PillButton(label: '重试', icon: Icons.refresh_rounded, primary: true, onTap: () => parse.run(parse.input.text)),
                const SizedBox(width: 12),
                PillButton(label: '返回', onTap: parse.clear),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 结果 ----------------

class _ResultView extends StatelessWidget {
  const _ResultView({required this.info});

  final UiMediaInfo info;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final parse = AppState.I.parse;
    final n = parse.selected.length;
    final all = n == info.items.length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Tokens.pageGutter, 16, Tokens.pageGutter, 24),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, c) {
                final coverSize = c.maxWidth > 700 ? 176.0 : 128.0;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NetImage(
                      url: info.cover,
                      platform: info.platform,
                      width: coverSize,
                      height: coverSize,
                      radius: Tokens.radiusL,
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: SizedBox(
                        height: coverSize,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            PlatformTag(info.platform),
                            const SizedBox(height: 10),
                            Text(
                              info.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, height: 1.3, color: p.textPrimary),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              [
                                if (info.author != null) info.author!,
                                _summary(info),
                                if (info.durationMs != null) formatDuration(info.durationMs!.toInt()),
                              ].where((s) => s.isNotEmpty).join('  ·  '),
                              style: TextStyle(color: p.textSecondary, fontSize: 13),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                PillButton(
                                  label: parse.added ? '已加入队列' : (all ? '下载全部' : '下载选中 $n 项'),
                                  icon: parse.added ? Icons.check_rounded : Icons.download_rounded,
                                  primary: true,
                                  onTap: n == 0 || parse.added ? null : () => parse.download(),
                                ),
                                const SizedBox(width: 12),
                                if (info.items.length > 1) ...[
                                  PillButton(
                                    label: all ? '全不选' : '全选',
                                    icon: all ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                    onTap: parse.toggleAll,
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                if (parse.added)
                                  PillButton(
                                    label: '查看下载',
                                    icon: Icons.downloading_rounded,
                                    onTap: () => AppState.I.page.value = 'downloading',
                                  )
                                else
                                  PillButton(label: '关闭', icon: Icons.close_rounded, onTap: parse.clear),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.pageGutter - 12),
          sliver: SliverToBoxAdapter(child: const _ListHeader()),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Tokens.pageGutter - 12, 4, Tokens.pageGutter - 12, 32),
          sliver: SliverList.builder(
            itemCount: info.items.length,
            itemBuilder: (context, i) => _ItemRow(info: info, index: i),
          ),
        ),
      ],
    );
  }
}

/// 列宽统一定义，表头与行对齐
class _Cols extends StatelessWidget {
  const _Cols({required this.index, required this.media, required this.quality, required this.size, required this.action});

  final Widget index, media, quality, size, action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final wide = c.maxWidth > 620;
      return Row(
        children: [
          SizedBox(width: 52, child: index),
          Expanded(flex: 4, child: media),
          const SizedBox(width: 12),
          SizedBox(width: wide ? 220 : 150, child: quality),
          if (wide) SizedBox(width: 90, child: size),
          SizedBox(width: 56, child: action),
        ],
      );
    },
  );
}

class _ListHeader extends StatelessWidget {
  const _ListHeader();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(color: p.textSecondary, fontSize: 13);
    return Container(
      height: 40,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.divider))),
      child: _Cols(
        index: Text('#', style: style, textAlign: TextAlign.center),
        media: Text('内容', style: style),
        quality: Text('清晰度', style: style),
        size: Text('大小', style: style),
        action: const SizedBox.shrink(),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.info, required this.index});

  final UiMediaInfo info;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final parse = AppState.I.parse;
    final item = info.items[index];
    final sel = parse.selected.contains(index);
    final vi = (parse.variant[index] ?? 0).clamp(0, item.variants.isEmpty ? 0 : item.variants.length - 1);
    final v = item.variants.isEmpty ? null : item.variants[vi];
    final (icon, kind) = switch (item.kind) {
      UiMediaKind.video => (Icons.play_circle_outline_rounded, '视频'),
      UiMediaKind.image => (Icons.image_outlined, '图片'),
      UiMediaKind.livePhoto => (Icons.motion_photos_on_outlined, '实况'),
      UiMediaKind.audio => (Icons.music_note_rounded, '背景音乐'),
    };
    return Hover(
      onTap: () => parse.toggle(index),
      builder: (_, h) => Container(
        height: Tokens.rowHeight,
        decoration: BoxDecoration(
          color: h ? p.rowHover : null,
          borderRadius: BorderRadius.circular(Tokens.radiusRow),
        ),
        child: _Cols(
          index: Center(child: _Check(selected: sel, hovered: h, index: index)),
          media: Row(
            children: [
              NetImage(
                url: item.thumbnail,
                platform: info.platform,
                width: 40,
                height: 48,
                radius: Tokens.radiusS,
                icon: icon,
              ),
              const SizedBox(width: 12),
              Icon(icon, size: 16, color: sel ? Tokens.accent : p.textTertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.kind == UiMediaKind.audio && v != null ? v.label : '$kind ${index + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: sel ? Tokens.accent : p.textPrimary),
                ),
              ),
              if (v != null) ...[
                const SizedBox(width: 8),
                Text(v.ext.toUpperCase(), style: TextStyle(fontSize: 11, color: p.textTertiary)),
              ],
            ],
          ),
          quality: item.variants.length > 1
              ? Align(alignment: Alignment.centerLeft, child: _QualityMenu(item: item, index: index, selected: vi))
              : Text(
                  v == null || item.kind == UiMediaKind.audio ? '—' : v.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
          size: Text(
            v?.size == null ? '—' : formatBytes(v!.size!.toInt()),
            style: TextStyle(fontSize: 13, color: p.textTertiary),
          ),
          action: h
              ? IconBtn(Icons.download_rounded, tooltip: '只下载这一项', onTap: () => parse.download(only: [index]))
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// 序号列：未选中显示序号，悬停或选中显示勾选框
class _Check extends StatelessWidget {
  const _Check({required this.selected, required this.hovered, required this.index});

  final bool selected;
  final bool hovered;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!selected && !hovered) {
      return Text(
        (index + 1).toString().padLeft(2, '0'),
        style: TextStyle(color: p.textTertiary, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()]),
      );
    }
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: selected ? Tokens.accent : null,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: selected ? Tokens.accent : p.textTertiary, width: 1.4),
      ),
      child: selected ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
    );
  }
}

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.item, required this.index, required this.selected});

  final UiMediaItem item;
  final int index;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return PopupMenuButton<int>(
      tooltip: '选择清晰度',
      position: PopupMenuPosition.under,
      color: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.radiusM)),
      onSelected: (v) => AppState.I.parse.pick(index, v),
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
                Text(item.variants[i].label, style: TextStyle(fontSize: 13, color: p.textPrimary)),
                if (item.variants[i].size != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    formatBytes(item.variants[i].size!.toInt()),
                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(color: p.field, borderRadius: BorderRadius.circular(Tokens.radiusS)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                item.variants[selected].label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: p.textPrimary),
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: p.textSecondary),
          ],
        ),
      ),
    );
  }
}
