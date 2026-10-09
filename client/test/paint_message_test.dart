import 'package:client/services/graphql_service.dart';
import 'package:client/services/paint_spec.dart';
import 'package:client/services/unity_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paint selection sends ChangePaintColor with the color name', () {
    final command = UnityCommands.forAsset(
      type: 'PAINT',
      value: 'Gloss Black',
    );

    expect(command, isNotNull);
    expect(command!.gameObject, 'FlutterMessageReceiver');
    expect(command.method, 'ChangePaintColor');
    expect(command.argument, 'Gloss Black');
  });

  test('rim selection attaches a stand-in at the wheel anchors', () {
    final command = UnityCommands.forAsset(
      type: 'RIM',
      value: '18-inch Civic Si',
      url: 'primitive:rim',
      anchor: 'wheels',
    );

    expect(command, isNotNull);
    expect(command!.method, 'AttachPart');
    expect(command.argument, contains('"type":"RIM"'));
    expect(command.argument, contains('primitive:rim'));
    expect(command.argument, contains('"anchor":"wheels"'));
  });

  test('model paths resolve against API_URL instead of a hardcoded LAN IP', () {
    expect(
      GraphQLService.resolveUrl(
        '/models/cesium-milk-truck.glb',
        apiUrl: 'http://10.0.0.8:3000/graphql',
      ),
      'http://10.0.0.8:3000/models/cesium-milk-truck.glb',
    );
  });

  test('part descriptors are not rewritten into API paths', () {
    expect(
      GraphQLService.resolveUrl('primitive:rim', apiUrl: 'http://10.0.0.8:3000/graphql'),
      'primitive:rim',
    );
  });

  test('published mask paths are rewritten before Unity sees them', () {
    final frame = MaskBridge.absolutize(
      {'maskPng': '/masks/paint-mask.png', 'points': []},
      apiUrl: 'http://10.0.0.8:3000/graphql',
    );

    expect(frame['maskPng'], 'http://10.0.0.8:3000/masks/paint-mask.png');
  });

  test('catalog finish tags survive a longer color bundle', () {
    expect(PaintSpec.hexFromBundle('color:#1c1c1c;finish:matte'), '#1C1C1C');
    expect(PaintSpec.finishFrom('color:#d0122d;finish:candy', 'Candy Red'), 'candy');
    expect(PaintSpec.finishFrom('color:#b7b7be', 'Metallic Silver'), 'metallic');
  });

  test('custom paint is a JSON payload Unity can parse', () {
    final command = UnityCommands.applyPaint(PaintSpec.message(
      color: '#1C1C1C',
      finish: 'matte',
      panel: 'hood',
    ));

    expect(command.method, 'ApplyPaint');
    expect(command.argument, '{"color":"#1C1C1C","finish":"matte","panel":"hood"}');
  });

  test('photo share and floor anchor are explicit Unity calls', () {
    expect(UnityCommands.captureSnapshot().method, 'CaptureSnapshot');
    expect(UnityCommands.anchorToSurface().method, 'AnchorToSurface');
  });
}
