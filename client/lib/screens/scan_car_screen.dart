import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../models/asset.dart';
import '../models/car.dart';
import '../services/auth_session.dart';
import 'customization_screen.dart';

class ScanCarScreen extends StatefulWidget {
  const ScanCarScreen({super.key});

  @override
  State<ScanCarScreen> createState() => _ScanCarScreenState();
}

class _ScanCarScreenState extends State<ScanCarScreen> {
  final _picker = ImagePicker();
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _result;
  Uint8List? _preview;

  static const String identifyMutation = r'''
    mutation Identify($input: IdentifyVehicleInput!) {
      identifyVehicle(input: $input) {
        identified
        source
        make
        model
        year
        confidence
        yearExact
        reason
        car {
          id
          make
          model
          year
          baseMeshUrl
        }
        assets {
          id
          name
          type
          price
          materialBundleUrl
          anchor
        }
      }
    }
  ''';

  Future<void> _capture(ImageSource source) async {
    if (!AuthSession.isLoggedIn) {
      setState(() => _error = 'Log in again before identifying a car.');
      return;
    }

    XFile? shot;
    try {
      shot = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 60,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Camera permission is required to identify a car. $error');
      return;
    }
    if (shot == null || !mounted) return;

    final bytes = await shot.readAsBytes();
    if (!mounted) return;
    if (bytes.length > 4000000) {
      setState(() => _error = 'That photo is too large. Try again closer to the car.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _preview = bytes;
    });

    final mime = shot.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final client = GraphQLProvider.of(context).value;
    final result = await client.mutate(
      MutationOptions(
        document: gql(identifyMutation),
        variables: {
          'input': {
            'imageBase64': base64Encode(bytes),
            'mimeType': mime,
          },
        },
      ),
    );

    if (!mounted) return;
    if (result.hasException || result.data?['identifyVehicle'] == null) {
      setState(() {
        _busy = false;
        _error = result.exception?.graphqlErrors.isNotEmpty == true
            ? result.exception!.graphqlErrors.first.message
            : 'Could not reach the identification service.';
      });
      return;
    }

    setState(() {
      _busy = false;
      _result = Map<String, dynamic>.from(result.data!['identifyVehicle'] as Map);
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final carJson = result?['car'];
    final car = carJson is Map ? Car.fromJson(Map<String, dynamic>.from(carJson)) : null;
    final assets = ((result?['assets'] ?? []) as List)
        .whereType<Map>()
        .map((json) => Asset.fromJson(Map<String, dynamic>.from(json)))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Scan a real car')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'A vision model reads one frame and the catalog returns only parts fitted to that car. It does not guess when the model is not configured.',
          ),
          const SizedBox(height: 16),
          if (_preview != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_preview!, height: 180, fit: BoxFit.cover),
            ),
          if (_busy) const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (result != null) ...[
            const SizedBox(height: 20),
            Text(
              result['identified'] == true
                  ? '${result['year'] ?? ''} ${result['make'] ?? ''} ${result['model'] ?? ''}'.trim()
                  : 'Not identified',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            if (result['confidence'] != null)
              Text('Model confidence ${((result['confidence'] as num) * 100).round()}%'),
            if (result['reason'] != null) ...[
              const SizedBox(height: 8),
              Text(result['reason'].toString()),
            ],
            if (assets.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Parts that fit', style: TextStyle(fontWeight: FontWeight.w600)),
              ...assets.map((asset) => Text('${asset.type}: ${asset.name}')),
            ],
            if (car != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => CustomizationScreen(car: car)),
                  );
                },
                child: Text('Customize ${car.year} ${car.make} ${car.model}'),
              ),
            ],
          ],
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _busy ? null : () => _capture(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
            label: const Text('Take photo'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _capture(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose photo'),
          ),
        ],
      ),
    );
  }
}
