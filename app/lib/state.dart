import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/core.dart' as core;
import 'src/rust/api/types.dart';

/// 全局状态：设置、任务列表、当前页面、提示消息。界面通过 ValueListenable 订阅。
class AppState {
  AppState._();
  static final I = AppState._();

  final settings = ValueNotifier<UiSettings?>(null);
  final tasks = ValueNotifier<List<UiTask>>(const []);
  final env = ValueNotifier<UiEnv?>(null);
  final page = ValueNotifier<String>('parse');
  final themeMode = ValueNotifier(ThemeMode.system);

  /// 剪贴板里识别到的、还没处理的链接（解析页会接过去）
  final clipboardLink = ValueNotifier<String?>(null);

  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;
  void notify(String msg) => _notices.add(msg);

  Future<void> start() async {
    settings.value = core.settings();
    env.value = core.environment();
    tasks.value = core.tasks();
    _applyTheme();
    core.events().listen(_onEvent);
  }

  void _onEvent(UiEvent e) {
    switch (e) {
      case UiEvent_Task(:final field0):
        final list = [...tasks.value];
        final i = list.indexWhere((t) => t.id == field0.id);
        if (i < 0) {
          tasks.value = core.tasks();
          return;
        }
        final old = list[i];
        list[i] = field0;
        tasks.value = list;
        if (old.status != field0.status) {
          if (field0.status == UiTaskStatus.done) notify('下载完成：${field0.title}');
          if (field0.status == UiTaskStatus.failed) notify('下载失败：${field0.error ?? field0.title}');
        }
      case UiEvent_TasksChanged():
        tasks.value = core.tasks();
      case UiEvent_SettingsChanged():
        settings.value = core.settings();
        env.value = core.environment();
        _applyTheme();
    }
  }

  void _applyTheme() {
    themeMode.value = switch (settings.value?.theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> updateSettings(UiSettings Function(UiSettings s) f) async {
    final s = settings.value;
    if (s == null) return;
    final n = f(s);
    settings.value = n;
    _applyTheme();
    await core.updateSettings(s: n);
  }

  int get activeCount =>
      tasks.value.where((t) => t.status == UiTaskStatus.running || t.status == UiTaskStatus.queued).length;

  // ---------- 剪贴板识别 ----------

  String? _lastClip;
  Timer? _clipTimer;

  /// 窗口在前台时每隔一会儿看一眼剪贴板；出现新的、属于已支持平台的链接时交给解析页
  void watchClipboard(bool on) {
    _clipTimer?.cancel();
    _clipTimer = null;
    if (!on) return;
    _clipTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => checkClipboard());
  }

  Future<void> checkClipboard() async {
    if (!(settings.value?.watchClipboard ?? false)) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || text == _lastClip) return;
    _lastClip = text;
    final link = core.findLink(text: text);
    if (link == null || core.platformOf(url: link) == null) return;
    clipboardLink.value = text;
  }

  /// 程序自己复制的文字不要再识别回来
  void ignoreClipboard(String text) => _lastClip = text;
}
