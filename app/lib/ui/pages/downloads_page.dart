import 'package:flutter/material.dart';

import '../../src/rust/api/core.dart' as core;
import '../../src/rust/api/types.dart';
import '../../state.dart';
import '../../theme.dart';
import '../widgets.dart';

/// 下载列表：`finished` 为假时是进行中 / 排队 / 失败，为真时是已下载（可按平台筛选）
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.finished});

  final bool finished;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return ListenableBuilder(
      listenable: Listenable.merge([app.tasks, app.platformFilter]),
      builder: (context, _) {
        final filter = finished ? app.platformFilter.value : null;
        final list = app.tasks.value
            .where((t) => (t.status == UiTaskStatus.done) == finished)
            .where((t) => filter == null || t.platform == filter)
            .toList();
        final running = list.where((t) => t.status == UiTaskStatus.running).toList();
        final total = list.fold<int>(0, (s, t) => s + t.total.toInt());
        final title = finished ? (filter == null ? '已下载' : PlatformStyle.of(filter).name) : '正在下载';
        final sub = finished
            ? '${list.length} 个文件 · ${formatBytes(total)}'
            : (running.isEmpty
                  ? '${list.length} 个任务'
                  : '${running.length} 个下载中 · ${formatBytes(running.fold<int>(0, (s, t) => s + t.speed.toInt()))}/s');
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(Tokens.pageGutter, 16, Tokens.pageGutter, 16),
              sliver: SliverToBoxAdapter(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(title, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: context.palette.textPrimary)),
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(sub, style: TextStyle(fontSize: 13, color: context.palette.textTertiary)),
                    ),
                    const Spacer(),
                    ..._actions(list),
                  ],
                ),
              ),
            ),
            if (list.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyHint(
                  icon: finished ? Icons.task_alt_rounded : Icons.downloading_rounded,
                  text: finished ? '还没有下载完成的文件' : '没有正在进行的下载，去「解析」页粘贴一个链接试试',
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: Tokens.pageGutter - 12),
                sliver: SliverToBoxAdapter(child: _Header(finished: finished)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(Tokens.pageGutter - 12, 4, Tokens.pageGutter - 12, 32),
                sliver: SliverFixedExtentList(
                  itemExtent: Tokens.rowHeight,
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _TaskRow(task: list[i], index: i),
                    childCount: list.length,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _actions(List<UiTask> list) {
    if (finished) {
      return [
        if (list.isNotEmpty)
          PillButton(label: '清空记录', icon: Icons.delete_sweep_outlined, onTap: () => core.clearFinished()),
      ];
    }
    final failed = list.where((t) => t.status == UiTaskStatus.failed || t.status == UiTaskStatus.canceled).toList();
    final active = list.where((t) => t.status == UiTaskStatus.running || t.status == UiTaskStatus.queued).toList();
    return [
      if (failed.isNotEmpty)
        PillButton(
          label: '全部重试',
          icon: Icons.refresh_rounded,
          primary: true,
          onTap: () {
            for (final t in failed) {
              core.retryTask(id: t.id);
            }
          },
        ),
      if (failed.isNotEmpty && active.isNotEmpty) const SizedBox(width: 10),
      if (active.isNotEmpty)
        PillButton(
          label: '全部取消',
          icon: Icons.stop_circle_outlined,
          onTap: () {
            for (final t in active) {
              core.cancelTask(id: t.id);
            }
          },
        ),
    ];
  }
}

class _Cols extends StatelessWidget {
  const _Cols({
    required this.index,
    required this.file,
    required this.platform,
    required this.quality,
    required this.state,
    required this.actions,
  });

  final Widget index, file, platform, quality, state, actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final wide = c.maxWidth > 760;
      return Row(
        children: [
          SizedBox(width: 52, child: index),
          Expanded(flex: 5, child: file),
          const SizedBox(width: 12),
          if (wide) SizedBox(width: 96, child: platform),
          if (wide) SizedBox(width: 130, child: quality),
          SizedBox(width: wide ? 190 : 150, child: state),
          SizedBox(width: 108, child: actions),
        ],
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.finished});

  final bool finished;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(color: p.textSecondary, fontSize: 13);
    return Container(
      height: 40,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.divider))),
      child: _Cols(
        index: Text('#', style: style, textAlign: TextAlign.center),
        file: Text('文件', style: style),
        platform: Text('平台', style: style),
        quality: Text('清晰度', style: style),
        state: Text(finished ? '大小' : '进度', style: style),
        actions: const SizedBox.shrink(),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.index});

  final UiTask task;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = task;
    final total = t.total.toInt();
    final got = t.downloaded.toInt();
    final name = t.filePath.split(RegExp(r'[\\/]')).last;
    final done = t.status == UiTaskStatus.done;
    return Hover(
      onTap: null,
      builder: (_, h) => GestureDetector(
        onDoubleTap: done ? () => _open(t.filePath) : null,
        child: Container(
          decoration: BoxDecoration(
            color: h ? p.rowHover : null,
            borderRadius: BorderRadius.circular(Tokens.radiusRow),
          ),
          child: _Cols(
            index: Center(
              child: Text(
                (index + 1).toString().padLeft(2, '0'),
                style: TextStyle(color: p.textTertiary, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            file: Row(
              children: [
                NetImage(
                  url: t.cover,
                  platform: t.platform,
                  width: 40,
                  height: 48,
                  radius: Tokens.radiusS,
                  icon: t.kind == UiMediaKind.image ? Icons.image_outlined : Icons.movie_outlined,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: p.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.author ?? t.platformName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: p.textTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            platform: Align(alignment: Alignment.centerLeft, child: PlatformTag(t.platform, dense: true)),
            quality: Text(
              t.variantLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: p.textSecondary),
            ),
            state: _State(task: t, got: got, total: total),
            actions: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: switch (t.status) {
                UiTaskStatus.running || UiTaskStatus.queued => [
                  IconBtn(Icons.close_rounded, tooltip: '取消', onTap: () => core.cancelTask(id: t.id)),
                ],
                UiTaskStatus.done => [
                  IconBtn(Icons.play_circle_outline_rounded, tooltip: '打开', onTap: () => _open(t.filePath)),
                  IconBtn(Icons.folder_open_outlined, tooltip: '在文件夹中显示', onTap: () => _reveal(t.filePath)),
                  IconBtn(
                    Icons.delete_outline_rounded,
                    tooltip: '删除记录（保留文件）',
                    onTap: () => core.removeTask(id: t.id, deleteFile: false),
                  ),
                ],
                UiTaskStatus.failed || UiTaskStatus.canceled => [
                  IconBtn(Icons.refresh_rounded, tooltip: '重试', onTap: () => core.retryTask(id: t.id)),
                  IconBtn(
                    Icons.delete_outline_rounded,
                    tooltip: '删除',
                    onTap: () => core.removeTask(id: t.id, deleteFile: true),
                  ),
                ],
              },
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _open(String path) =>
      core.openPath(path: path).catchError((Object e) => AppState.I.notify(cleanError(e)));

  static Future<void> _reveal(String path) =>
      core.revealPath(path: path).catchError((Object e) => AppState.I.notify(cleanError(e)));
}

class _State extends StatelessWidget {
  const _State({required this.task, required this.got, required this.total});

  final UiTask task;
  final int got;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final small = TextStyle(fontSize: 12, color: p.textTertiary, fontFeatures: const [FontFeature.tabularFigures()]);
    switch (task.status) {
      case UiTaskStatus.done:
        return Text(formatBytes(total), style: TextStyle(fontSize: 13, color: p.textTertiary));
      case UiTaskStatus.queued:
        return Text('排队中', style: small);
      case UiTaskStatus.canceled:
        return Text('已取消', style: small);
      case UiTaskStatus.failed:
        return Tooltip(
          message: task.error ?? '下载失败',
          child: Text(
            task.error ?? '下载失败',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Tokens.accent),
          ),
        );
      case UiTaskStatus.running:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              total > 0
                  ? '${(got * 100 / total).toStringAsFixed(0)}% · ${formatBytes(task.speed.toInt())}/s'
                  : '${formatBytes(got)} · ${formatBytes(task.speed.toInt())}/s',
              style: small,
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: total > 0 ? (got / total).clamp(0.0, 1.0) : null,
                minHeight: 3,
                backgroundColor: p.field,
                color: Tokens.accent,
              ),
            ),
          ],
        );
    }
  }
}
