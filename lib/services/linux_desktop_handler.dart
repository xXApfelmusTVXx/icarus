import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The GTK application id (linux/CMakeLists.txt). The AppImage's desktop
/// entry, icons and MIME types are named after it.
const linuxApplicationId = 'xyz.icarus-strats';

typedef LinuxDesktopTool = Future<void> Function(
  String executable,
  List<String> arguments,
);

/// Makes the desktop hand icarus: links and .ica and .vrf files to the
/// AppImage that is running, the way the Windows build writes its protocol
/// key on every start. Without it the browser has nowhere to send a sign-in
/// back to.
///
/// Only an AppImage registers (APPIMAGE and APPDIR are set by its runtime):
/// a dev build or a bare bundle has no lasting path to point at. The entry is
/// a handler, not a menu item (NoDisplay): putting the AppImage in the menu
/// is the job of the user's AppImage integration tool, and a second entry
/// would show up beside that one.
///
/// Does nothing when the installed entry already points at this AppImage.
Future<void> registerLinuxDesktopHandler({
  required String scheme,
  Map<String, String>? environment,
  LinuxDesktopTool runTool = _runDesktopTool,
}) async {
  final env = environment ?? Platform.environment;
  final appImage = env['APPIMAGE'];
  final appDir = env['APPDIR'];
  if (appImage == null || appImage.isEmpty || appDir == null || appDir.isEmpty) {
    return;
  }
  final dataHome = _dataHome(env);
  if (dataHome == null) return;

  final packaged = p.join(appDir, 'usr', 'share');
  final template = await File(
    p.join(packaged, 'applications', '$linuxApplicationId.desktop'),
  ).readAsString();
  final entry = linuxDesktopHandlerEntry(template, appImagePath: appImage);
  if (entry == null) return;

  final entryFile = File(
    p.join(dataHome, 'applications', '$linuxApplicationId.desktop'),
  );
  if (await entryFile.exists() && await entryFile.readAsString() == entry) {
    return;
  }

  final icons = Directory(p.join(packaged, 'icons', 'hicolor'));
  if (await icons.exists()) {
    await for (final size in icons.list()) {
      final icon = File(p.join(size.path, 'apps', '$linuxApplicationId.png'));
      if (!await icon.exists()) continue;
      final target = File(p.join(dataHome, 'icons', 'hicolor',
          p.basename(size.path), 'apps', '$linuxApplicationId.png'));
      await target.parent.create(recursive: true);
      await icon.copy(target.path);
    }
  }

  final mimeTypes = File(
    p.join(packaged, 'mime', 'packages', '$linuxApplicationId.xml'),
  );
  final mimeTarget = File(
    p.join(dataHome, 'mime', 'packages', '$linuxApplicationId.xml'),
  );
  await mimeTarget.parent.create(recursive: true);
  await mimeTypes.copy(mimeTarget.path);

  // Last, so an entry matching this AppImage means everything above is done.
  await entryFile.parent.create(recursive: true);
  await entryFile.writeAsString(entry);

  await runTool('update-mime-database', [p.join(dataHome, 'mime')]);
  await runTool('update-desktop-database', [p.join(dataHome, 'applications')]);
  await runTool(
    'xdg-mime',
    ['default', '$linuxApplicationId.desktop', 'x-scheme-handler/$scheme'],
  );
}

/// The packaged desktop entry [template] made into a handler for the
/// AppImage at [appImagePath]: Exec and TryExec point at it, and NoDisplay
/// keeps it out of menus. Null when the path holds a control character, which
/// a desktop entry has no way to write.
String? linuxDesktopHandlerEntry(
  String template, {
  required String appImagePath,
}) {
  if (appImagePath.contains(RegExp(r'[\x00-\x1f\x7f]'))) return null;

  // Exec quoting first, then the string escape on top of it (Desktop Entry
  // Specification, "The Exec key"): a literal backslash ends up as four.
  final quoted = '"${appImagePath.replaceAllMapped(
    RegExp(r'[\\"`$]'),
    (match) => '\\${match[0]}',
  ).replaceAll('%', '%%')}"';
  String escapeString(String value) => value.replaceAll(r'\', r'\\');

  final lines = <String>[];
  for (final line in const LineSplitter().convert(template)) {
    if (line.startsWith('Exec=')) {
      lines
        ..add('Exec=${escapeString(quoted)} %U')
        ..add('TryExec=${escapeString(appImagePath)}');
    } else if (!line.startsWith('TryExec=') &&
        !line.startsWith('NoDisplay=')) {
      lines.add(line);
    }
  }
  lines.add('NoDisplay=true');
  return '${lines.join('\n')}\n';
}

String? _dataHome(Map<String, String> env) {
  final xdgDataHome = env['XDG_DATA_HOME'];
  if (xdgDataHome != null && p.isAbsolute(xdgDataHome)) return xdgDataHome;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.local', 'share');
}

Future<void> _runDesktopTool(String executable, List<String> arguments) async {
  try {
    await Process.run(executable, arguments);
  } on ProcessException {
    // Not every desktop has every tool. The entry and MIME files are in
    // place either way and are picked up when the desktop next rescans.
  }
}
