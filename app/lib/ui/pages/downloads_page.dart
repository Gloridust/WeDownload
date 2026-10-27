import 'package:flutter/material.dart';

import '../../src/rust/api/core.dart' as core;
import '../../src/rust/api/types.dart';
import '../../state.dart';
import '../../theme.dart';
import '../widgets.dart';

/// 下载列表：`finished` 为假时显示进行中 / 排队 / 失败的任务，为真时显示已完成的
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.finished});

  final bool finished;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.I.tasks,
      builder: (context, all, _) {
        final list = all.where((t) => (t.status == UiTaskStatus.done) == finished).toList();
        final running = list.where((t) => t.status == UiTaskStatus.running).toList();
        final speed = running.fold<int>(0, (s, t) => s + t.speed.toInt());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: finished ? '已完成' : '正在下载',
              subtitle: finished
                  ? '共 ${list.length} 个文件'
                  : (running.isEmpty ? '${list.length} 个任务' : '${running.length} 个下载中 · ${formatBytes(speed)}/s'),
              trailing: finished
                  ? (list.isEmpty ? null : PillButton(label: '清空记录', icon: Icons.delete_sweep_rounded, onTap: () => core.clearFinished()))
                  : _bulkActions(list),
            ),
            Expanded(
              child: list.isEmpty
                  ? EmptyHint(
                      icon: finished ? Icons.task_alt_rounded : Icons.downloading_rounded,
                      text: finished ? '还没有下载完成的文件' : '没有正在进行的下载',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(Tokens.pageGutter - 12, 0, Tokens.pageGutter - 12, 32),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, i) => _TaskRow(task: list[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget? _bulkActions(List<UiTask> list) {
    final failed = list.where((t) => t.status == UiTaskStatus.failed || t.status == UiTaskStatus.canceled).toList();
    final active = list.where((t) => t.status == UiTaskStatus.running || t.status == UiTaskStatus.queued).toList();
    if (failed.isEmpty && active.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failed.isNotEmpty)
          PillButton(
            label: '全部重试',
            icon: Icons.refresh_rounded,
            onTap: () {
              for (final t in failed) {
                core.retryTask(id: t.id);
              }
            },
          ),
        if (failed.isNotEmpty && active.isNotEmpty) const SizedBox(width: 8),
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
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task});

  final UiTask task;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = task;
    final total = t.total.toInt();
    final done = t.downloaded.toInt();
    final frac = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    final fileName = t.filePath.split(RegExp(r'[\\/]')).last;
    final (statusText, statusColor) = switch (t.status) {
      UiTaskStatus.queued => ('排队中', p.textTertiary),
      UiTaskStatus.running => (
        total > 0
            ? '${formatBytes(done)} / ${formatBytes(total)} · ${formatBytes(t.speed.toInt())}/s'
            : '${formatBytes(done)} · ${formatBytes(t.speed.toInt())}/s',
        p.textSecondary,
      ),
      UiTaskStatus.done => (formatBytes(total), p.textTertiary),
      UiTaskStatus.failed => (t.error ?? '下载失败', Tokens.danger),
      UiTaskStatus.canceled => ('已取消', p.textTertiary),
    };
    return Hover(
      onTap: t.status == UiTaskStatus.done ? () => _open(t.filePath) : null,
      builder: (_, h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: h ? p.surface : null,
          borderRadius: BorderRadius.circular(Tokens.radiusRow),
          boxShadow: h ? [BoxShadow(color: p.shadow, blurRadius: 12, offset: const Offset(0, 2))] : null,
        ),
        child: Row(
          children: [
            NetImage(
              url: t.cover,
              platform: t.platform,
              width: 48,
              height: 64,
              radius: Tokens.radiusS,
              icon: t.kind == UiMediaKind.image ? Icons.image_rounded : Icons.movie_rounded,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: p.textPrimary, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      PlatformTag(t.platform, dense: true),
                      const SizedBox(width: 8),
                      Text(t.variantLabel, style: TextStyle(fontSize: 12, color: p.textTertiary)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          statusText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: statusColor),
                        ),
                      ),
                    ],
                  ),
                  if (t.status == UiTaskStatus.running || t.status == UiTaskStatus.queued) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: t.status == UiTaskStatus.queued ? 0 : frac,
                        minHeight: 4,
                        backgroundColor: p.field,
                        color: Tokens.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            ..._actions(t),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(UiTask t) => switch (t.status) {
    UiTaskStatus.running || UiTaskStatus.queued => [
      IconBtn(Icons.close_rounded, tooltip: '取消', onTap: () => core.cancelTask(id: t.id)),
    ],
    UiTaskStatus.done => [
      IconBtn(Icons.play_circle_outline_rounded, tooltip: '打开', onTap: () => _open(t.filePath)),
      IconBtn(Icons.folder_open_rounded, tooltip: '在文件夹中显示', onTap: () => _reveal(t.filePath)),
      IconBtn(Icons.delete_outline_rounded, tooltip: '删除记录', onTap: () => core.removeTask(id: t.id, deleteFile: false)),
    ],
    UiTaskStatus.failed || UiTaskStatus.canceled => [
      IconBtn(Icons.refresh_rounded, tooltip: '重试', onTap: () => core.retryTask(id: t.id)),
      IconBtn(Icons.delete_outline_rounded, tooltip: '删除', onTap: () => core.removeTask(id: t.id, deleteFile: true)),
    ],
  };

  static Future<void> _open(String path) async {
    try {
      await core.openPath(path: path);
    } catch (e) {
      AppState.I.notify('$e');
    }
  }

  static Future<void> _reveal(String path) async {
    try {
      await core.revealPath(path: path);
    } catch (e) {
      AppState.I.notify('$e');
    }
  }
}
