import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/linux_desktop_handler.dart';
import 'package:path/path.dart' as p;

const _template = '''
[Desktop Entry]
Type=Application
Name=Icarus
Exec=icarus %U
Icon=xyz.icarus-strats
MimeType=x-scheme-handler/icarus;application/x-icarus-strategy;application/x-valorant-replay;
''';

void main() {
  group('linuxDesktopHandlerEntry', () {
    test('points Exec and TryExec at the AppImage and hides the entry', () {
      final entry = linuxDesktopHandlerEntry(
        _template,
        appImagePath: '/home/ana/Apps/Icarus-5.2.0-x86_64.AppImage',
      )!;

      expect(
        entry,
        contains('Exec="/home/ana/Apps/Icarus-5.2.0-x86_64.AppImage" %U\n'),
      );
      expect(
        entry,
        contains('TryExec=/home/ana/Apps/Icarus-5.2.0-x86_64.AppImage\n'),
      );
      expect(entry, endsWith('NoDisplay=true\n'));
      expect(entry, isNot(contains('Exec=icarus')));
      expect(entry, contains('MimeType=x-scheme-handler/icarus;'));
    });

    test('escapes what a quoted Exec argument cannot hold as it is', () {
      final entry = linuxDesktopHandlerEntry(
        _template,
        appImagePath: r'/home/ana/"$weird`\100%/Icarus.AppImage',
      )!;

      // Exec quoting puts a backslash before " $ ` \ and doubles %, then the
      // string escape doubles every backslash.
      expect(
        entry,
        contains(r'Exec="/home/ana/\\"\\$weird\\`\\\\100%%/Icarus.AppImage" %U'),
      );
      expect(entry, contains(r'TryExec=/home/ana/"$weird`\\100%/Icarus.AppImage'));
    });

    test('refuses a path with a control character', () {
      expect(
        linuxDesktopHandlerEntry(_template, appImagePath: '/tmp/a\nb.AppImage'),
        isNull,
      );
    });
  });

  group('registerLinuxDesktopHandler', () {
    late Directory root;
    late String appDir;
    late String dataHome;
    late List<List<String>> tools;

    Future<void> runTool(String executable, List<String> arguments) async {
      tools.add([executable, ...arguments]);
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('icarus_linux_handler_');
      appDir = p.join(root.path, 'AppDir');
      dataHome = p.join(root.path, 'data');
      tools = [];
      final share = p.join(appDir, 'usr', 'share');
      await File(p.join(share, 'applications', '$linuxApplicationId.desktop'))
          .create(recursive: true)
          .then((file) => file.writeAsString(_template));
      await File(p.join(share, 'mime', 'packages', '$linuxApplicationId.xml'))
          .create(recursive: true)
          .then((file) => file.writeAsString('<mime-info/>'));
      for (final size in ['64x64', '256x256']) {
        await File(p.join(
                share, 'icons', 'hicolor', size, 'apps', '$linuxApplicationId.png'))
            .create(recursive: true)
            .then((file) => file.writeAsString('png $size'));
      }
    });

    tearDown(() => root.delete(recursive: true));

    Map<String, String> appImageEnvironment(String appImage) => {
          'APPIMAGE': appImage,
          'APPDIR': appDir,
          'XDG_DATA_HOME': dataHome,
        };

    test('installs the entry, icons and MIME types, then refreshes the desktop',
        () async {
      await registerLinuxDesktopHandler(
        scheme: 'icarus',
        environment: appImageEnvironment('/opt/Icarus.AppImage'),
        runTool: runTool,
      );

      final entry = File(
          p.join(dataHome, 'applications', '$linuxApplicationId.desktop'));
      expect(await entry.readAsString(),
          contains('Exec="/opt/Icarus.AppImage" %U'));
      expect(
        await File(p.join(dataHome, 'icons', 'hicolor', '256x256', 'apps',
                '$linuxApplicationId.png'))
            .readAsString(),
        'png 256x256',
      );
      expect(
        await File(p.join(dataHome, 'mime', 'packages',
                '$linuxApplicationId.xml'))
            .exists(),
        isTrue,
      );
      expect(tools, [
        ['update-mime-database', p.join(dataHome, 'mime')],
        ['update-desktop-database', p.join(dataHome, 'applications')],
        ['xdg-mime', 'default', '$linuxApplicationId.desktop',
            'x-scheme-handler/icarus'],
      ]);
    });

    test('does nothing again for the same AppImage, and moves to a new one',
        () async {
      final env = appImageEnvironment('/opt/Icarus.AppImage');
      await registerLinuxDesktopHandler(
          scheme: 'icarus', environment: env, runTool: runTool);
      tools.clear();

      await registerLinuxDesktopHandler(
          scheme: 'icarus', environment: env, runTool: runTool);
      expect(tools, isEmpty);

      await registerLinuxDesktopHandler(
        scheme: 'icarus',
        environment: appImageEnvironment('/opt/Icarus-5.3.0.AppImage'),
        runTool: runTool,
      );
      expect(tools, hasLength(3));
      expect(
        await File(p.join(
                dataHome, 'applications', '$linuxApplicationId.desktop'))
            .readAsString(),
        contains('Exec="/opt/Icarus-5.3.0.AppImage" %U'),
      );
    });

    test('leaves the desktop alone outside an AppImage', () async {
      await registerLinuxDesktopHandler(
        scheme: 'icarus',
        environment: {'XDG_DATA_HOME': dataHome, 'HOME': root.path},
        runTool: runTool,
      );

      expect(await Directory(dataHome).exists(), isFalse);
      expect(tools, isEmpty);
    });
  });
}
