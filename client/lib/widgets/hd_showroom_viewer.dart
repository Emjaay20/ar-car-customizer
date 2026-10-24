import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ShowroomAngleCut {
  final String label;
  final Uint8List polishedBytes;
  final Uint8List? originalBytes;

  const ShowroomAngleCut({
    required this.label,
    required this.polishedBytes,
    this.originalBytes,
  });
}

class HdShowroomViewer extends StatefulWidget {
  final List<ShowroomAngleCut> angles;
  final String paintName;
  final String hexColor;
  final String finish;
  final String vehicleTitle;

  const HdShowroomViewer({
    super.key,
    required this.angles,
    required this.paintName,
    required this.hexColor,
    required this.finish,
    required this.vehicleTitle,
  });

  static Future<void> show(
    BuildContext context, {
    Uint8List? polishedBytes,
    Uint8List? originalBytes,
    List<ShowroomAngleCut>? angles,
    required String paintName,
    required String hexColor,
    required String finish,
    required String vehicleTitle,
  }) {
    final list = angles != null && angles.isNotEmpty
        ? angles
        : [
            ShowroomAngleCut(
              label: 'Front Studio View',
              polishedBytes: polishedBytes!,
              originalBytes: originalBytes,
            ),
          ];

    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (ctx) => HdShowroomViewer(
          angles: list,
          paintName: paintName,
          hexColor: hexColor,
          finish: finish,
          vehicleTitle: vehicleTitle,
        ),
      ),
    );
  }

  @override
  State<HdShowroomViewer> createState() => _HdShowroomViewerState();
}

class _HdShowroomViewerState extends State<HdShowroomViewer> {
  int _selectedAngleIndex = 0;
  double _splitFraction = 0.50; // 0.0 = all original, 1.0 = all polished
  bool _saving = false;

  ShowroomAngleCut get _currentCut => widget.angles[_selectedAngleIndex];

  IconData _angleIcon(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('front')) return Icons.directions_car;
    if (lower.contains('side')) return Icons.swap_horiz;
    if (lower.contains('rear') || lower.contains('back')) return Icons.turn_right;
    return Icons.photo_camera;
  }

  static const _mediaChannel = MethodChannel('ar_car/media');

  Future<void> _saveToGallery() async {
    setState(() => _saving = true);
    try {
      final savedCount = <String>[];
      final ts = DateTime.now().millisecondsSinceEpoch;

      for (int i = 0; i < widget.angles.length; i++) {
        final cut = widget.angles[i];
        final cleanLabel = cut.label.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        final filename = 'AutoCraft_${cleanLabel}_$ts.jpg';

        String? savedUri;
        if (Platform.isAndroid) {
          try {
            savedUri = await _mediaChannel.invokeMethod<String>('saveImageToGallery', {
              'bytes': cut.polishedBytes,
              'filename': filename,
            });
          } catch (e) {
            debugPrint('[HdShowroomViewer] Android MediaStore save error: $e');
          }
        }

        if (savedUri == null || savedUri.isEmpty) {
          final baseDir = await getApplicationDocumentsDirectory();
          final file = File('${baseDir.path}/$filename');
          await file.writeAsBytes(cut.polishedBytes, flush: true);
          savedUri = file.path;
        }

        if (savedUri.isNotEmpty) {
          savedCount.add(savedUri);
        }
      }

      if (!mounted) return;
      if (savedCount.isNotEmpty) {
        final msg = savedCount.length > 1
            ? 'Saved ${savedCount.length} Studio Angles to Photos (AutoCraft album)!'
            : 'Saved to Photos (AutoCraft album)!';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Color(0xFF00E5FF), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    msg,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF142434),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not register image in MediaStore. Tap Share to save via system.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save file: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _shareImage() async {
    final tempFiles = <XFile>[];
    for (int i = 0; i < widget.angles.length; i++) {
      final cut = widget.angles[i];
      final tempFile = File(
        '${Directory.systemTemp.path}/autocraft-${cut.label.replaceAll(' ', '_')}-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(cut.polishedBytes, flush: true);
      tempFiles.add(XFile(tempFile.path));
    }

    await Share.shareXFiles(
      tempFiles,
      text:
          'AutoCraft 360° Studio Showcase · ${widget.vehicleTitle} · ${widget.paintName} (${widget.hexColor}) · Finish: ${widget.finish.toUpperCase()}',
    );
  }

  void _nextAngle() {
    if (widget.angles.length <= 1) return;
    setState(() {
      _selectedAngleIndex = (_selectedAngleIndex + 1) % widget.angles.length;
    });
  }

  void _prevAngle() {
    if (widget.angles.length <= 1) return;
    setState(() {
      _selectedAngleIndex = (_selectedAngleIndex - 1 + widget.angles.length) % widget.angles.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentCut = _currentCut;
    final hasOriginal = currentCut.originalBytes != null && currentCut.originalBytes!.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back to Live AR',
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.verified, color: Color(0xFF00E5FF), size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.paintName,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.angles.length > 1) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF00E5FF), width: 0.8),
                    ),
                    child: const Text(
                      '360°',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Text(
              '${widget.hexColor} · Finish: ${widget.finish.toUpperCase()} · HD Studio',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share, color: Color(0xFF00E5FF)),
            onPressed: _shareImage,
            tooltip: 'Share Reference Photo',
          ),
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00E5FF)),
                  )
                : const Icon(Icons.download, color: Colors.white),
            onPressed: _saving ? null : _saveToGallery,
            tooltip: 'Save to Gallery',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 360° Angle Switcher Bar (Responsive multi-angle tabs)
            if (widget.angles.length > 1)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                color: const Color(0xFF161B22),
                child: Row(
                  children: List.generate(widget.angles.length, (idx) {
                    final angle = widget.angles[idx];
                    final isSelected = _selectedAngleIndex == idx;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: idx < widget.angles.length - 1 ? 6.0 : 0.0,
                        ),
                        child: InkWell(
                          onTap: () => setState(() => _selectedAngleIndex = idx),
                          borderRadius: BorderRadius.circular(8),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF21262D),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF00E5FF) : Colors.white12,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _angleIcon(angle.label),
                                  size: 14,
                                  color: isSelected ? Colors.black : Colors.white54,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    angle.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isSelected ? Colors.black : Colors.white70,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),

            // Before / After control indicator
            if (hasOriginal)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: const Color(0xFF141922),
                child: Row(
                  children: [
                    const Text('Original', style: TextStyle(fontSize: 12, color: Colors.white60)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbColor: const Color(0xFF00E5FF),
                          activeTrackColor: const Color(0xFF00E5FF),
                          inactiveTrackColor: Colors.white24,
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Slider(
                          value: _splitFraction,
                          onChanged: (v) => setState(() => _splitFraction = v),
                        ),
                      ),
                    ),
                    const Text('AR Painted', style: TextStyle(fontSize: 12, color: Color(0xFF00E5FF), fontWeight: FontWeight.bold)),
                  ],
                ),
              ),

            // Main interactive zoomable & swipeable turntable viewport
            Expanded(
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity != null) {
                    if (details.primaryVelocity! < -200) {
                      _nextAngle();
                    } else if (details.primaryVelocity! > 200) {
                      _prevAngle();
                    }
                  }
                },
                child: Container(
                  color: Colors.black,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final imgSize = _getImageDimensions(currentCut.polishedBytes) ??
                          (currentCut.originalBytes != null ? _getImageDimensions(currentCut.originalBytes!) : null) ??
                          const Size(1080, 1920);

                      return InteractiveViewer(
                        minScale: 1.0,
                        maxScale: 4.5,
                        child: Center(
                          child: hasOriginal
                              ? FittedBox(
                                  fit: BoxFit.contain,
                                  child: SizedBox(
                                    width: imgSize.width,
                                    height: imgSize.height,
                                    child: Stack(
                                      children: [
                                        // Base: Original Car for current angle
                                        Image.memory(
                                          currentCut.originalBytes!,
                                          width: imgSize.width,
                                          height: imgSize.height,
                                          fit: BoxFit.fill,
                                        ),
                                        // Top layer: Polished HD Cut, clipped by split fraction
                                        ClipRect(
                                          clipper: _SplitClipper(_splitFraction),
                                          child: Image.memory(
                                            currentCut.polishedBytes,
                                            width: imgSize.width,
                                            height: imgSize.height,
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                        // Clean vertical divider line bounded to car photo
                                        Positioned(
                                          left: imgSize.width * _splitFraction - 1.5,
                                          top: 0,
                                          bottom: 0,
                                          child: Container(
                                            width: 3,
                                            color: const Color(0xFF00E5FF),
                                          ),
                                        ),
                                        // Circular grab handle at center of seam
                                        Positioned(
                                          left: imgSize.width * _splitFraction - 22,
                                          top: imgSize.height * 0.5 - 22,
                                          child: Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF00E5FF),
                                              shape: BoxShape.circle,
                                              border: Border.all(color: Colors.white, width: 2),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withValues(alpha: 0.6),
                                                  blurRadius: 10,
                                                  spreadRadius: 2,
                                                ),
                                              ],
                                            ),
                                            child: const Icon(
                                              Icons.compare_arrows,
                                              size: 26,
                                              color: Colors.black,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : Image.memory(
                                  currentCut.polishedBytes,
                                  fit: BoxFit.contain,
                                  width: constraints.maxWidth,
                                  height: constraints.maxHeight,
                                ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),

            // Bottom action bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: const Color(0xFF161B22),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.videocam, size: 18),
                      label: const Text('Back to Live AR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _saving ? null : _saveToGallery,
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(
                        _saving
                            ? 'Saving Photos...'
                            : (widget.angles.length > 1 ? 'Save All Angles' : 'Save to Gallery'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitClipper extends CustomClipper<Rect> {
  final double fraction;
  _SplitClipper(this.fraction);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(size.width * fraction, 0, size.width, size.height);
  }

  @override
  bool shouldReclip(_SplitClipper oldClipper) => oldClipper.fraction != fraction;
}

Size? _getImageDimensions(Uint8List bytes) {
  if (bytes.length < 4) return null;
  // PNG signature: 89 50 4E 47
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    if (bytes.length >= 24) {
      final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      return Size(w.toDouble(), h.toDouble());
    }
  }
  // JPEG signature: FF D8
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    int offset = 2;
    while (offset + 4 < bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      if (marker == 0xD9 || marker == 0xDA) break; // EOI or SOS
      final len = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (marker >= 0xC0 && marker <= 0xC3) {
        if (offset + 9 < bytes.length) {
          final h = (bytes[offset + 5] << 8) | bytes[offset + 6];
          final w = (bytes[offset + 7] << 8) | bytes[offset + 8];
          return Size(w.toDouble(), h.toDouble());
        }
      }
      offset += 2 + len;
    }
  }
  return null;
}

