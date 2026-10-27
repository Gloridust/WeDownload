import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'autotest.dart';
import 'src/rust/api/core.dart' as core;
import 'src/rust/frb_generated.dart';
import 'state.dart';
import 'theme.dart';
import 'ui/brand.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // 开发用：WEDOWNLOAD_DATA_DIR 指向独立目录即可得到一个全新的环境
  await core.bootstrap(dataDir: Platform.environment['WEDOWNLOAD_DATA_DIR']);

  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 800),
        minimumSize: Size(560, 520),
        center: true,
        title: kAppName,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    // 关窗口前停掉下载、关闭解析用的浏览器
    await windowManager.setPreventClose(true);
    windowManager.addListener(_CloseHandler());
  }

  await AppState.I.start();
  AppState.I.watchClipboard(true);
  runApp(const WeDownloadApp());
  maybeRunAutotest();
}

class _CloseHandler with WindowListener {
  @override
  void onWindowClose() async {
    await core.shutdown().timeout(const Duration(seconds: 3), onTimeout: () {});
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}

class WeDownloadApp extends StatelessWidget {
  const WeDownloadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppState.I.themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: const Shell(),
      ),
    );
  }
}
