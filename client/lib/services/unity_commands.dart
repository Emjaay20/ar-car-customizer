import 'dart:convert';

import 'graphql_service.dart';

class UnityCommand {
  final String gameObject;
  final String method;
  final String argument;

  const UnityCommand({
    required this.gameObject,
    required this.method,
    required this.argument,
  });
}

class UnityCommands {
  static const gameObject = 'FlutterMessageReceiver';
  static const paintMethod = 'ChangePaintColor';
  static const loadMethod = 'LoadCarModel';
  static const attachMethod = 'AttachPart';
  static const liveTintMethod = 'SetLiveTint';
  static const bridgeMethod = 'ApplyBridgeFrame';
  static const sentisMethod = 'RunSentis';
  static const applyPaintMethod = 'ApplyPaint';
  static const snapshotMethod = 'CaptureSnapshot';
  static const anchorMethod = 'AnchorToSurface';

  static UnityCommand? forAsset({
    required String type,
    required String value,
    String? url,
    String? anchor,
  }) {
    if (type == 'PAINT') {
      return UnityCommand(
        gameObject: gameObject,
        method: paintMethod,
        argument: value,
      );
    }
    if (type != 'RIM' && type != 'SPOILER') return null;

    return UnityCommand(
      gameObject: gameObject,
      method: attachMethod,
      argument: jsonEncode({
        'type': type,
        'name': value,
        'url': url ?? '',
        'anchor': anchor ?? (type == 'SPOILER' ? 'trunk' : 'wheels'),
      }),
    );
  }

  static UnityCommand applyPaint(String json) {
    return UnityCommand(
      gameObject: gameObject,
      method: applyPaintMethod,
      argument: json,
    );
  }

  static UnityCommand captureSnapshot() {
    return const UnityCommand(
      gameObject: gameObject,
      method: snapshotMethod,
      argument: '',
    );
  }

  static UnityCommand anchorToSurface() {
    return const UnityCommand(
      gameObject: gameObject,
      method: anchorMethod,
      argument: '',
    );
  }

  static UnityCommand liveTint(String color) {
    return UnityCommand(
      gameObject: gameObject,
      method: liveTintMethod,
      argument: color,
    );
  }

  static UnityCommand bridgeFrame(String json) {
    return UnityCommand(
      gameObject: gameObject,
      method: bridgeMethod,
      argument: json,
    );
  }

  static String partUrl(String materialBundleUrl, {String? apiUrl}) {
    return GraphQLService.resolveUrl(materialBundleUrl, apiUrl: apiUrl);
  }
}

class MaskBridge {
  static Map<String, dynamic> absolutize(Map<String, dynamic> frame, {required String apiUrl}) {
    final copy = Map<String, dynamic>.from(frame);
    final mask = copy['maskPng'];
    if (mask is String) {
      copy['maskPng'] = GraphQLService.resolveUrl(mask, apiUrl: apiUrl);
    }
    return copy;
  }
}
