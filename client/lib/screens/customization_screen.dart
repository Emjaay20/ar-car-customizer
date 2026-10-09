import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/asset.dart';
import '../models/car.dart';
import '../services/auth_session.dart';
import '../services/graphql_service.dart';
import '../services/mask_bridge.dart';
import '../services/paint_spec.dart';
import '../services/unity_commands.dart';
import '../services/unity_file_cache.dart';

class CustomizationScreen extends StatefulWidget {
  final Car car;

  const CustomizationScreen({super.key, required this.car});

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  final Map<String, Asset> _selected = {};
  UnityWidgetController? _unityController;
  String? _unityStatus;
  String? _savedConfigId;
  bool _saving = false;
  bool _sharingPhoto = false;
  String _finish = 'gloss';
  String _panel = 'body';
  String? _paintColor;
  final _hex = TextEditingController();

  static const String getAssetsQuery = r'''
    query AssetsForCar($carId: ID!) {
      assetsForCar(carId: $carId) {
        id
        name
        type
        price
        materialBundleUrl
        anchor
      }
    }
  ''';

  static const String saveConfigMutation = r'''
    mutation Save($input: SaveConfigurationInput!) {
      saveConfiguration(input: $input) {
        id
        status
        name
      }
    }
  ''';

  static const String shareMutation = r'''
    mutation Share($id: ID!) {
      shareConfiguration(id: $id) {
        id
        shareToken
      }
    }
  ''';

  Future<void> _loadPreview(UnityWidgetController controller, String meshUrl) async {
    setState(() => _unityStatus = 'Downloading preview model…');
    String argument;
    try {
      argument = await UnityFileCache.bundledJarUri(meshUrl) ??
          await UnityFileCache.forUnity(meshUrl);
    } catch (_) {
      if (!mounted) return;
      setState(() => _unityStatus = 'Preview model did not download.');
      _snack('Could not download the preview model. Is the backend running?');
      return;
    }
    if (!mounted || _unityController != controller) return;
    controller.postMessage(
      UnityCommands.gameObject,
      UnityCommands.loadMethod,
      argument,
    );
  }

  void _post(UnityCommand? command) {
    if (command == null || _unityController == null) return;
    _unityController!.postMessage(command.gameObject, command.method, command.argument);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _select(Asset asset) {
    if (asset.type == 'PAINT') {
      final finish = PaintSpec.finishFrom(asset.materialBundleUrl, asset.name);
      final color = PaintSpec.colorToken(asset.materialBundleUrl, asset.name);
      setState(() {
        _selected[asset.type] = asset;
        _finish = finish;
        _paintColor = color;
      });
      _sendPaint(color: color, finish: finish, panel: _panel);
      return;
    }

    setState(() => _selected[asset.type] = asset);
    _post(UnityCommands.forAsset(
      type: asset.type,
      value: asset.name,
      url: UnityCommands.partUrl(asset.materialBundleUrl),
      anchor: asset.anchor,
    ));
  }

  void _sendPaint({
    required String color,
    required String finish,
    required String panel,
  }) {
    _post(UnityCommands.applyPaint(PaintSpec.message(
      color: color,
      finish: finish,
      panel: panel,
    )));
  }

  void _applyCurrentPaint() {
    final color = _paintColor;
    if (color == null || color.isEmpty) return;
    _sendPaint(color: color, finish: _finish, panel: _panel);
  }

  void _applyHex() {
    final raw = _hex.text.trim();
    if (!PaintSpec.validHex(raw)) {
      _snack('Enter a 6-digit hex color, like #1C1C1C.');
      return;
    }
    final color = PaintSpec.normalizeHex(raw);
    setState(() {
      _paintColor = color;
      _selected.remove('PAINT');
    });
    _sendPaint(color: color, finish: _finish, panel: _panel);
  }

  Future<void> _shareSnapshot(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      _snack('The AR photo was not written.');
      return;
    }
    try {
      await Share.shareXFiles(
        [XFile(path)],
        text:
            'AR paint preview · ${widget.car.year} ${widget.car.make} ${widget.car.model} · $_finish $_panel',
      );
    } catch (error) {
      if (!mounted) return;
      _snack('Could not open the share sheet: $error');
    }
  }

  Future<void> _saveConfig() async {
    if (!AuthSession.isLoggedIn) {
      _snack('Log in again before saving.');
      return;
    }
    if (_selected.isEmpty) {
      _snack('Pick a part first.');
      return;
    }

    setState(() => _saving = true);
    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(
        document: gql(saveConfigMutation),
        variables: {
          'input': {
            'carId': widget.car.id,
            'assetIds': _selected.values.map((asset) => asset.id).toList(),
            'status': 'DRAFT',
            'name': '${widget.car.year} ${widget.car.make} ${widget.car.model}',
          },
        },
      ),
    );

    if (!mounted) return;
    setState(() => _saving = false);
    if (result.hasException) {
      final message = result.exception?.graphqlErrors.isNotEmpty == true
          ? result.exception!.graphqlErrors.first.message
          : '${result.exception}';
      _snack('Save failed: $message');
      return;
    }
    final id = result.data?['saveConfiguration']?['id'];
    setState(() => _savedConfigId = id is String ? id : _savedConfigId);
    _snack('Saved to your garage.');
  }

  Future<void> _share() async {
    final id = _savedConfigId;
    if (id == null) {
      _snack('Save the configuration before sharing.');
      return;
    }
    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(document: gql(shareMutation), variables: {'id': id}),
    );
    if (!mounted) return;
    final token = result.data?['shareConfiguration']?['shareToken'];
    if (result.hasException || token is! String) {
      _snack('Could not create a share code.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _snack('Share code copied. It opens this car, not a video.');
  }

  Future<void> _loadPublishedMask() async {
    try {
      final published = await PublishedMaskBridge.fetch();
      if (!mounted) return;
      if (published == null) {
        _snack('No published mask. Run: python ml/segment_car.py --synthetic --publish');
        return;
      }
      final frame = jsonDecode(published.json);
      if (frame is Map && frame['maskPng'] is String) {
        frame['maskPng'] = await UnityFileCache.forUnity(frame['maskPng'] as String);
      }
      _post(UnityCommands.bridgeFrame(frame is Map ? jsonEncode(frame) : published.json));
      final note = published.note;
      _snack(note == null || note.isEmpty
          ? 'Published mask sent to the camera overlay.'
          : note);
    } catch (error) {
      if (!mounted) return;
      _snack('Mask bridge failed: $error');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _statusLabel(String text) {
    if (text.startsWith('MODEL_LOADED')) return 'Preview model loaded.';
    if (text.startsWith('MODEL_FAILED')) return 'Preview model did not load.';
    if (text.startsWith('PAINT_APPLIED')) return 'Paint applied. Finish follows the room light on the preview.';
    if (text.startsWith('PAINT_QUEUED')) return 'Paint queued until the preview model loads.';
    if (text.startsWith('ANCHORED:plane')) return 'Preview is sitting on a detected floor.';
    if (text.startsWith('ANCHORED:camera')) return 'No floor yet. The whole vehicle stays in front of the camera.';
    if (text.startsWith('ANCHOR_SEARCHING')) return 'Looking for a floor in front of the camera.';
    if (text.startsWith('SNAPSHOT:')) return 'AR photo ready to share.';
    return text;
  }

  void _onUnityMessage(dynamic message) {
    final text = message.toString();
    if (text.startsWith('SNAPSHOT:')) {
      setState(() {
        _sharingPhoto = false;
        _unityStatus = _statusLabel(text);
      });
      _shareSnapshot(text.substring('SNAPSHOT:'.length));
      return;
    }
    if (text.startsWith('SNAPSHOT_FAILED')) {
      setState(() => _sharingPhoto = false);
    }
    setState(() => _unityStatus = _statusLabel(text));
    if (text.startsWith('MODEL_FAILED')) {
      _snack('Preview model did not load. Showing a stand-in car.');
    } else if (text.startsWith('MODEL_LOADED')) {
      _snack('Preview model loaded. Look ahead of the phone to see it.');
    } else if (text.startsWith('PAINT_NO_BODY')) {
      _snack('Model loaded, but no body material was found to paint.');
    } else if (text.startsWith('MASK_FAILED') ||
        text.startsWith('SENTIS_') ||
        text.startsWith('PART_FAILED') ||
        text.startsWith('SNAPSHOT_FAILED') ||
        text.startsWith('ANCHOR_FAILED')) {
      _snack(text);
    }
  }

  Color _swatch(Asset asset) {
    final hex = PaintSpec.hexFromBundle(asset.materialBundleUrl);
    if (hex != null) {
      final value = int.tryParse(hex.substring(1), radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final meshUrl = GraphQLService.resolveUrl(widget.car.baseMeshUrl);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.car.year} ${widget.car.make} ${widget.car.model}'),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: ColoredBox(
              color: Colors.black,
              child: UnityWidget(
                onUnityCreated: (controller) {
                  _unityController = controller;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _loadPreview(controller, meshUrl);
                  });
                },
                onUnityMessage: _onUnityMessage,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  child: Query(
                    options: QueryOptions(
                      document: gql(getAssetsQuery),
                      variables: {'carId': widget.car.id},
                    ),
                    builder: (result, {refetch, fetchMore}) {
                      if (result.isLoading && result.data == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (result.hasException) {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Error: ${result.exception}'),
                        );
                      }

                      final assets = ((result.data?['assetsForCar'] ?? []) as List)
                          .whereType<Map>()
                          .map((json) => Asset.fromJson(Map<String, dynamic>.from(json)))
                          .toList();
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        children: [
                          const Text(
                            'Finishes show on the preview immediately. Gloss, candy, and metallic pick up room light. Hood, roof, and doors are regions on the preview, not a scan of those panels. Camera tint still waits for a mask, then crops to the selected region.',
                            style: TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                          if (_unityStatus != null)
                            Text(_unityStatus!, style: const TextStyle(fontSize: 11, color: Colors.black45)),
                          const SizedBox(height: 8),
                          _choiceRow('Finish', PaintSpec.finishes, _finish, (value) {
                            setState(() => _finish = value);
                            _applyCurrentPaint();
                          }),
                          _choiceRow('Panel', PaintSpec.panels, _panel, (value) {
                            setState(() => _panel = value);
                            _applyCurrentPaint();
                          }),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _hex,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Custom hex',
                                    hintText: '#1C1C1C',
                                  ),
                                  textCapitalization: TextCapitalization.characters,
                                  onSubmitted: (_) => _applyHex(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _unityController == null ? null : _applyHex,
                                child: const Text('Apply'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _section('Paint', assets.where((asset) => asset.type == 'PAINT'), paint: true),
                          _section('Rims', assets.where((asset) => asset.type == 'RIM')),
                          _section('Spoilers', assets.where((asset) => asset.type == 'SPOILER')),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: _unityController == null ? null : _loadPublishedMask,
                            child: const Text('Apply published segmentation mask'),
                          ),
                          OutlinedButton(
                            onPressed: _unityController == null
                                ? null
                                : () => _unityController!.postMessage(
                                      UnityCommands.gameObject,
                                      UnityCommands.sentisMethod,
                                      '',
                                    ),
                            child: const Text('Run on-device segmentation'),
                          ),
                          OutlinedButton(
                            onPressed: _unityController == null ? null : () => _post(UnityCommands.anchorToSurface()),
                            child: const Text('Sit preview on detected floor'),
                          ),
                          OutlinedButton(
                            onPressed: _unityController == null || _sharingPhoto
                                ? null
                                : () {
                                    setState(() => _sharingPhoto = true);
                                    _post(UnityCommands.captureSnapshot());
                                    Future<void>.delayed(const Duration(seconds: 4), () {
                                      if (!mounted || !_sharingPhoto) return;
                                      setState(() => _sharingPhoto = false);
                                      _snack('No photo came back. Re-export Unity if this phone build is old.');
                                    });
                                  },
                            child: Text(_sharingPhoto ? 'Saving photo…' : 'Save AR photo'),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _saving ? null : _saveConfig,
                          child: Text(_saving ? 'Saving' : 'Save to garage'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _share,
                          child: const Text('Share code'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceRow(String title, List<String> values, String selected, ValueChanged<String> onPick) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: values.map((value) {
              final on = value == selected;
              final label = value[0].toUpperCase() + value.substring(1);
              return ChoiceChip(
                label: Text(label),
                selected: on,
                onSelected: _unityController == null ? null : (_) => onPick(value),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, Iterable<Asset> assets, {bool paint = false}) {
    final rows = assets.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Text('None fitted to this car.', style: TextStyle(color: Colors.grey, fontSize: 12))
        else if (paint)
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: rows.map(_paintSwatch).toList(),
          )
        else
          ...rows.map(_partTile),
      ],
    );
  }

  Widget _paintSwatch(Asset asset) {
    final selected = _selected[asset.type]?.id == asset.id;
    return GestureDetector(
      onTap: () => _select(asset),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _swatch(asset),
              borderRadius: BorderRadius.circular(8),
              border: selected ? Border.all(color: Colors.blue, width: 3) : null,
            ),
            child: selected ? const Icon(Icons.check, color: Colors.white) : null,
          ),
          const SizedBox(height: 4),
          Text(asset.name, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _partTile(Asset asset) {
    final selected = _selected[asset.type]?.id == asset.id;
    final standIn = asset.materialBundleUrl.startsWith('primitive:');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: selected,
      title: Text(asset.name),
      subtitle: Text(
        standIn
            ? 'Stand-in shape · ₦${asset.price.toStringAsFixed(0)}'
            : '₦${asset.price.toStringAsFixed(0)}',
      ),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => _select(asset),
    );
  }
}
