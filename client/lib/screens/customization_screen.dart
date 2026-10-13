import 'dart:async';
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
import '../services/paint_spec.dart';
import '../services/unity_commands.dart';

enum ArLockState { searching, capturing, locked, updating, released }

class CustomizationScreen extends StatefulWidget {
  final Car car;
  final bool isUniversalMode;
  final String? initialVehicleLabel;

  const CustomizationScreen({
    super.key,
    required this.car,
    this.isUniversalMode = false,
    this.initialVehicleLabel,
  });

  @override
  State<CustomizationScreen> createState() => _CustomizationScreenState();
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  final Map<String, Asset> _selected = {};
  List<Asset> _catalogAssets = const [];
  UnityWidgetController? _unityController;
  String? _unityStatus = 'Hold steady to lock preview';
  String? _savedConfigId;
  String? _customVehicleTitle;
  bool _saving = false;
  bool _sharingPhoto = false;
  bool _capturingForMask = false;
  bool _capturingForStudioShare = false;
  bool _maskingBusy = false;
  bool _hasActiveMask = false;
  bool _sentisLiveActive = false;
  ArLockState _lockState = ArLockState.searching;
  String? _lockedFrameId;
  Uint8List? _lastGoodPolishedBytes;
  String _finish = 'gloss';
  String _panel = 'body';
  String? _paintColor = '#9B1B30';
  final _hex = TextEditingController();
  int _maskSlot = 0;

  String get _displayVehicleTitle {
    if (_customVehicleTitle != null && _customVehicleTitle!.trim().isNotEmpty) {
      return _customVehicleTitle!.trim();
    }
    if (widget.initialVehicleLabel != null && widget.initialVehicleLabel!.trim().isNotEmpty) {
      return widget.initialVehicleLabel!.trim();
    }
    if (widget.isUniversalMode) {
      return 'Universal AR Studio · Any Car';
    }
    return '${widget.car.year} ${widget.car.make} ${widget.car.model}';
  }

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

  static const String segmentLiveCarMutation = r'''
    mutation SegmentLiveCar($input: IdentifyVehicleInput!) {
      segmentLiveCar(input: $input) {
        masked
        maskBase64
        polishedBase64
        paintPixels
        source
        reason
        frameId
      }
    }
  ''';

  void _post(UnityCommand? command) {
    if (command == null || _unityController == null) return;
    _unityController!.postMessage(command.gameObject, command.method, command.argument);
  }

  Timer? _autoMaskTimer;

  void _ensureAutoMaskTimer() {
    _autoMaskTimer ??= Timer.periodic(const Duration(milliseconds: 2600), (_) {
      if (!mounted) return;
      if (_sentisLiveActive && _lockState == ArLockState.searching && !_maskingBusy && !_sharingPhoto) {
        _captureAndLockPreview(silent: true);
      }
    });
  }

  void _startLiveFilter() {
    if (_unityController == null) return;
    setState(() {
      _sentisLiveActive = true;
      _lockState = ArLockState.searching;
      _unityStatus = 'Hold steady to lock preview';
    });
    _applyCurrentPaint();
    _post(UnityCommands.runSentis(stop: false));
    _ensureAutoMaskTimer();
    _captureAndLockPreview(silent: true);
  }

  Future<void> _pauseLiveFilter() async {
    _autoMaskTimer?.cancel();
    _autoMaskTimer = null;
    if (!mounted) return;
    _releaseLock();
    setState(() {
      _sentisLiveActive = false;
      _hasActiveMask = false;
      _maskingBusy = false;
      _capturingForMask = false;
      _lockState = ArLockState.searching;
      _unityStatus = 'Live filter paused · Showing untouched camera feed.';
    });
    _post(UnityCommands.runSentis(stop: true));
  }

  Future<void> _captureAndLockPreview({bool silent = false, bool isUpdate = false}) async {
    if (_unityController == null || _maskingBusy || _sharingPhoto) return;
    setState(() {
      _maskingBusy = true;
      _capturingForMask = true;
      _capturingForStudioShare = false;
      _lockState = isUpdate ? ArLockState.updating : ArLockState.capturing;
      _unityStatus = isUpdate ? 'Updating preview angle…' : 'Locking showroom preview…';
    });

    _post(UnityCommands.captureSnapshot(clean: true));
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted || !_capturingForMask) return;
      setState(() {
        _capturingForMask = false;
        _maskingBusy = false;
        if (_lastGoodPolishedBytes != null) {
          _lockState = ArLockState.locked;
          _unityStatus = 'Preview locked · Tap Update view when ready';
        } else {
          _lockState = ArLockState.searching;
          _unityStatus = 'Hold steady to lock preview';
        }
      });
    });
  }

  Future<void> _repolishLockedFrame() async {
    final frameId = _lockedFrameId;
    if (frameId == null || _maskingBusy) return;
    try {
      final client = GraphQLProvider.of(context).value;
      final result = await client.mutate(
        MutationOptions(
          document: gql(segmentLiveCarMutation),
          fetchPolicy: FetchPolicy.noCache,
          variables: {
            'input': {
              'imageBase64': '',
              'hexColor': _paintColor ?? '#9B1B30',
              'finish': _finish,
              'panel': _panel,
              'repolishOnly': true,
              'frameId': frameId,
              'hdMode': true,
            },
          },
        ),
      );
      final data = result.data?['segmentLiveCar'] as Map<String, dynamic>?;
      final polB64 = data?['polishedBase64'] as String?;
      if (polB64 != null && polB64.isNotEmpty && mounted) {
        final bytes = base64Decode(polB64);
        _lastGoodPolishedBytes = bytes;
        final tempFile = File('${Directory.systemTemp.path}/arcar-locked-frame.jpg');
        await tempFile.writeAsBytes(bytes, flush: true);
        if (mounted) {
          _post(UnityCommands.loadLockedFrame(tempFile.path));
        }
      }
    } catch (_) {}
  }

  void _releaseLock() {
    _post(UnityCommands.releaseLockedFrame());
    setState(() {
      _lockState = ArLockState.released;
      _lockedFrameId = null;
      _lastGoodPolishedBytes = null;
      _hasActiveMask = false;
      _unityStatus = 'Hold steady to lock preview';
    });
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (mounted && _lockState == ArLockState.released) {
        setState(() => _lockState = ArLockState.searching);
      }
    });
  }

  void _showHdShowroomSheet(Uint8List polishedBytes) {
    final paintName = _selected['PAINT']?.name ?? 'Custom Paint';
    final hexLabel = _paintColor ?? '#9B1B30';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141820),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hd, color: Color(0xFF00E5FF), size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Showroom HD Cut · $paintName ($hexLabel)',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.52,
                    ),
                    child: Image.memory(
                      polishedBytes,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.videocam, size: 18),
                        label: const Text('Back to Live AR'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final tempFile = File(
                            '${Directory.systemTemp.path}/autocraft-hd-${DateTime.now().millisecondsSinceEpoch}.jpg',
                          );
                          await tempFile.writeAsBytes(polishedBytes, flush: true);
                          if (ctx.mounted) Navigator.pop(ctx);
                          await Share.shareXFiles(
                            [XFile(tempFile.path)],
                            text:
                                'Auto-Body Shop HD Paint Reference · $_displayVehicleTitle · $paintName ($hexLabel) · Finish: ${_finish.toUpperCase()}',
                          );
                        },
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: const Text('Save / Share HD'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _processLiveMaskSnapshot(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _maskingBusy = false;
          _capturingForMask = false;
          if (_lastGoodPolishedBytes != null) {
            _lockState = ArLockState.locked;
            _unityStatus = 'Preview locked · Tap Update view when ready';
          } else {
            _lockState = ArLockState.searching;
            _unityStatus = 'Hold steady to lock preview';
          }
        });
        return;
      }

      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}

      if (!mounted || !_sentisLiveActive) {
        if (mounted) setState(() => _maskingBusy = false);
        return;
      }
      final client = GraphQLProvider.of(context).value;
      final result = await client.mutate(
        MutationOptions(
          document: gql(segmentLiveCarMutation),
          fetchPolicy: FetchPolicy.noCache,
          variables: {
            'input': {
              'imageBase64': base64Encode(bytes),
              'mimeType': 'image/png',
              'hexColor': _paintColor ?? '#9B1B30',
              'finish': _finish,
              'panel': _panel,
              'repolishOnly': false,
              'hdMode': true,
            },
          },
        ),
      );

      if (!mounted || !_sentisLiveActive) {
        if (mounted) setState(() => _maskingBusy = false);
        return;
      }
      final data = result.data?['segmentLiveCar'] as Map<String, dynamic>?;
      if (result.hasException || data == null || data['masked'] != true || data['polishedBase64'] == null) {
        final gqlErr = result.exception?.graphqlErrors.isNotEmpty == true
            ? result.exception!.graphqlErrors.first.message
            : result.exception?.linkException?.toString();
        final reason = data?['reason']?.toString() ??
            (gqlErr != null ? 'Server busy · Retrying…' : 'Hold steady to lock preview');
        setState(() {
          _maskingBusy = false;
          _capturingForMask = false;
          if (_lastGoodPolishedBytes != null) {
            _lockState = ArLockState.locked;
            _unityStatus = 'Preview locked · Kept previous angle';
          } else {
            _lockState = ArLockState.searching;
            _unityStatus = reason;
          }
        });
        return;
      }

      final polishedB64 = data['polishedBase64'] as String;
      final polishedBytes = base64Decode(polishedB64);
      _lastGoodPolishedBytes = polishedBytes;
      _lockedFrameId = data['frameId'] as String?;

      final lockedFrameFile = File('${Directory.systemTemp.path}/arcar-locked-frame.jpg');
      await lockedFrameFile.writeAsBytes(polishedBytes, flush: true);

      if (data['maskBase64'] != null) {
        final maskBytes = base64Decode(data['maskBase64'] as String);
        _maskSlot = (_maskSlot + 1) % 2;
        final maskFile = File('${Directory.systemTemp.path}/arcar-live-mask-$_maskSlot.png');
        await maskFile.writeAsBytes(maskBytes, flush: true);
        _post(UnityCommands.loadMask(maskFile.path));
      }

      if (!mounted || !_sentisLiveActive) return;

      _post(UnityCommands.loadLockedFrame(lockedFrameFile.path));
      _applyCurrentPaint();

      setState(() {
        _maskingBusy = false;
        _capturingForMask = false;
        _hasActiveMask = true;
        _lockState = ArLockState.locked;
        _unityStatus = 'Preview locked';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _maskingBusy = false;
        _capturingForMask = false;
        if (_lastGoodPolishedBytes != null) {
          _lockState = ArLockState.locked;
          _unityStatus = 'Preview locked · Kept previous angle';
        } else {
          _lockState = ArLockState.searching;
          _unityStatus = 'Hold steady to lock preview';
        }
      });
    }
  }

  /// Studio photo polisher: used ONLY when exporting/sharing the Auto-Body Shop Reference still.
  /// Never covers the live camera viewport.
  Future<void> _exportBodyShopReference() async {
    if (_unityController == null || _sharingPhoto || _maskingBusy) return;
    setState(() {
      _sharingPhoto = true;
      _capturingForStudioShare = true;
      _capturingForMask = false;
      _unityStatus = 'Polishing studio reference photo for share…';
    });

    _post(UnityCommands.captureSnapshot(clean: true));
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted || !_capturingForStudioShare) return;
      setState(() {
        _capturingForStudioShare = false;
        _sharingPhoto = false;
      });
      _snack('Snapshot timed out.');
    });
  }

  Future<void> _processStudioShareSnapshot(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() => _sharingPhoto = false);
      _snack('The camera frame was not written.');
      return;
    }

    try {
      final rawBytes = await file.readAsBytes();
      if (!mounted) return;
      final paintName = _selected['PAINT']?.name ?? 'Custom Paint';
      final client = GraphQLProvider.of(context).value;
      final result = await client.mutate(
        MutationOptions(
          document: gql(segmentLiveCarMutation),
          fetchPolicy: FetchPolicy.noCache,
          variables: {
            'input': {
              'imageBase64': base64Encode(rawBytes),
              'mimeType': 'image/png',
              'hexColor': _paintColor ?? '#9B1B30',
              'finish': _finish,
              'panel': _panel,
              'repolishOnly': false,
            },
          },
        ),
      );

      String shareFilePath = path;
      final data = result.data?['segmentLiveCar'] as Map<String, dynamic>?;
      final polishedB64 = data?['polishedBase64'] as String?;
      if (polishedB64 != null && polishedB64.isNotEmpty) {
        final polishedFile = File(
          '${Directory.systemTemp.path}/autocraft-reference-${DateTime.now().millisecondsSinceEpoch}.png',
        );
        await polishedFile.writeAsBytes(base64Decode(polishedB64), flush: true);
        shareFilePath = polishedFile.path;
        try {
          await file.delete();
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _sharingPhoto = false;
        _unityStatus = 'Live filter active · Studio reference ready to share';
      });

      await Share.shareXFiles(
        [XFile(shareFilePath)],
        text:
            'Auto-Body Shop Paint Reference · $_displayVehicleTitle · $paintName (${_paintColor ?? "#9B1B30"}) · Finish: ${_finish.toUpperCase()} · Panel: ${_panel.toUpperCase()}',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _sharingPhoto = false);
      _snack('Could not share reference photo: $error');
    }
  }

  @override
  void dispose() {
    _autoMaskTimer?.cancel();
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
      // Instant 0ms tint update on the live moving camera—never pauses to take a photo
      _sendPaint(color: color, finish: finish, panel: _panel);
      if (!_sentisLiveActive) {
        _startLiveFilter();
      } else if (!_hasActiveMask && !_maskingBusy) {
        _captureAndLockPreview(silent: true);
      }
      return;
    }

    setState(() => _selected[asset.type] = asset);
    _snack('${asset.name} selected for build quote.');
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
    if (_lockState == ArLockState.locked && _lockedFrameId != null) {
      _repolishLockedFrame();
    }
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
    if (!_sentisLiveActive) {
      _startLiveFilter();
    } else if (!_hasActiveMask && !_maskingBusy) {
      _captureAndLockPreview(silent: true);
    }
  }

  Future<String?> _promptGarageVehicleName() async {
    final paintLabel = _selected['PAINT']?.name ?? '${_finish.toUpperCase()} ${_paintColor ?? "#9B1B30"}';
    final initialText = (_customVehicleTitle != null && _customVehicleTitle!.trim().isNotEmpty)
        ? _customVehicleTitle!.trim()
        : (widget.isUniversalMode
            ? 'My Custom Vehicle ($paintLabel)'
            : '${widget.car.year} ${widget.car.make} ${widget.car.model} ($paintLabel)');
    final controller = TextEditingController(text: initialText);

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text('Save Vehicle to Your Garage'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Name any car you just masked & customized (Make, Model, Plate, or Build Name):',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Vehicle / Build Name',
                  hintText: 'e.g. 2018 Toyota Corolla · Candy Red',
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in [
                    'Toyota Corolla ($paintLabel)',
                    'Toyota Camry ($paintLabel)',
                    'Toyota Matrix Hatchback ($paintLabel)',
                    'Custom SUV / Sedan ($paintLabel)',
                  ])
                    ActionChip(
                      label: Text(preset, style: const TextStyle(fontSize: 11)),
                      onPressed: () => controller.text = preset,
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final text = controller.text.trim();
                Navigator.pop(ctx, text.isEmpty ? initialText : text);
              },
              child: const Text('Save to Garage'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveConfig() async {
    if (!AuthSession.isLoggedIn) {
      _snack('Log in again before saving.');
      return;
    }

    // If user only adjusted live AR paint/hex without tapping a catalog card, auto-bind a paint asset
    if (_selected.isEmpty && _catalogAssets.isNotEmpty) {
      final fallbackPaint = _catalogAssets.firstWhere(
        (a) => a.type == 'PAINT',
        orElse: () => _catalogAssets.first,
      );
      _selected[fallbackPaint.type] = fallbackPaint;
    }

    if (_selected.isEmpty) {
      _snack('Pick a paint or part first.');
      return;
    }

    final chosenName = await _promptGarageVehicleName();
    if (chosenName == null || !mounted) return;

    setState(() {
      _saving = true;
      _customVehicleTitle = chosenName;
    });
    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(
        document: gql(saveConfigMutation),
        variables: {
          'input': {
            'carId': widget.car.id,
            'assetIds': _selected.values.map((asset) => asset.id).toList(),
            'status': 'DRAFT',
            'name': chosenName,
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
    _snack('Saved "$chosenName" to your garage!');
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
    _snack('Share code copied.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _statusLabel(String text) {
    if (text.startsWith('SENTIS_LIVE_STARTED') || text.startsWith('MASK_APPLIED:sentis')) {
      return 'Live car filter active · Move around car & tap any color.';
    }
    if (text.startsWith('MASK_APPLIED')) {
      return 'Live car filter active · Tap any color or finish below.';
    }
    if (text.startsWith('LIVE_TINT:')) {
      return 'Live paint applied ($_finish · $_panel · ${_paintColor ?? ""}).';
    }
    return text;
  }

  void _onUnityMessage(dynamic message) {
    final text = message.toString();
    if (text.startsWith('SNAPSHOT:')) {
      final snapPath = text.substring('SNAPSHOT:'.length);
      if (_capturingForStudioShare) {
        _capturingForStudioShare = false;
        _processStudioShareSnapshot(snapPath);
        return;
      }
      if (_capturingForMask) {
        _capturingForMask = false;
        _processLiveMaskSnapshot(snapPath);
        return;
      }
      setState(() => _sharingPhoto = false);
      return;
    }
    if (text.startsWith('SNAPSHOT_FAILED')) {
      setState(() {
        _sharingPhoto = false;
        _capturingForStudioShare = false;
        _capturingForMask = false;
        _maskingBusy = false;
      });
      return;
    }
    if (text.startsWith('SENTIS_STOPPED')) {
      setState(() {
        _sentisLiveActive = false;
        _hasActiveMask = false;
        _unityStatus = 'Live filter paused · Showing untouched camera feed.';
      });
      return;
    }
    if (text.startsWith('MASK_APPLIED')) {
      if (!_sentisLiveActive) return;
      setState(() {
        _hasActiveMask = true;
        _unityStatus = _statusLabel(text);
      });
      return;
    }
    if (text.startsWith('SENTIS_LIVE_STARTED')) {
      if (!_sentisLiveActive) return;
      setState(() {
        _unityStatus = _hasActiveMask
            ? _statusLabel(text)
            : 'Live filter active · Locking onto car sheet metal…';
      });
      return;
    }
    if (text.startsWith('SENTIS_NEEDS_MASK') ||
        text.startsWith('CAMERA_SETTLED') ||
        text.startsWith('SENTIS_UNAVAILABLE') ||
        text.startsWith('SENTIS_NO_MODEL')) {
      if (_sentisLiveActive && !_maskingBusy && !_sharingPhoto && _lockState == ArLockState.searching) {
        _captureAndLockPreview(silent: true);
      }
      return;
    }
    if (text.startsWith('LIVE_TINT:')) {
      setState(() => _unityStatus = _statusLabel(text));
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

  void _showVoiceCommandDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.mic, color: Color(0xFF00E5FF)),
                  SizedBox(width: 10),
                  Text(
                    'Hands-Free Voice Commands',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Tap a voice phrase to change the live camera paint tint immediately:',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('"Paint Candy Red"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _paintColor = '#D0122D';
                        _finish = 'candy';
                      });
                      _applyCurrentPaint();
                    },
                  ),
                  ActionChip(
                    label: const Text('"Paint Super White"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _paintColor = '#F2F3F5';
                        _finish = 'gloss';
                      });
                      _applyCurrentPaint();
                    },
                  ),
                  ActionChip(
                    label: const Text('"Paint Matte Black"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _paintColor = '#1C1C1C';
                        _finish = 'matte';
                      });
                      _applyCurrentPaint();
                    },
                  ),
                  ActionChip(
                    label: const Text('"Metallic Silver"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _paintColor = '#B7B7BE';
                        _finish = 'metallic';
                      });
                      _applyCurrentPaint();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_displayVehicleTitle, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: _sentisLiveActive ? 'Pause AR Studio' : 'Start AR Studio',
            icon: Icon(
              _sentisLiveActive ? Icons.videocam : Icons.videocam_off,
              color: _sentisLiveActive ? const Color(0xFF00E5FF) : Colors.white54,
            ),
            onPressed: () {
              if (_sentisLiveActive) {
                _pauseLiveFilter();
              } else {
                _startLiveFilter();
              }
            },
          ),
          IconButton(
            tooltip: 'Hands-Free Voice Controls',
            icon: const Icon(Icons.mic, color: Color(0xFF00E5FF)),
            onPressed: _showVoiceCommandDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Always-live 60 FPS AR camera feed (never covered by a static photo)
                ColoredBox(
                  color: Colors.black,
                  child: UnityWidget(
                    onUnityCreated: (controller) {
                      _unityController = controller;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _applyCurrentPaint();
                        Future<void>.delayed(const Duration(milliseconds: 600), () {
                          if (mounted) {
                            _startLiveFilter();
                          }
                        });
                      });
                    },
                    onUnityMessage: _onUnityMessage,
                  ),
                ),
                // Top HUD status pill
                if (_unityStatus != null)
                  Positioned(
                    top: 10,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _sentisLiveActive || _hasActiveMask
                              ? const Color(0xFF00E5FF)
                              : Colors.white24,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (_maskingBusy || _sharingPhoto)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF00E5FF),
                              ),
                            )
                          else
                            Icon(
                              _sentisLiveActive || _hasActiveMask
                                  ? Icons.videocam
                                  : Icons.center_focus_strong,
                              size: 16,
                              color: _sentisLiveActive || _hasActiveMask
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white70,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _unityStatus!,
                              style: const TextStyle(fontSize: 12, color: Colors.white),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Bottom live AR showroom controls
                Positioned(
                  bottom: 10,
                  left: 12,
                  right: 12,
                  child: Row(
                    children: [
                      if (_lockState == ArLockState.locked) ...[
                        Expanded(
                          flex: 3,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: _maskingBusy
                                ? null
                                : () => _captureAndLockPreview(isUpdate: true),
                            icon: const Icon(Icons.sync, size: 18),
                            label: const Text(
                              'Update view',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.black.withValues(alpha: 0.65),
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white38),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: _releaseLock,
                            icon: const Icon(Icons.lock_open, size: 18),
                            label: const Text('Release'),
                          ),
                        ),
                        if (_lastGoodPolishedBytes != null) ...[
                          const SizedBox(width: 8),
                          IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF1F2430),
                              foregroundColor: const Color(0xFF00E5FF),
                            ),
                            tooltip: 'Save / Share HD Reference',
                            icon: const Icon(Icons.ios_share, size: 20),
                            onPressed: () => _showHdShowroomSheet(_lastGoodPolishedBytes!),
                          ),
                        ],
                      ] else ...[
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: _maskingBusy
                                ? null
                                : () => _captureAndLockPreview(),
                            icon: Icon(
                              _maskingBusy ? Icons.hourglass_top : Icons.lock_outline,
                              size: 18,
                            ),
                            label: Text(
                              _maskingBusy ? 'Locking showroom preview…' : 'Lock view',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
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
                      _catalogAssets = assets;
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                        children: [
                          const Text(
                            'Camera stays live as you move around your car. Tap any Paint Color or Finish for an instant tint change, then tap "Share Auto-Body Shop Reference" when ready.',
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                          const SizedBox(height: 6),
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
                          _section('Paint Colors (Live Camera Filter)', assets.where((asset) => asset.type == 'PAINT'), paint: true),
                          _section('Rims', assets.where((asset) => asset.type == 'RIM')),
                          _section('Spoilers', assets.where((asset) => asset.type == 'SPOILER')),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _unityController == null || _sharingPhoto || _maskingBusy
                                ? null
                                : _exportBodyShopReference,
                            icon: const Icon(Icons.share_outlined, size: 18),
                            label: Text(
                              _sharingPhoto
                                  ? 'Polishing Studio Reference Photo…'
                                  : 'Share Auto-Body Shop Reference Photo',
                            ),
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
              border: selected ? Border.all(color: const Color(0xFF00E5FF), width: 3) : Border.all(color: Colors.white24),
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: selected,
      title: Text(asset.name),
      subtitle: Text('₦${asset.price.toStringAsFixed(0)}'),
      trailing: selected ? const Icon(Icons.check, color: Color(0xFF00E5FF)) : null,
      onTap: () => _select(asset),
    );
  }
}
