import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.isSupported,
    required this.isUpdateAvailable,
    required this.source,
    this.remoteVersion,
    this.updateTitle,
    this.releaseNotes,
    this.features,
    this.errorCode,
    this.message,
    this.downloadUrl,
  });

  final bool isSupported;
  final bool isUpdateAvailable;
  final String source;
  final String? remoteVersion;
  final String? updateTitle;
  final String? releaseNotes;
  final List<String>? features;
  final int? errorCode;
  final String? message;

  /// The file the update dialog downloads instead of opening a store. Set
  /// for Linux, where the update is a new AppImage.
  final Uri? downloadUrl;
}

class UpdateChecker {
  static const MethodChannel _channel = MethodChannel('icarus/update_checker');
  static const int appVersionNumber = Settings.versionNumber;
  static const String versionInfoUrl =
      'https://sunkenintime.github.io/icarus/version.json';
  static const String _windowsStoreSchemeUrl =
      'ms-windows-store://pdp/?productid=9PBWHHZRQFW6';

  /// Linux builds update from the GitHub Releases that Release Desktop
  /// attaches the AppImage to (docs/release_process.md, "Linux AppImage").
  static const String linuxReleasesUrl =
      'https://api.github.com/repos/SunkenInTime/icarus/releases?per_page=20';

  /// The AppImage's name in every release; build_linux_release.ps1 gives it.
  static const String linuxAppImageAssetName = 'icarus-x86_64.AppImage';

  static final RegExp _releaseTag =
      RegExp(r'^desktop-(stable|prerelease)-v(\d+\.\d+\.\d+)\+(\d+)$');

  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? fetchVersionInfoOverride;
  @visibleForTesting
  static Future<Map<String, dynamic>> Function()? windowsStoreCheckOverride;
  @visibleForTesting
  static Future<Object?> Function()? fetchLinuxReleasesOverride;

  /// The web build is always the deployed version; it has no updater, so it
  /// never fetches the desktop version file.
  static const _webResult = UpdateCheckResult(
    isSupported: false,
    isUpdateAvailable: false,
    source: 'web',
    message: 'The web build updates itself on reload.',
  );

  static Future<Map<String, dynamic>?> fetchVersionInfo() async {
    final fetchOverride = fetchVersionInfoOverride;
    if (fetchOverride != null) return fetchOverride();

    try {
      final response = await http.get(Uri.parse(versionInfoUrl));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        debugPrint('Failed to load version info: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Error fetching version info: $e');
      return null;
    }
  }

  static Future<UpdateCheckResult> checkForUpdateSignal({
    bool? isWebOverride,
    bool? isWindowsOverride,
    bool? isLinuxOverride,
  }) async {
    final bool isWeb = isWebOverride ?? kIsWeb;
    if (isWeb) return _webResult;
    final bool isWindows = isWindowsOverride ??
        ((!isWeb && Platform.isWindows) || windowsStoreCheckOverride != null);
    if (_isLinux(isWindows: isWindows, override: isLinuxOverride)) {
      return _checkLinuxReleaseSignal();
    }

    if (isWindows) {
      final windowsResult = await _checkWindowsStoreSignal();
      if (windowsResult.isSupported) {
        if (!windowsResult.isUpdateAvailable) {
          return windowsResult;
        }
        return _enrichResultWithRemoteInfo(windowsResult);
      }

      final remoteResult = await _checkRemoteVersionSignal();
      if (!remoteResult.isSupported) {
        return windowsResult;
      }
      return remoteResult;
    }

    return _checkRemoteVersionSignal();
  }

  static Future<UpdateCheckResult> checkForWindowsStoreUpdateSignal({
    bool? isWebOverride,
    bool? isWindowsOverride,
    bool? isLinuxOverride,
  }) async {
    final bool isWeb = isWebOverride ?? kIsWeb;
    if (isWeb) return _webResult;
    final bool isWindows = isWindowsOverride ??
        ((!isWeb && Platform.isWindows) || windowsStoreCheckOverride != null);
    if (_isLinux(isWindows: isWindows, override: isLinuxOverride)) {
      return _checkLinuxReleaseSignal();
    }

    if (!isWindows) {
      return _checkRemoteVersionSignal();
    }

    final windowsResult = await _checkWindowsStoreSignal();
    if (!windowsResult.isSupported || !windowsResult.isUpdateAvailable) {
      return windowsResult;
    }

    return _enrichResultWithRemoteInfo(windowsResult);
  }

  static Future<UpdateCheckResult> _checkWindowsStoreSignal() async {
    final callOverride = windowsStoreCheckOverride;

    try {
      final dynamic responseDynamic = callOverride != null
          ? await callOverride()
          : await _channel.invokeMethod<dynamic>('checkWindowsStoreUpdate');

      if (responseDynamic is! Map) {
        return const UpdateCheckResult(
          isSupported: false,
          isUpdateAvailable: false,
          source: 'windows_store',
          message: 'Unexpected Windows Store payload.',
        );
      }

      final response = Map<String, dynamic>.from(responseDynamic);
      return UpdateCheckResult(
        isSupported: response['isSupported'] == true,
        isUpdateAvailable: response['isUpdateAvailable'] == true,
        source: '${response['source'] ?? 'windows_store'}',
        errorCode: _toInt(response['errorCode']),
        message: response['message']?.toString(),
      );
    } on MissingPluginException {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        message: 'Windows Store checker plugin not available.',
      );
    } on PlatformException catch (e) {
      return UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        errorCode: e.code.isEmpty ? null : int.tryParse(e.code),
        message: e.message,
      );
    } catch (e) {
      return UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'windows_store',
        message: '$e',
      );
    }
  }

  static Future<UpdateCheckResult> _checkRemoteVersionSignal() async {
    final versionInfo = await fetchVersionInfo();
    if (versionInfo == null) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'remote_version_file',
        message: 'Version info unavailable.',
      );
    }

    final int? remoteVersionNumber = _extractVersionNumber(versionInfo);
    if (remoteVersionNumber == null) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'remote_version_file',
        message: 'Invalid remote version number.',
      );
    }

    return UpdateCheckResult(
      isSupported: true,
      isUpdateAvailable: remoteVersionNumber > appVersionNumber,
      source: 'remote_version_file',
      remoteVersion: _extractVersionName(versionInfo),
      updateTitle: _extractUpdateTitle(versionInfo),
      releaseNotes: _extractReleaseNotes(versionInfo),
      features: _extractFeatures(versionInfo),
    );
  }

  static Future<UpdateCheckResult> _enrichResultWithRemoteInfo(
      UpdateCheckResult baseResult) async {
    final versionInfo = await fetchVersionInfo();
    if (versionInfo == null) {
      return baseResult;
    }

    return UpdateCheckResult(
      isSupported: baseResult.isSupported,
      isUpdateAvailable: baseResult.isUpdateAvailable,
      source: baseResult.source,
      remoteVersion: _extractVersionName(versionInfo),
      updateTitle: _extractUpdateTitle(versionInfo),
      releaseNotes: _extractReleaseNotes(versionInfo),
      features: _extractFeatures(versionInfo),
      errorCode: baseResult.errorCode,
      message: baseResult.message,
    );
  }

  static Future<UpdateCheckResult> _checkLinuxReleaseSignal() async {
    final releases = await _fetchLinuxReleases();
    if (releases == null) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'linux',
        message: 'Linux releases unavailable.',
      );
    }
    return linuxUpdateFromReleases(
      releases,
      currentVersionNumber: appVersionNumber,
      channel: kResolvedUpdateChannel,
    );
  }

  static Future<Object?> _fetchLinuxReleases() async {
    final fetchOverride = fetchLinuxReleasesOverride;
    if (fetchOverride != null) return fetchOverride();

    try {
      final response = await http.get(
        Uri.parse(linuxReleasesUrl),
        headers: const {'Accept': 'application/vnd.github+json'},
      );
      if (response.statusCode != 200) {
        debugPrint('Failed to load Linux releases: ${response.statusCode}');
        return null;
      }
      return json.decode(response.body);
    } catch (e) {
      debugPrint('Error fetching Linux releases: $e');
      return null;
    }
  }

  /// The newest published release this Linux build can update to: one with
  /// the AppImage attached, on the build's channel. A stable build takes
  /// stable releases only; a prerelease build takes both. Releases from
  /// before Linux shipped carry no AppImage and are never offered.
  @visibleForTesting
  static UpdateCheckResult linuxUpdateFromReleases(
    Object? releases, {
    required int currentVersionNumber,
    required String channel,
  }) {
    if (releases is! List) {
      return const UpdateCheckResult(
        isSupported: false,
        isUpdateAvailable: false,
        source: 'linux',
        message: 'Unexpected GitHub releases payload.',
      );
    }

    Map<dynamic, dynamic>? newest;
    int newestBuild = -1;
    Uri? newestDownload;
    String? newestVersion;
    for (final release in releases.whereType<Map<dynamic, dynamic>>()) {
      if (release['draft'] == true) continue;
      final tag = _releaseTag.firstMatch('${release['tag_name']}');
      if (tag == null) continue;
      final isStable = tag.group(1) == 'stable' && release['prerelease'] != true;
      if (channel == 'stable' && !isStable) continue;
      final download = _linuxAppImageUrl(release['assets']);
      if (download == null) continue;
      final build = int.parse(tag.group(3)!);
      if (build <= newestBuild) continue;
      newest = release;
      newestBuild = build;
      newestDownload = download;
      newestVersion = tag.group(2);
    }

    if (newest == null) {
      return const UpdateCheckResult(
        isSupported: true,
        isUpdateAvailable: false,
        source: 'linux',
      );
    }
    final title = '${newest['name'] ?? ''}'.trim();
    return UpdateCheckResult(
      isSupported: true,
      isUpdateAvailable: newestBuild > currentVersionNumber,
      source: 'linux',
      remoteVersion: newestVersion,
      updateTitle: title.isEmpty ? null : title,
      // The release script writes the notes with a byte order mark and
      // Windows line ends.
      releaseNotes: '${newest['body'] ?? ''}'
          .replaceAll('﻿', '')
          .replaceAll('\r', '')
          .trim(),
      downloadUrl: newestDownload,
    );
  }

  /// The AppImage's download link, only from GitHub itself: the dialog opens
  /// it in the browser.
  static Uri? _linuxAppImageUrl(Object? assets) {
    if (assets is! List) return null;
    for (final asset in assets.whereType<Map<dynamic, dynamic>>()) {
      if (asset['name'] != linuxAppImageAssetName) continue;
      final url = Uri.tryParse('${asset['browser_download_url']}');
      if (url != null && url.scheme == 'https' && url.host == 'github.com') {
        return url;
      }
    }
    return null;
  }

  static void showUpdateDialog(BuildContext context, UpdateCheckResult result) {
    final l10n = context.l10n;
    final String remoteVersion = result.remoteVersion ?? Settings.versionName;
    final String titleText =
        (result.updateTitle != null && result.updateTitle!.trim().isNotEmpty)
            ? result.updateTitle!
            : l10n.serviceMsgStoreUpdateVersionAvailable(remoteVersion);
    final String releaseNotes =
        result.releaseNotes ?? l10n.serviceMsgStoreUpdateDefaultNotes;
    final List<String> features = result.features ?? const <String>[];
    final Uri? downloadUrl = result.downloadUrl;

    showDialog(
      context: context,
      builder: (BuildContext context) => ShadDialog.alert(
        title: Text(l10n.serviceMsgStoreUpdateTitle),
        description: Text.rich(
          TextSpan(
            text: '$titleText\n\n',
            children: [
              TextSpan(text: '${l10n.serviceMsgStoreUpdateReleaseNotes}\n'),
              TextSpan(text: '$releaseNotes\n'),
              if (features.isNotEmpty)
                TextSpan(text: '\n${l10n.serviceMsgStoreUpdateWhatsNew}\n'),
              if (features.isNotEmpty)
                TextSpan(
                  text: features.map((feature) => '- $feature').join('\n'),
                ),
              if (downloadUrl != null)
                TextSpan(text: '\n${l10n.updateMsgLinuxDownloadHint}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: Text(l10n.serviceMsgStoreUpdateLater),
          ),
          TextButton(
            onPressed: () async {
              final Uri updateUri = downloadUrl ??
                  ((result.source == 'windows_store')
                      ? Uri.parse(_windowsStoreSchemeUrl)
                      : Settings.windowsStoreLink);
              await launchUrl(updateUri);
              if (!context.mounted) return;

              Navigator.of(context).pop();
            },
            child: Text(
              downloadUrl != null
                  ? l10n.updateMsgDownload
                  : l10n.serviceMsgStoreUpdateNow,
            ),
          ),
        ],
      ),
    );
  }

  /// Decided after Windows, so a test standing in for the Store on a Linux
  /// host still takes the Windows path.
  static bool _isLinux({required bool isWindows, bool? override}) =>
      override ?? (!isWindows && Platform.isLinux);

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  static int? _extractVersionNumber(Map<String, dynamic> versionInfo) {
    return _toInt(
      versionInfo['current_version_number'] ?? versionInfo['version_number'],
    );
  }

  static String? _extractVersionName(Map<String, dynamic> versionInfo) {
    return versionInfo['current_version']?.toString() ??
        versionInfo['version']?.toString();
  }

  static String? _extractUpdateTitle(Map<String, dynamic> versionInfo) {
    return versionInfo['update_title']?.toString() ??
        versionInfo['release_title']?.toString();
  }

  static String? _extractReleaseNotes(Map<String, dynamic> versionInfo) {
    return versionInfo['release_notes']?.toString() ??
        versionInfo['description']?.toString();
  }

  static List<String>? _extractFeatures(Map<String, dynamic> versionInfo) {
    final dynamic rawFeatures =
        versionInfo['list_of_features'] ?? versionInfo['features'];
    if (rawFeatures is! List) return null;

    final List<String> features = rawFeatures
        .map((feature) => feature?.toString().trim() ?? '')
        .where((feature) => feature.isNotEmpty)
        .toList();
    return features.isEmpty ? null : features;
  }
}
