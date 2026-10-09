import 'dart:io';

import 'package:client/services/unity_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('http model URLs are copied locally before Unity sees them', () {
    expect(
      UnityFileCache.needsLocalCopy('http://192.168.100.66:3000/models/cesium-milk-truck.glb'),
      isTrue,
    );
    expect(UnityFileCache.needsLocalCopy('primitive:rim'), isFalse);
    expect(UnityFileCache.needsLocalCopy('file:///storage/model.glb'), isFalse);
  });

  test('bundled models use a jar URI Unity can read inside the APK', () {
    expect(
      UnityFileCache.bundledAssetName('http://192.168.100.66:3000/models/cesium-milk-truck.glb'),
      'cesium-milk-truck.glb',
    );
    expect(
      UnityFileCache.jarAssetUri(
        '/data/app/~~abc==/com.example.client/base.apk',
        'cesium-milk-truck.glb',
      ),
      'jar:file:///data/app/~~abc==/com.example.client/base.apk!/assets/cesium-milk-truck.glb',
    );
  });

  test('file URIs keep a leading slash for Unity on Android', () {
    expect(
      UnityFileCache.fileUri('/storage/emulated/0/Android/data/com.example.client/files/model.glb'),
      'file:///storage/emulated/0/Android/data/com.example.client/files/model.glb',
    );
  });

  test('cache names stay filesystem-safe', () {
    expect(
      UnityFileCache.cacheFileName(
        Uri.parse('http://192.168.100.66:3000/models/cesium-milk-truck.glb'),
      ),
      '192.168.100.66_3000_cesium-milk-truck.glb',
    );
  });

  test('a downloaded GLB is handed to Unity as a file URI', () async {
    final dir = await Directory.systemTemp.createTemp('unity-cache-test');
    addTearDown(() => dir.delete(recursive: true));
    final client = MockClient((request) async {
      return http.Response.bytes(<int>[0x67, 0x6c, 0x54, 0x46], 200);
    });

    final uri = await UnityFileCache.forUnity(
      'http://192.168.100.66:3000/models/cesium-milk-truck.glb',
      directory: dir,
      client: client,
    );

    expect(uri, contains('cesium-milk-truck.glb'));
    final saved = dir.listSync().whereType<File>().single;
    expect(saved.path, endsWith('cesium-milk-truck.glb'));
    expect(await saved.readAsBytes(), <int>[0x67, 0x6c, 0x54, 0x46]);
  });
}
