import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Size;
import 'package:gtk/gtk.dart';
import 'package:icarus/const/second_instance_args.dart';
import 'package:icarus/startup/windows_process_termination.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

bool get isWindowsRuntime => Platform.isWindows;

GtkApplicationNotifier? _linuxLaunches;

Future<void> ensureIcarusSingleInstance(
  List<String> args, {
  required String instanceId,
}) async {
  if (Platform.isLinux) {
    // GApplication keeps Icarus to one instance (linux/my_application.cc):
    // a second launch hands its arguments to this one and exits.
    _linuxLaunches ??= GtkApplicationNotifier()
      ..addCommandLineListener(_onLinuxSecondLaunch);
    return;
  }
  if (!Platform.isWindows) {
    return;
  }

  await WindowsSingleInstance.ensureSingleInstance(
    args,
    instanceId,
    onSecondWindow: publishSecondInstanceArgs,
    exitFunction: terminateDuplicateWindowsProcess,
  );
}

void _onLinuxSecondLaunch(List<String> args) {
  publishSecondInstanceArgs(args);
  unawaited(_bringWindowForward());
}

/// What windows_single_instance does on Windows when a second launch arrives.
Future<void> _bringWindowForward() async {
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
}

Future<void> initializeIcarusDesktopWindow(String title) async {
  await windowManager.ensureInitialized();
  final windowOptions = WindowOptions(
    size: const Size(1600, 900),
    minimumSize: const Size(1280, 720),
    center: true,
    title: title,
    // The app draws its own title strip (lib/widgets/window_chrome.dart).
    // macOS keeps its traffic lights; Windows and Linux get app-drawn
    // caption buttons.
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
