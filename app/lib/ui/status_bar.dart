import 'package:flutter/material.dart';

import '../src/rust/api/types.dart';
import '../state.dart';
import '../theme.dart';
import 'widgets.dart';

/// 底部状态栏：左边是正在下载的作品，中间是整体进度与速度，右边是队列概况。
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      height: Tokens.statusBarHeight,
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: ValueListenableBuilder(
        valueListenable: AppState.I.tasks,
        builder: (context, tasks, _) {
          final running = tasks.where((t) => t.status == UiTaskStatus.running).toList();
          final queued = tasks.where((t) => t.status == UiTaskStatus.queued).length;
          final failed = tasks.where((t) => t.status == UiTaskStatus.failed).length;
          final done = tasks.where((t) => t.status == UiTaskStatus.done).toList();
          final speed = running.fold<int>(0, (s, t) => s + t.speed.toInt());
          final got = running.fold<int>(0, (s, t) => s + t.downloaded.toInt());
          final total = running.fold<int>(0, (s, t) => s + t.total.toInt());
          final current = running.isNotEmpty ? running.first : (done.isNotEmpty ? done.first : null);
          final idle = running.isEmpty && queued == 0;
          return Row(
            children: [
              const SizedBox(width: 20),
              // 左：当前作品
              SizedBox(
                width: 300,
                child: current == null
                    ? Text('还没有下载任务', style: TextStyle(fontSize: 13, color: p.textTertiary))
                    : Hover(
                        onTap: () => AppState.I.page.value = idle ? 'finished' : 'downloading',
                        builder: (_, h) => Row(
                          children: [
                            NetImage(
                              url: current.cover,
                              platform: current.platform,
                              width: 44,
                              height: 44,
                              radius: Tokens.radiusS,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    current.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: h ? Tokens.accent : p.textPrimary,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    idle ? '最近完成 · ${current.platformName}' : '${current.platformName} · ${current.variantLabel}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 12, color: p.textTertiary),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(width: 24),
              // 中：整体进度
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: idle
                        ? Text(
                            failed > 0 ? '$failed 个任务失败，可在「正在下载」里重试' : '队列空闲',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: failed > 0 ? Tokens.accent : p.textTertiary),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    formatBytes(got),
                                    style: TextStyle(fontSize: 12, color: p.textTertiary, fontFeatures: _tab),
                                  ),
                                  const Spacer(),
                                  Icon(Icons.south_rounded, size: 13, color: Tokens.accent),
                                  Text(
                                    ' ${formatBytes(speed)}/s',
                                    style: TextStyle(fontSize: 12, color: p.textSecondary, fontFeatures: _tab),
                                  ),
                                  const Spacer(),
                                  Text(
                                    total > 0 ? formatBytes(total) : '--',
                                    style: TextStyle(fontSize: 12, color: p.textTertiary, fontFeatures: _tab),
                                  ),
                                ],
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
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // 右：队列概况
              SizedBox(
                width: 240,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _Count(icon: Icons.downloading_rounded, n: running.length + queued, label: '进行中', page: 'downloading'),
                    const SizedBox(width: 16),
                    _Count(icon: Icons.task_alt_rounded, n: done.length, label: '已下载', page: 'finished'),
                  ],
                ),
              ),
              const SizedBox(width: 20),
            ],
          );
        },
      ),
    );
  }
}

const _tab = [FontFeature.tabularFigures()];

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.n, required this.label, required this.page});

  final IconData icon;
  final int n;
  final String label;
  final String page;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: label,
      child: Hover(
        onTap: () {
          AppState.I.platformFilter.value = null;
          AppState.I.page.value = page;
        },
        builder: (_, h) => Row(
          children: [
            Icon(icon, size: 20, color: h ? p.textPrimary : p.textSecondary),
            const SizedBox(width: 4),
            Text('$n', style: TextStyle(fontSize: 13, color: h ? p.textPrimary : p.textSecondary, fontFeatures: _tab)),
          ],
        ),
      ),
    );
  }
}
