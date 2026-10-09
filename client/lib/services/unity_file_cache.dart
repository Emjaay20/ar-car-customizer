import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Unity's exported player rejects plain http:// downloads
/// ("Insecure connection not allowed"). Flutter can still fetch the LAN
/// backend, so cache the bytes and hand Unity a file:// URI instead.
class UnityFileCache {
  static const apkChannel = MethodChannel('ar_car/apk');

  /// Packed into the Android APK at assets/. UnityWebRequest can read this
  /// with a jar:file URI, which is not blocked by the HTTP player setting.
  static const bundledGlb = 'cesium-milk-truck.glb';

  static bool needsLocalCopy(String url) {
    return url.startsWith('http://') || url.startsWith('https://');
  }

  /// Unity's Android file loader wants `file://` plus an absolute path.
  static String? bundledAssetName(String url) {
    if (!needsLocalCopy(url)) return null;
    final name = Uri.parse(url).pathSegments.isEmpty ? '' : Uri.parse(url).pathSegments.last;
    if (name == bundledGlb) return name;
    return null;
  }

  /// Matches Unity's Android streaming-assets form: jar:file://<apk>!/assets/<name>
  static String jarAssetUri(String apkPath, String assetName) {
    return 'jar:file://$apkPath!/assets/$assetName';
  }

  static Future<String?> bundledJarUri(String url) async {
    if (!Platform.isAndroid) return null;
    final name = bundledAssetName(url);
    if (name == null) return null;
    try {
      final apk = await apkChannel.invokeMethod<String>('sourceDir');
      if (apk == null || apk.isEmpty) return null;
      return jarAssetUri(apk, name);
    } catch (_) {
      return null;
    }
  }

  static String fileUri(String absolutePath) {
    if (absolutePath.startsWith('file://')) return absolutePath;
    if (absolutePath.startsWith('/')) return 'file://$absolutePath';
    return Uri.file(absolutePath).toString();
  }

  static String cacheFileName(Uri uri) {
    final leaf = uri.pathSegments.isEmpty ? 'asset.bin' : uri.pathSegments.last;
    final safe = leaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final host = uri.host.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final port = uri.hasPort ? uri.port : 0;
    return '${host}_${port}_$safe';
  }

  static Future<String> forUnity(String url, {Directory? directory, http.Client? client}) async {
    if (!needsLocalCopy(url)) return url;

    final uri = Uri.parse(url);
    final dir = directory ?? await _cacheDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${cacheFileName(uri)}');
    if (!await file.exists() || await file.length() == 0) {
      final ownClient = client == null;
      final httpClient = client ?? http.Client();
      try {
        final response = await httpClient.get(uri);
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          throw Exception('Download failed (${response.statusCode}) for $url');
        }
        await file.writeAsBytes(response.bodyBytes, flush: true);
      } finally {
        if (ownClient) httpClient.close();
      }
    }
    return fileUri(file.path);
  }

  static Future<Directory> _cacheDirectory() async {
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) return Directory('${external.path}/unity-cache');
    }
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}/unity-cache');
  }
}
