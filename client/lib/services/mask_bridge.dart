import 'dart:convert';

import 'package:http/http.dart' as http;

import 'graphql_service.dart';
import 'unity_commands.dart';

class PublishedMask {
  final String json;
  final String? note;

  const PublishedMask({required this.json, this.note});
}

class PublishedMaskBridge {
  static Future<PublishedMask?> fetch({String? apiUrl}) async {
    final endpoint = apiUrl ?? GraphQLService.apiUrl;
    final url = GraphQLService.resolveUrl('/masks/bridge-frame.json', apiUrl: endpoint);
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('Mask bridge returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception('Mask bridge was not a JSON object');
    }
    final frame = Map<String, dynamic>.from(decoded);
    final note = frame['note'] as String?;
    final absolute = MaskBridge.absolutize(frame, apiUrl: endpoint);
    return PublishedMask(json: jsonEncode(absolute), note: note);
  }
}
