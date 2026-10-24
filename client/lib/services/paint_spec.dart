import 'dart:convert';

/// Paint message shared with Unity. Unity owns the PBR numbers.
class PaintSpec {
  static const finishes = ['gloss', 'matte', 'satin', 'metallic', 'candy', 'carbon'];
  static const panels = ['body', 'hood', 'roof', 'doors', 'mirrors'];

  static String normalizeFinish(String? value) {
    final token = (value ?? '').toLowerCase().trim();
    if (finishes.contains(token)) return token;
    if (token.contains('matte')) return 'matte';
    if (token.contains('satin')) return 'satin';
    if (token.contains('metallic') || token.contains('metal')) return 'metallic';
    if (token.contains('candy')) return 'candy';
    if (token.contains('carbon')) return 'carbon';
    if (token.contains('gloss')) return 'gloss';
    return 'gloss';
  }

  static String normalizePanel(String? value) {
    final token = (value ?? '').toLowerCase().trim();
    if (token == 'door' || token == 'doors') return 'doors';
    if (token == 'mirror' || token == 'mirrors') return 'mirrors';
    if (panels.contains(token)) return token;
    return 'body';
  }

  static String? hexFromBundle(String spec) {
    final match = RegExp(r'(?:color:)?#([0-9a-fA-F]{6})').firstMatch(spec);
    if (match == null) return null;
    return '#${match.group(1)!.toUpperCase()}';
  }

  static String? finishTag(String spec) {
    final match = RegExp(r'(?:^|;)finish:([a-zA-Z]+)').firstMatch(spec);
    return match?.group(1);
  }

  static String finishFrom(String spec, String name) {
    return normalizeFinish(finishTag(spec) ?? name);
  }

  static String colorToken(String spec, String name) {
    return hexFromBundle(spec) ?? name;
  }

  static bool validHex(String value) {
    return RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(value.trim());
  }

  static String normalizeHex(String value) {
    var token = value.trim();
    if (!token.startsWith('#')) token = '#$token';
    return '#${token.substring(1).toUpperCase()}';
  }

  static String message({
    required String color,
    required String finish,
    required String panel,
  }) {
    return jsonEncode({
      'color': color,
      'finish': normalizeFinish(finish),
      'panel': normalizePanel(panel),
    });
  }
}
