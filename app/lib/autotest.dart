import 'dart:io';

import 'src/rust/api/core.dart' as core;
import 'src/rust/api/types.dart';
import 'state.dart';

/// 开发用：`WEDOWNLOAD_AUTOTEST=<链接>` 启动后自动解析并下载（跳过音乐），切到下载页；
/// `WEDOWNLOAD_PAGE=<页面>` 指定初始页面。用来在无法模拟点击的环境里检查界面。
Future<void> maybeRunAutotest() async {
  final page = Platform.environment['WEDOWNLOAD_PAGE'];
  if (page != null) AppState.I.page.value = page;
  final link = Platform.environment['WEDOWNLOAD_AUTOTEST'];
  if (link == null || link.isEmpty) return;
  // 记录页面切换，方便确认界面没有自己跳走
  AppState.I.page.addListener(() => stdout.writeln('[autotest] page -> ${AppState.I.page.value}'));
  try {
    final info = await core.extract(input: link);
    final picks = [
      for (var i = 0; i < info.items.length; i++)
        if (info.items[i].kind != UiMediaKind.audio) UiPick(item: i, variant: 0),
    ];
    await core.enqueue(key: info.key, picks: picks);
    AppState.I.page.value = 'downloading';
  } catch (e) {
    AppState.I.notify('自动测试失败：$e');
  }
}
