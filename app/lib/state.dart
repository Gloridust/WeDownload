import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/core.dart' as core;
import 'src/rust/api/types.dart';

/// 全局状态：设置、任务、解析结果、当前页面、提示消息。界面通过 ValueListenable 订阅。
class AppState {
  AppState._();
  static final I = AppState._();

  final settings = ValueNotifier<UiSettings?>(null);
  final tasks = ValueNotifier<List<UiTask>>(const []);
  final env = ValueNotifier<UiEnv?>(null);
  final page = ValueNotifier<String>('parse');
  final themeMode = ValueNotifier(ThemeMode.system);

  /// 已完成页按平台筛选（侧栏「平台」分组）
  final platformFilter = ValueNotifier<UiPlatform?>(null);

  final parse = ParseState();

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

  /// 从任意页面发起解析：切到解析页并开始
  void parseText(String text) {
    page.value = 'parse';
    parse.run(text);
  }

  // ---------- 剪贴板识别 ----------

  String? _lastClip;
  Timer? _clipTimer;

  /// 窗口在前台时每隔一会儿看一眼剪贴板；出现新的、属于已支持平台的链接就自动解析
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
    if (parse.busy.value) {
      parse.pending = text;
    } else {
      parseText(text);
    }
  }

  /// 程序自己读过 / 复制的文字不要再识别回来
  void ignoreClipboard(String text) => _lastClip = text;
}

/// 解析状态：输入、进行中、结果、错误，以及结果里的勾选与清晰度选择。
class ParseState extends ChangeNotifier {
  final input = TextEditingController();
  final busy = ValueNotifier(false);
  UiMediaInfo? result;
  String? error;

  /// 勾选的条目序号
  final selected = <int>{};

  /// 条目序号 → 选中的版本序号
  final variant = <int, int>{};

  /// 本次运行里解析过的作品（解析页空闲时显示）
  final history = <UiMediaInfo>[];

  /// 解析期间又识别到的链接，结束后接着解析
  String? pending;
  bool added = false;
  int _seq = 0;

  Future<void> run(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    input.text = text;
    if (core.findLink(text: text) == null) {
      error = '没有在输入里找到链接';
      result = null;
      notifyListeners();
      return;
    }
    final seq = ++_seq;
    busy.value = true;
    error = null;
    notifyListeners();
    try {
      final r = await core.extract(input: text);
      if (seq != _seq) return;
      show(r);
      history.removeWhere((h) => h.url == r.url);
      history.insert(0, r);
      if (history.length > 12) history.removeLast();
    } catch (e) {
      if (seq != _seq) return;
      error = cleanError(e);
      result = null;
    } finally {
      if (seq == _seq) {
        busy.value = false;
        notifyListeners();
        final next = pending;
        pending = null;
        if (next != null && next != text) run(next);
      }
    }
  }

  /// 显示一条解析结果（也用于从历史里重新打开）
  void show(UiMediaInfo r) {
    result = r;
    error = null;
    added = false;
    variant.clear();
    selected
      ..clear()
      ..addAll([
        for (var i = 0; i < r.items.length; i++)
          if (r.items[i].kind != UiMediaKind.audio) i,
      ]);
    notifyListeners();
  }

  void toggle(int i) {
    selected.contains(i) ? selected.remove(i) : selected.add(i);
    added = false;
    notifyListeners();
  }

  void toggleAll() {
    final r = result;
    if (r == null) return;
    if (selected.length == r.items.length) {
      selected.clear();
    } else {
      selected.addAll(List.generate(r.items.length, (i) => i));
    }
    added = false;
    notifyListeners();
  }

  void pick(int item, int v) {
    variant[item] = v;
    added = false;
    notifyListeners();
  }

  void clear() {
    _seq++;
    busy.value = false;
    result = null;
    error = null;
    input.clear();
    notifyListeners();
  }

  Future<void> download({List<int>? only}) async {
    final r = result;
    if (r == null) return;
    final items = only ?? (selected.toList()..sort());
    if (items.isEmpty) return;
    try {
      await core.enqueue(key: r.key, picks: [for (final i in items) UiPick(item: i, variant: variant[i] ?? 0)]);
      if (only == null) added = true;
      notifyListeners();
      AppState.I.notify('已加入下载队列（${items.length} 项）');
    } catch (e) {
      AppState.I.notify(cleanError(e));
    }
  }
}

String cleanError(Object e) {
  var s = e.toString();
  if (s.startsWith('AnyhowException(') && s.endsWith(')')) s = s.substring(16, s.length - 1);
  if (s.startsWith('Exception: ')) s = s.substring(11);
  // anyhow 的回溯信息只留第一行
  return s.split('\n\nStack backtrace').first.split('\n').first.trim();
}
