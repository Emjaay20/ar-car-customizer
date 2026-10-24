import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../models/asset.dart';
import '../models/car.dart';
import '../services/auth_session.dart';
import '../services/graphql_service.dart';
import '../services/paint_spec.dart';
import '../services/unity_commands.dart';
import '../widgets/hd_showroom_viewer.dart';

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

class AuthoritativePaintState {
  final String colorHex;
  final String finish;
  final String panel;
  final String assetName;
  final int version;

  const AuthoritativePaintState({
    required this.colorHex,
    required this.finish,
    required this.panel,
    required this.assetName,
    required this.version,
  });

  AuthoritativePaintState copyWith({
    String? colorHex,
    String? finish,
    String? panel,
    String? assetName,
  }) {
    return AuthoritativePaintState(
      colorHex: colorHex ?? this.colorHex,
      finish: finish ?? this.finish,
      panel: panel ?? this.panel,
      assetName: assetName ?? this.assetName,
      version: version + 1,
    );
  }
}

class _CustomizationScreenState extends State<CustomizationScreen> {
  final Map<String, Asset> _selected = {};
  List<Asset> _catalogAssets = const [];
  UnityWidgetController? _unityController;
  String? _unityStatus = '🟢 Live AR Customizer · 60 FPS';
  String? _savedConfigId;
  String? _customVehicleTitle;
  bool _saving = false;
  bool _sharingPhoto = false;
  bool _capturingForMask = false;
  bool _capturingForStudioShare = false;
  bool _maskingBusy = false;
  bool _hasActiveMask = false;
  bool _sentisLiveActive = false;
  Uint8List? _lastGoodPolishedBytes;
  Uint8List? _lastRawSnapshotBytes;
  String _finish = 'gloss';
  String _panel = 'body';
  String _coverageMode = 'true-to-life';
  String? _paintColor = '#9B1B30';
  final _hex = TextEditingController();
  int _maskSlot = 0;
  int _requestSequence = 0;
  int _latestProcessedSequence = 0;
  int _studioShareRetryCount = 0;
  late AuthoritativePaintState _paintState;

  @override
  void initState() {
    super.initState();
    final defaultAsset = _defaultCatalog.firstWhere(
      (a) => a.type == 'PAINT',
      orElse: () => _defaultCatalog.first,
    );
    final defaultFinish = PaintSpec.finishFrom(defaultAsset.materialBundleUrl, defaultAsset.name);
    final defaultColor = PaintSpec.colorToken(defaultAsset.materialBundleUrl, defaultAsset.name);
    _selected['PAINT'] = defaultAsset;
    _finish = defaultFinish;
    _paintColor = defaultColor;
    _panel = 'body';
    _paintState = AuthoritativePaintState(
      colorHex: defaultColor,
      finish: defaultFinish,
      panel: 'body',
      assetName: defaultAsset.name,
      version: 1,
    );
  }

  void _updatePaintState({String? color, String? finish, String? panel, String? assetName, Asset? asset}) {
    final nextColor = color ?? _paintState.colorHex;
    final nextFinish = finish ?? _paintState.finish;
    final nextPanel = panel ?? _paintState.panel;
    final nextName = assetName ?? (asset != null ? asset.name : _paintState.assetName);

    setState(() {
      _paintColor = nextColor;
      _finish = nextFinish;
      _panel = nextPanel;
      if (asset != null) {
        _selected['PAINT'] = asset;
      }
      _paintState = _paintState.copyWith(
        colorHex: nextColor,
        finish: nextFinish,
        panel: nextPanel,
        assetName: nextName,
      );
    });

    _sendPaint(color: nextColor, finish: nextFinish, panel: nextPanel);
    if (!_sentisLiveActive) {
      _startLiveFilter();
    }
  }

  bool _isWalkaroundScanning = false;
  bool _isCapturingWalkaroundAngle = false;
  int _walkaroundStep = 0;
  String _walkaroundStepPrompt = '';
  final List<String> _walkaroundSnapPaths = [];
  final List<String> _walkaroundAngleLabels = [
    'Front 3/4 View',
    'Driver Side Profile',
    'Rear 3/4 View',
  ];

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

  static final List<Asset> _defaultCatalog = [
    Asset(id: 'paint-candy-red', name: 'Candy Red', type: 'PAINT', price: 120000, materialBundleUrl: 'paints/candy_red#9B1B30'),
    Asset(id: 'paint-carmine-red', name: 'Carmine Red', type: 'PAINT', price: 110000, materialBundleUrl: 'paints/carmine_red#8B0000'),
    Asset(id: 'paint-gloss-black', name: 'Gloss Black', type: 'PAINT', price: 95000, materialBundleUrl: 'paints/gloss_black#111111'),
    Asset(id: 'paint-matte-black', name: 'Matte Black', type: 'PAINT', price: 105000, materialBundleUrl: 'paints/matte_black#222222'),
    Asset(id: 'paint-metallic-silver', name: 'Metallic Silver', type: 'PAINT', price: 98000, materialBundleUrl: 'paints/metallic_silver#C0C0C0'),
    Asset(id: 'paint-modern-steel', name: 'Modern Steel', type: 'PAINT', price: 98000, materialBundleUrl: 'paints/modern_steel#4B4F54'),
    Asset(id: 'paint-satin-graphite', name: 'Satin Graphite', type: 'PAINT', price: 105000, materialBundleUrl: 'paints/satin_graphite#383E45'),
    Asset(id: 'paint-alpine-white', name: 'Alpine White', type: 'PAINT', price: 90000, materialBundleUrl: 'paints/alpine_white#F5F5F5'),
    Asset(id: 'paint-nardo-grey', name: 'Nardo Grey', type: 'PAINT', price: 115000, materialBundleUrl: 'paints/nardo_grey#6C7176'),
    Asset(id: 'paint-miami-blue', name: 'Miami Blue', type: 'PAINT', price: 130000, materialBundleUrl: 'paints/miami_blue#00A3E0'),
    Asset(id: 'rim-accord-sport', name: '18-inch Accord Sport', type: 'RIMS', price: 240000, materialBundleUrl: 'rims/accord_sport', anchor: 'wheel'),
    Asset(id: 'rim-forged-matte', name: '19-inch Forged Matte', type: 'RIMS', price: 320000, materialBundleUrl: 'rims/forged_matte', anchor: 'wheel'),
    Asset(id: 'spoiler-carbon-lip', name: 'Carbon Lip Spoiler', type: 'SPOILER', price: 85000, materialBundleUrl: 'spoilers/carbon_lip', anchor: 'trunk'),
  ];

  void _post(UnityCommand? command) {
    if (command == null || _unityController == null) return;
    _unityController!.postMessage(command.gameObject, command.method, command.argument);
  }

  void _startLiveFilter() {
    if (_unityController == null) return;
    setState(() {
      _sentisLiveActive = true;
      _unityStatus = '🟢 On-Device Live AR · 60 FPS';
    });
    _applyCurrentPaint();
    _post(UnityCommands.runSentis(stop: false));
  }

  Future<void> _pauseLiveFilter() async {
    if (!mounted) return;
    setState(() {
      _sentisLiveActive = false;
      _hasActiveMask = false;
      _maskingBusy = false;
      _capturingForMask = false;
      _unityStatus = 'Live filter paused · Untouched camera feed';
    });
    _post(UnityCommands.runSentis(stop: true));
  }

  Future<void> _refreshLiveMask({bool silent = false}) async {
    if (_unityController == null || _maskingBusy || _sharingPhoto) return;
    setState(() {
      _maskingBusy = true;
      _capturingForMask = true;
      _capturingForStudioShare = false;
      if (!silent && !_hasActiveMask) {
        _unityStatus = 'Detecting vehicle sheet metal…';
      }
    });

    _post(UnityCommands.captureSnapshot(clean: true));
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted || !_capturingForMask) return;
      setState(() {
        _capturingForMask = false;
        _maskingBusy = false;
        _unityStatus = _hasActiveMask
            ? '🟢 Live AR Customizer · 60 FPS'
            : 'Point camera at vehicle sheet metal';
      });
    });
  }

  Future<void> _captureHdStudioCut() async {
    if (_unityController == null || _sharingPhoto || _maskingBusy) return;
    _studioShareRetryCount = 0;
    setState(() {
      _sharingPhoto = true;
      _capturingForStudioShare = true;
      _capturingForMask = false;
      _unityStatus = 'Capturing Showroom HD Studio photo…';
    });

    _post(UnityCommands.captureSnapshot(clean: true));
    Future<void>.delayed(const Duration(seconds: 18), () {
      if (!mounted || !_capturingForStudioShare) return;
      setState(() {
        _capturingForStudioShare = false;
        _sharingPhoto = false;
        _unityStatus = '🟢 Live AR Customizer · 60 FPS';
      });
      _snack('Studio snapshot timed out.');
    });
  }


  String get _currentPaintDisplayTitle {
    final assetName = _selected['PAINT']?.name;
    final curFinCap = _finish.isNotEmpty ? '${_finish[0].toUpperCase()}${_finish.substring(1).toLowerCase()}' : 'Custom';
    if (assetName == null) return '$curFinCap Paint';
    final finishes = ['Gloss', 'Matte', 'Satin', 'Metallic', 'Candy', 'Carbon'];
    for (final f in finishes) {
      if (assetName.contains(f)) {
        return assetName.replaceAll(f, curFinCap);
      }
    }
    return '$curFinCap $assetName';
  }

  void _showHdShowroomSheet(Uint8List polishedBytes) {
    HdShowroomViewer.show(
      context,
      polishedBytes: polishedBytes,
      originalBytes: _lastRawSnapshotBytes,
      paintName: _currentPaintDisplayTitle,
      hexColor: _paintState.colorHex,
      finish: _paintState.finish,
      vehicleTitle: _displayVehicleTitle,
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
          _unityStatus = _hasActiveMask
              ? '🟢 Live AR Customizer · 60 FPS'
              : 'Point camera at vehicle sheet metal';
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
              'hdMode': false,
              'fullCoverage': _coverageMode == 'full',
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
        setState(() {
          _maskingBusy = false;
          _capturingForMask = false;
          _unityStatus = _hasActiveMask
              ? '🟢 Live AR Customizer · 60 FPS'
              : (data?['reason']?.toString() ?? 'Point camera at vehicle sheet metal');
        });
        return;
      }

      final polishedB64 = data['polishedBase64'] as String;
      final polishedBytes = base64Decode(polishedB64);
      _lastGoodPolishedBytes = polishedBytes;

      if (data['maskBase64'] != null) {
        final maskBytes = base64Decode(data['maskBase64'] as String);
        _maskSlot = (_maskSlot + 1) % 2;
        final maskFile = File('${Directory.systemTemp.path}/arcar-live-mask-$_maskSlot.png');
        await maskFile.writeAsBytes(maskBytes, flush: true);
        _post(UnityCommands.loadMask(maskFile.path));
      }

      if (!mounted || !_sentisLiveActive) return;

      _applyCurrentPaint();

      setState(() {
        _maskingBusy = false;
        _capturingForMask = false;
        _hasActiveMask = true;
        _unityStatus = '🟢 Live AR Customizer · 60 FPS';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _maskingBusy = false;
        _capturingForMask = false;
        _unityStatus = _hasActiveMask
            ? '🟢 Live AR Customizer · 60 FPS'
            : 'Point camera at vehicle sheet metal';
      });
    }
  }

  /// Studio photo polisher: delegates directly to Showroom HD Studio Cut
  Future<void> _exportBodyShopReference() async {
    await _captureHdStudioCut();
  }


  Future<ShowroomAngleCut?> _polishSingleAngle(String path, String label, {int retryCount = 0}) async {
    final file = File(path);
    if (!await file.exists()) return null;

    final seq = ++_requestSequence;
    final activePaint = _paintState;

    try {
      final rawBytes = await file.readAsBytes();
      if (!mounted) return null;
      final client = GraphQLProvider.of(context).value;
      final result = await client.mutate(
        MutationOptions(
          document: gql(segmentLiveCarMutation),
          fetchPolicy: FetchPolicy.noCache,
          variables: {
            'input': {
              'imageBase64': base64Encode(rawBytes),
              'mimeType': 'image/jpeg',
              'hexColor': activePaint.colorHex,
              'finish': activePaint.finish,
              'panel': activePaint.panel,
              'repolishOnly': false,
              'hdMode': true,
              'fullCoverage': _coverageMode == 'full',
              'frameId': 'req_$seq',
            },
          },
        ),
      );

      // Monotonic sequence guard: if a newer request was dispatched, discard stale response
      if (seq < _latestProcessedSequence) {
        return null;
      }
      _latestProcessedSequence = seq;

      final data = result.data?['segmentLiveCar'] as Map<String, dynamic>?;
      final polishedB64 = data?['polishedBase64'] as String?;
      final isMasked = data?['masked'] == true;

      if (!result.hasException && isMasked && polishedB64 != null && polishedB64.isNotEmpty) {
        final bytes = base64Decode(polishedB64);
        return ShowroomAngleCut(label: label, polishedBytes: bytes, originalBytes: rawBytes);
      }
    } catch (_) {
      if (retryCount < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        return _polishSingleAngle(path, label, retryCount: retryCount + 1);
      }
    }
    return null;
  }

  Future<void> _processStudioShareSnapshot(String path) async {
    final cut = await _polishSingleAngle(path, 'Front Studio View');
    if (!mounted) return;

    if (cut != null) {
      _studioShareRetryCount = 0;
      setState(() {
        _sharingPhoto = false;
        _capturingForStudioShare = false;
        _unityStatus = '🟢 Live AR Customizer · 60 FPS';
      });
      _lastGoodPolishedBytes = cut.polishedBytes;
      _lastRawSnapshotBytes = cut.originalBytes;
      _showHdShowroomSheet(cut.polishedBytes);
      return;
    }

    // Cold-start fresh frame retry: if 1st frame had paintPixels < 400 or failed isolation,
    // wait 800ms for camera auto-exposure to settle, take ONE fresh camera snapshot, and polish that!
    if (_studioShareRetryCount < 1 && _unityController != null) {
      _studioShareRetryCount++;
      setState(() {
        _sharingPhoto = true;
        _capturingForStudioShare = true;
        _unityStatus = 'Refining camera focus & isolation…';
      });
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      _post(UnityCommands.captureSnapshot(clean: true));
      return;
    }

    // Both consecutive fresh frames failed: show clear guidance toast
    _studioShareRetryCount = 0;
    setState(() {
      _sharingPhoto = false;
      _capturingForStudioShare = false;
      _unityStatus = '🟢 Live AR Customizer · 60 FPS';
    });
    _snack('Could not isolate car sheet metal cleanly. Point camera directly at the car and try again.');
  }

  Future<void> _startWalkaroundScan() async {
    if (_unityController == null || _sharingPhoto || _maskingBusy || _isWalkaroundScanning) return;
    setState(() {
      _isWalkaroundScanning = true;
      _isCapturingWalkaroundAngle = false;
      _walkaroundStep = 0;
      _walkaroundSnapPaths.clear();
      _walkaroundStepPrompt = 'Step 1 of 3: Frame Front 3/4 View and tap Capture';
      _unityStatus = 'Showroom 360° Director Mode · Step 1/3';
    });
  }

  void _cancelWalkaround() {
    setState(() {
      _isWalkaroundScanning = false;
      _isCapturingWalkaroundAngle = false;
      _walkaroundStep = 0;
      _walkaroundSnapPaths.clear();
      _unityStatus = '🟢 Live AR Customizer · 60 FPS';
    });
  }

  Future<void> _triggerWalkaroundCapture() async {
    if (!_isWalkaroundScanning || _isCapturingWalkaroundAngle || _unityController == null) return;
    setState(() {
      _isCapturingWalkaroundAngle = true;
      _unityStatus = 'Capturing ${_walkaroundAngleLabels[_walkaroundStep]}…';
    });
    _post(UnityCommands.captureSnapshot(clean: true));
  }

  void _handleWalkaroundSnapshot(String snapPath) {
    _walkaroundSnapPaths.add(snapPath);
    setState(() {
      _isCapturingWalkaroundAngle = false;
    });

    if (_walkaroundStep < _walkaroundAngleLabels.length - 1) {
      setState(() {
        _walkaroundStep++;
        _walkaroundStepPrompt =
            'Step ${_walkaroundStep + 1} of ${_walkaroundAngleLabels.length}: Frame ${_walkaroundAngleLabels[_walkaroundStep]} and tap Capture';
        _unityStatus = 'Step ${_walkaroundStep + 1}/3 · ${_walkaroundAngleLabels[_walkaroundStep]}';
      });
      return;
    }

    // All angles captured!
    setState(() {
      _isWalkaroundScanning = false;
      _sharingPhoto = true;
      _unityStatus = 'Polishing 360° Showroom Turntable…';
    });

    final paths = List<String>.from(_walkaroundSnapPaths);
    _processWalkaroundSnapshots(paths);
  }

  Future<void> _processWalkaroundSnapshots(List<String> paths) async {
    final cuts = <ShowroomAngleCut>[];
    for (int i = 0; i < paths.length; i++) {
      final label = i < _walkaroundAngleLabels.length ? _walkaroundAngleLabels[i] : 'Angle ${i + 1}';
      final cut = await _polishSingleAngle(paths[i], label);
      if (cut != null) {
        cuts.add(cut);
      } else {
        // Fallback: If polishing on an angle didn't cleanly isolate, keep the raw snapshot so angle isn't dropped
        try {
          final file = File(paths[i]);
          if (await file.exists()) {
            final rawBytes = await file.readAsBytes();
            cuts.add(ShowroomAngleCut(label: label, polishedBytes: rawBytes, originalBytes: rawBytes));
          }
        } catch (_) {}
      }
    }

    if (!mounted) return;
    setState(() {
      _sharingPhoto = false;
      _unityStatus = '🟢 Live AR Customizer · 60 FPS';
    });

    if (cuts.isNotEmpty) {
      final paintName = _currentPaintDisplayTitle;
      HdShowroomViewer.show(
        context,
        angles: cuts,
        paintName: paintName,
        hexColor: _paintState.colorHex,
        finish: _paintState.finish,
        vehicleTitle: _displayVehicleTitle,
      );
    } else {
      _snack('Could not isolate vehicle angles cleanly. Please keep car in frame and try again.');
    }
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
      _updatePaintState(color: color, finish: finish, asset: asset);
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
  }

  void _applyHex() {
    final raw = _hex.text.trim();
    if (!PaintSpec.validHex(raw)) {
      _snack('Enter a 6-digit hex color, like #1C1C1C.');
      return;
    }
    final color = PaintSpec.normalizeHex(raw);
    _selected.remove('PAINT');
    _updatePaintState(color: color, assetName: 'Custom $color');
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
      if (_isWalkaroundScanning) {
        _handleWalkaroundSnapshot(snapPath);
        return;
      }
      if (_capturingForStudioShare || _sharingPhoto) {
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
    if (text.startsWith('SENTIS_FPS:')) {
      final parts = text.split(':');
      final fps = parts.length > 1 ? parts[1] : '60';
      setState(() {
        _hasActiveMask = true;
        _unityStatus = '🟢 On-Device Live AR · $fps FPS';
      });
      return;
    }
    if (text.startsWith('SENTIS_MASK_UPDATED')) {
      if (!_hasActiveMask || (_unityStatus?.contains('Locking') ?? false)) {
        setState(() {
          _hasActiveMask = true;
          _unityStatus = '🟢 On-Device Live AR';
        });
      }
      return;
    }
    if (text.startsWith('SENTIS_NO_MODEL')) {
      setState(() {
        _unityStatus = 'AI Model loading on phone…';
      });
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
                      _updatePaintState(color: '#D0122D', finish: 'candy');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Paint Super White"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#F2F3F5', finish: 'gloss');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Paint Matte Black"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#1C1C1C', finish: 'matte');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Gloss Obsidian Black"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#111111', finish: 'gloss', panel: 'body');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Wrap Carbon Hood"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#111111', finish: 'carbon', panel: 'hood');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Two-Tone Floating Roof"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#111111', finish: 'gloss', panel: 'roof');
                    },
                  ),
                  ActionChip(
                    label: const Text('"Metallic Silver"'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _updatePaintState(color: '#B7B7BE', finish: 'metallic', panel: 'body');
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

  void _showServerSwitchDialog() {
    final isCloud = GraphQLService.apiUrl.contains('aetherhost');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.dns, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('AR AI Backend Server', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Current: ${isCloud ? "Cloud VPS (AetherHost)" : "Local PC (192.168.100.66)"}',
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              icon: const Icon(Icons.wifi, size: 18),
              label: const Text('Connect to Local PC (Fastest AR)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: !isCloud ? const Color(0xFF00E5FF) : Colors.white24,
                foregroundColor: !isCloud ? Colors.black : Colors.white,
              ),
              onPressed: () {
                GraphQLService.setApiUrl('http://192.168.100.66:3000/graphql');
                Navigator.pop(ctx);
                _snack('Switched backend to Local PC (192.168.100.66)');
              },
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.cloud, size: 18),
              label: const Text('Connect to Cloud (AetherHost)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: isCloud ? const Color(0xFF00E5FF) : Colors.white24,
                foregroundColor: isCloud ? Colors.black : Colors.white,
              ),
              onPressed: () {
                GraphQLService.setApiUrl('https://ar-car-backend.aetherhost.com.ng/graphql');
                Navigator.pop(ctx);
                _snack('Switched backend to Cloud (AetherHost)');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_displayVehicleTitle, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Server Connection',
            icon: Icon(
              GraphQLService.apiUrl.contains('aetherhost')
                  ? Icons.cloud_done
                  : Icons.wifi_tethering,
              color: const Color(0xFF00E5FF),
            ),
            onPressed: _showServerSwitchDialog,
          ),
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
                // Frosted glass loading shimmer during HD Studio capture to conceal intermediate capture / white mask
                if (_sharingPhoto)
                  Positioned.fill(
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.70),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E222D).withValues(alpha: 0.95),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                                        blurRadius: 30,
                                        spreadRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: const CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                                    strokeWidth: 3.5,
                                  ),
                                ),
                                const SizedBox(height: 22),
                                const Text(
                                  'POLISHING SHOWROOM HD CUT',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2.0,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _walkaroundSnapPaths.isNotEmpty
                                      ? 'Meta SAM 2 360° Multi-Angle Turntable Polishing…'
                                      : 'Meta SAM 2 Sub-Pixel Segmentation & PBR Glaze…',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 12,
                                  ),
                                ),

                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Top HUD status pill

                if (_unityStatus != null)
                  Positioned(
                    top: 10,
                    left: 12,
                    right: 12,
                    child: GestureDetector(
                      onTap: _showServerSwitchDialog,
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
                  ),
                // Walkaround AR Guidance HUD
                if (_isWalkaroundScanning)
                  Positioned(
                    top: 60,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                            blurRadius: 18,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.rotate_right, color: Color(0xFF00E5FF), size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _walkaroundStepPrompt,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${_walkaroundStep + 1}/${_walkaroundAngleLabels.length}',
                                  style: const TextStyle(
                                    color: Color(0xFF00E5FF),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: List.generate(_walkaroundAngleLabels.length, (idx) {
                              final isDone = idx < _walkaroundStep;
                              final isCurrent = idx == _walkaroundStep;
                              final color = isDone
                                  ? const Color(0xFF00E676)
                                  : (isCurrent ? const Color(0xFF00E5FF) : Colors.white38);
                              final icon = isDone
                                  ? Icons.check_circle
                                  : (isCurrent ? Icons.camera_alt : Icons.radio_button_unchecked);
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: isCurrent ? const Color(0xFF00E5FF) : Colors.transparent,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon, size: 14, color: color),
                                    const SizedBox(width: 4),
                                    Text(
                                      _walkaroundAngleLabels[idx].split(' ').first,
                                      style: TextStyle(
                                        color: color,
                                        fontSize: 11,
                                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (_walkaroundStep + 1) / _walkaroundAngleLabels.length.toDouble(),
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                              minHeight: 4,
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
                  child: _isWalkaroundScanning
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.88),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: _isCapturingWalkaroundAngle ? null : _cancelWalkaround,
                                tooltip: 'Cancel Walkaround',
                                icon: const Icon(Icons.close, color: Colors.white70),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    elevation: 6,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onPressed: _isCapturingWalkaroundAngle ? null : _triggerWalkaroundCapture,
                                  icon: _isCapturingWalkaroundAngle
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.black,
                                          ),
                                        )
                                      : const Icon(Icons.camera_alt, color: Colors.black, size: 20),
                                  label: Text(
                                    _isCapturingWalkaroundAngle
                                        ? 'Capturing Angle ${_walkaroundStep + 1}…'
                                        : '📸 Capture Angle (${_walkaroundStep + 1}/${_walkaroundAngleLabels.length})',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00E5FF),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  elevation: 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: (_sharingPhoto || _maskingBusy || _isWalkaroundScanning)
                                    ? null
                                    : () => _captureHdStudioCut(),
                                icon: Icon(
                                  _sharingPhoto && !_isWalkaroundScanning ? Icons.hourglass_top : Icons.camera_alt,
                                  size: 18,
                                ),
                                label: Text(
                                  _sharingPhoto && !_isWalkaroundScanning
                                      ? 'Polishing HD…'
                                      : 'Instant HD Photo',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF161B22),
                                  foregroundColor: const Color(0xFF00E5FF),
                                  side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  elevation: 4,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                onPressed: (_sharingPhoto || _maskingBusy || _isWalkaroundScanning)
                                    ? null
                                    : () => _startWalkaroundScan(),
                                icon: Icon(
                                  _isWalkaroundScanning ? Icons.hourglass_bottom : Icons.rotate_right,
                                  size: 18,
                                ),
                                label: Text(
                                  _isWalkaroundScanning ? 'Scanning…' : '360° Walkaround',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black.withValues(alpha: 0.65),
                                foregroundColor: const Color(0xFF00E5FF),
                                side: const BorderSide(color: Colors.white38),
                                padding: const EdgeInsets.all(12),
                              ),
                              tooltip: 'Refresh Live Mask',
                              onPressed: (_maskingBusy || _isWalkaroundScanning) ? null : () => _refreshLiveMask(),
                              icon: _maskingBusy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF00E5FF),
                                      ),
                                    )
                            : const Icon(Icons.sync, size: 20),
                      ),
                      if (_lastGoodPolishedBytes != null) ...[
                        const SizedBox(width: 8),
                        IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: const Color(0xFF1F2430),
                            foregroundColor: const Color(0xFF00E5FF),
                            padding: const EdgeInsets.all(12),
                          ),
                          tooltip: 'View Last HD Cut',
                          icon: const Icon(Icons.photo_library, size: 20),
                          onPressed: () => _showHdShowroomSheet(_lastGoodPolishedBytes!),
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
                      List<Asset> assets = [];
                      if (!result.hasException && result.data?['assetsForCar'] != null) {
                        assets = ((result.data!['assetsForCar']) as List)
                            .whereType<Map>()
                            .map((json) => Asset.fromJson(Map<String, dynamic>.from(json)))
                            .toList();
                      }
                      if (assets.isEmpty) {
                        assets = _defaultCatalog;
                      }
                      _catalogAssets = assets;
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                        children: [
                          const Text(
                            'Camera stays live as you move around your car. Tap any Paint Color or Finish for an instant tint change, then tap "Share Auto-Body Shop Reference" when ready.',
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                          const SizedBox(height: 6),
                          _choiceRow('Finish', PaintSpec.finishes, _paintState.finish, (value) {
                            _updatePaintState(finish: value);
                          }),
                          _choiceRow('Panel', PaintSpec.panels, _paintState.panel, (value) {
                            _updatePaintState(panel: value);
                          }),
                          _choiceRow(
                            'Coverage Mode',
                            const ['true-to-life', 'full'],
                            _coverageMode,
                            (value) {
                              setState(() {
                                _coverageMode = value;
                              });
                              _sendPaint(
                                color: _paintState.colorHex,
                                finish: _paintState.finish,
                                panel: _paintState.panel,
                              );
                              if (_hasActiveMask && !_maskingBusy) {
                                _refreshLiveMask();
                              }
                            },
                            labels: const {
                              'true-to-life': 'True-to-Life (Clean Lights & Plates)',
                              'full': 'Full Coverage',
                            },
                          ),
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

  Widget _choiceRow(String title, List<String> values, String selected, ValueChanged<String> onPick, {Map<String, String>? labels}) {
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
              final label = labels != null && labels.containsKey(value)
                  ? labels[value]!
                  : (value[0].toUpperCase() + value.substring(1));
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
