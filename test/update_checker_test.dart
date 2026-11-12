import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Future<void> _openUpdateDialog(
  WidgetTester tester,
  UpdateCheckResult result,
) async {
  await tester.pumpWidget(
    ShadApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => UpdateChecker.showUpdateDialog(context, result),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The update status provider only asks the Store on Windows hosts.
final _storeOnlyOnWindows =
    Platform.isWindows ? false : 'Store update checks only run on Windows';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    UpdateChecker.fetchVersionInfoOverride = null;
    UpdateChecker.windowsStoreCheckOverride = null;
    UpdateChecker.fetchLinuxReleasesOverride = null;
  });

  test('windows native signal returns update available', () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': true,
        'isUpdateAvailable': true,
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '3.2.0',
        'current_version_number': '41',
        'release_notes': 'Store release notes',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.isSupported, isTrue);
    expect(result.isUpdateAvailable, isTrue);
    expect(result.source, 'windows_store');
    expect(result.remoteVersion, '3.2.0');
    expect(result.releaseNotes, 'Store release notes');
  });

  test('unsupported windows native signal falls back to remote update check',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': false,
        'isUpdateAvailable': false,
        'message': 'No package identity',
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '9.9.9',
        'current_version_number': '999',
        'release_notes': 'Test release',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'remote_version_file');
    expect(result.isSupported, isTrue);
    expect(result.isUpdateAvailable, isTrue);
    expect(result.remoteVersion, '9.9.9');
    expect(result.releaseNotes, 'Test release');
  });

  test('windows store-only signal returns store update when supported',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': true,
        'isUpdateAvailable': true,
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '3.2.0',
        'current_version_number': '41',
        'release_notes': 'Store release notes',
      };
    };

    final result = await UpdateChecker.checkForWindowsStoreUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isTrue);
    expect(result.isUpdateAvailable, isTrue);
    expect(result.remoteVersion, '3.2.0');
  });

  test('unsupported windows native signal returns windows result if remote fails',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': false,
        'isUpdateAvailable': false,
        'message': 'No package identity',
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async => null;

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, 'No package identity');
  });

  test('remote check handles invalid version number deterministically',
      () async {
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '3.1.3',
        'current_version_number': 'not-an-int',
        'release_notes': 'Bad payload',
      };
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: false,
      isLinuxOverride: false,
    );

    expect(result.source, 'remote_version_file');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
  });

  test('web never fetches the desktop version file', () async {
    var fetches = 0;
    UpdateChecker.fetchVersionInfoOverride = () async {
      fetches += 1;
      return <String, dynamic>{'current_version_number': '999'};
    };

    final update = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: true,
    );
    final storeUpdate = await UpdateChecker.checkForWindowsStoreUpdateSignal(
      isWebOverride: true,
    );

    expect(fetches, 0);
    for (final result in [update, storeUpdate]) {
      expect(result.isSupported, isFalse);
      expect(result.isUpdateAvailable, isFalse);
    }
  });

  group('linux', () {
    Map<String, Object?> release(
      String tag, {
      bool appImage = true,
      bool draft = false,
      bool prerelease = false,
      String downloadHost = 'github.com',
    }) =>
        {
          'tag_name': tag,
          'name': '$tag title',
          'draft': draft,
          'prerelease': prerelease,
          'body': '﻿- First change\r\n- Second change',
          'assets': [
            {
              'name': 'icarus-setup.exe',
              'browser_download_url':
                  'https://github.com/SunkenInTime/icarus/releases/download/$tag/icarus-setup.exe',
            },
            if (appImage)
              {
                'name': UpdateChecker.linuxAppImageAssetName,
                'browser_download_url':
                    'https://$downloadHost/SunkenInTime/icarus/releases/download/$tag/${UpdateChecker.linuxAppImageAssetName}',
              },
          ],
        };

    test('checks the GitHub releases, never the desktop version file',
        () async {
      var versionFileFetches = 0;
      var releaseFetches = 0;
      UpdateChecker.fetchVersionInfoOverride = () async {
        versionFileFetches += 1;
        return <String, dynamic>{'current_version_number': '999'};
      };
      UpdateChecker.fetchLinuxReleasesOverride = () async {
        releaseFetches += 1;
        return [release('desktop-stable-v99.0.0+9999')];
      };

      final update = await UpdateChecker.checkForUpdateSignal(
        isWebOverride: false,
        isWindowsOverride: false,
        isLinuxOverride: true,
      );
      final storeUpdate = await UpdateChecker.checkForWindowsStoreUpdateSignal(
        isWebOverride: false,
        isWindowsOverride: false,
        isLinuxOverride: true,
      );

      expect(versionFileFetches, 0);
      expect(releaseFetches, 2);
      for (final result in [update, storeUpdate]) {
        expect(result.source, 'linux');
        expect(result.isSupported, isTrue);
        expect(result.isUpdateAvailable, isTrue);
        expect(result.remoteVersion, '99.0.0');
      }
    });

    test('says the check failed when the releases could not be fetched',
        () async {
      UpdateChecker.fetchLinuxReleasesOverride = () async => null;

      final result = await UpdateChecker.checkForUpdateSignal(
        isWebOverride: false,
        isWindowsOverride: false,
        isLinuxOverride: true,
      );

      expect(result.source, 'linux');
      expect(result.isSupported, isFalse);
      expect(result.isUpdateAvailable, isFalse);
      expect(result.downloadUrl, isNull);
    });

    test('offers the newest stable release that has the AppImage', () {
      final result = UpdateChecker.linuxUpdateFromReleases(
        [
          // Newer, but each one is out of reach for a stable build.
          release('desktop-stable-v5.4.0+120', appImage: false),
          release('desktop-stable-v5.3.2+119', draft: true),
          release('desktop-prerelease-v5.3.1+118', prerelease: true),
          release('desktop-stable-v5.3.0+117', downloadHost: 'example.com'),
          release('5.3.0'),
          release('desktop-stable-v5.2.1+112'),
          release('desktop-stable-v5.2.0+111'),
        ],
        currentVersionNumber: 111,
        channel: 'stable',
      );

      expect(result.isSupported, isTrue);
      expect(result.isUpdateAvailable, isTrue);
      expect(result.remoteVersion, '5.2.1');
      expect(result.updateTitle, 'desktop-stable-v5.2.1+112 title');
      expect(result.releaseNotes, '- First change\n- Second change');
      expect(
        result.downloadUrl.toString(),
        'https://github.com/SunkenInTime/icarus/releases/download/'
        'desktop-stable-v5.2.1+112/icarus-x86_64.AppImage',
      );
    });

    test('a prerelease build also takes prereleases', () {
      final result = UpdateChecker.linuxUpdateFromReleases(
        [
          release('desktop-stable-v5.2.1+112'),
          release('desktop-prerelease-v5.3.1+118', prerelease: true),
        ],
        currentVersionNumber: 111,
        channel: 'prerelease',
      );

      expect(result.isUpdateAvailable, isTrue);
      expect(result.remoteVersion, '5.3.1');
    });

    test('no update when this build is the newest with an AppImage', () {
      final result = UpdateChecker.linuxUpdateFromReleases(
        [
          release('desktop-stable-v5.2.1+112', appImage: false),
          release('desktop-stable-v5.2.0+111'),
        ],
        currentVersionNumber: 111,
        channel: 'stable',
      );

      expect(result.isSupported, isTrue);
      expect(result.isUpdateAvailable, isFalse);
    });

    test('no update before any release carries an AppImage', () {
      final result = UpdateChecker.linuxUpdateFromReleases(
        [release('desktop-stable-v5.2.0+111', appImage: false)],
        currentVersionNumber: 100,
        channel: 'stable',
      );

      expect(result.isSupported, isTrue);
      expect(result.isUpdateAvailable, isFalse);
      expect(result.downloadUrl, isNull);
    });

    testWidgets('the update dialog downloads the AppImage', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      await _openUpdateDialog(
        tester,
        UpdateCheckResult(
          isSupported: true,
          isUpdateAvailable: true,
          source: 'linux',
          remoteVersion: '5.2.1',
          releaseNotes: '- A change',
          downloadUrl: Uri.parse(
            'https://github.com/SunkenInTime/icarus/releases/download/'
            'desktop-stable-v5.2.1+112/icarus-x86_64.AppImage',
          ),
        ),
      );

      expect(find.text(l10n.updateMsgDownload), findsOneWidget);
      expect(find.text(l10n.serviceMsgStoreUpdateNow), findsNothing);
      expect(
        find.textContaining(l10n.updateMsgLinuxDownloadHint,
            findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('the store dialog keeps its words', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      await _openUpdateDialog(
        tester,
        const UpdateCheckResult(
          isSupported: true,
          isUpdateAvailable: true,
          source: 'windows_store',
          remoteVersion: '5.2.1',
        ),
      );

      expect(find.text(l10n.serviceMsgStoreUpdateNow), findsOneWidget);
      expect(
        find.textContaining(l10n.updateMsgLinuxDownloadHint,
            findRichText: true),
        findsNothing,
      );
    });

    test('an unexpected payload is a failed check', () {
      final result = UpdateChecker.linuxUpdateFromReleases(
        {'message': 'API rate limit exceeded'},
        currentVersionNumber: 111,
        channel: 'stable',
      );

      expect(result.isSupported, isFalse);
      expect(result.isUpdateAvailable, isFalse);
    });
  });

  test('provider exposes update result from checker service', () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': true,
        'isUpdateAvailable': true,
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '9.9.9',
        'current_version_number': '999',
        'release_notes': 'Provider test release',
      };
    };

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(appUpdateStatusProvider.future);

    expect(result.source, 'windows_store');
    expect(result.isUpdateAvailable, isTrue);
    expect(result.releaseNotes, 'Provider test release');
  }, skip: _storeOnlyOnWindows);

  test('provider never falls back to the remote check without the Store',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': false,
        'isUpdateAvailable': false,
        'message': 'No package identity',
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      return <String, dynamic>{
        'current_version': '9.9.9',
        'current_version_number': '999',
        'release_notes': 'Remote release',
      };
    };

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result = await container.read(appUpdateStatusProvider.future);

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, 'No package identity');
  }, skip: _storeOnlyOnWindows);

  test('windows native checker exception returns safe non-crashing result',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      throw Exception('simulated native failure');
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, isNotNull);
  });

  test('windows native checker platform exception returns safe result',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      throw MissingPluginException('channel unavailable');
    };

    final result = await UpdateChecker.checkForUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, contains('not available'));
  });

  test('windows store-only signal returns unsupported result without remote',
      () async {
    UpdateChecker.windowsStoreCheckOverride = () async {
      return <String, dynamic>{
        'source': 'windows_store',
        'isSupported': false,
        'isUpdateAvailable': false,
        'message': 'No package identity',
      };
    };
    UpdateChecker.fetchVersionInfoOverride = () async {
      throw Exception('remote should not be used for store-only signal');
    };

    final result = await UpdateChecker.checkForWindowsStoreUpdateSignal(
      isWebOverride: false,
      isWindowsOverride: true,
    );

    expect(result.source, 'windows_store');
    expect(result.isSupported, isFalse);
    expect(result.isUpdateAvailable, isFalse);
    expect(result.message, 'No package identity');
  });
}
