import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum OcrImportReviewAction { continueShooting, finishImport, cancel }

class OcrSelectionResult {
  final String imagePath;
  final Rect normalizedRect;

  const OcrSelectionResult({
    required this.imagePath,
    required this.normalizedRect,
  });
}

class OcrCropSelectionScreen extends StatefulWidget {
  final String imagePath;

  const OcrCropSelectionScreen({
    super.key,
    required this.imagePath,
  });

  @override
  State<OcrCropSelectionScreen> createState() => _OcrCropSelectionScreenState();
}

class _OcrCropSelectionScreenState extends State<OcrCropSelectionScreen> {
  double _left = 0.08;
  double _top = 0.1;
  double _right = 0.92;
  double _bottom = 0.9;
  bool _isSaving = false;
  Size? _sourceImageSize;

  @override
  void initState() {
    super.initState();
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _sourceImageSize =
            Size(decoded.width.toDouble(), decoded.height.toDouble());
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('画像の読み込みに失敗しました')),
      );
      Navigator.of(context).pop();
    }
  }

  void _resetSelection() {
    setState(() {
      _left = 0.08;
      _top = 0.1;
      _right = 0.92;
      _bottom = 0.9;
    });
  }

  void _moveSelection(Offset delta) {
    final dx = delta.dx;
    final dy = delta.dy;
    final width = _right - _left;
    final height = _bottom - _top;

    setState(() {
      _left = (_left + dx).clamp(0.0, 1.0 - width);
      _top = (_top + dy).clamp(0.0, 1.0 - height);
      _right = _left + width;
      _bottom = _top + height;
    });
  }

  void _resizeSelection({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) {
    const minSize = 0.12;

    setState(() {
      final nextLeft = (left ?? _left).clamp(0.0, _right - minSize);
      final nextTop = (top ?? _top).clamp(0.0, _bottom - minSize);
      final nextRight = (right ?? _right).clamp(nextLeft + minSize, 1.0);
      final nextBottom = (bottom ?? _bottom).clamp(nextTop + minSize, 1.0);

      _left = nextLeft;
      _top = nextTop;
      _right = nextRight;
      _bottom = nextBottom;
    });
  }

  Future<void> _saveCrop() async {
    if (_isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        OcrSelectionResult(
          imagePath: widget.imagePath,
          normalizedRect: Rect.fromLTRB(_left, _top, _right, _bottom),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OCR範囲の確定に失敗しました: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR範囲を選択'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _resetSelection,
            child: const Text('リセット'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                'ノイズを除きたい範囲だけを囲んでください',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final imageSize = _sourceImageSize;
                    if (imageSize == null) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final fittedRect = _calculateFittedRect(
                      Size(constraints.maxWidth, constraints.maxHeight),
                      imageSize,
                    );

                    final selectionRect = Rect.fromLTRB(
                      fittedRect.left + fittedRect.width * _left,
                      fittedRect.top + fittedRect.height * _top,
                      fittedRect.left + fittedRect.width * _right,
                      fittedRect.top + fittedRect.height * _bottom,
                    );

                    return Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.file(
                                File(widget.imagePath),
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        _SelectionOverlay(
                          imageRect: fittedRect,
                          selectionRect: selectionRect,
                          onMove: (delta) => _moveSelection(
                            Offset(
                              delta.dx / fittedRect.width,
                              delta.dy / fittedRect.height,
                            ),
                          ),
                          onResizeTopLeft: (delta) => _resizeSelection(
                            left: _left + delta.dx / fittedRect.width,
                            top: _top + delta.dy / fittedRect.height,
                          ),
                          onResizeTopRight: (delta) => _resizeSelection(
                            right: _right + delta.dx / fittedRect.width,
                            top: _top + delta.dy / fittedRect.height,
                          ),
                          onResizeBottomLeft: (delta) => _resizeSelection(
                            left: _left + delta.dx / fittedRect.width,
                            bottom: _bottom + delta.dy / fittedRect.height,
                          ),
                          onResizeBottomRight: (delta) => _resizeSelection(
                            right: _right + delta.dx / fittedRect.width,
                            bottom: _bottom + delta.dy / fittedRect.height,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSaving ? null : _saveCrop,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.document_scanner_outlined),
                  label: Text(_isSaving ? '処理中...' : 'この範囲でOCR'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Rect _calculateFittedRect(Size viewport, Size source) {
    final scale = math.min(
      viewport.width / source.width,
      viewport.height / source.height,
    );
    final width = source.width * scale;
    final height = source.height * scale;
    final left = (viewport.width - width) / 2;
    final top = (viewport.height - height) / 2;
    return Rect.fromLTWH(left, top, width, height);
  }
}

Future<ui.Image> decodeImageFromList(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

class _SelectionOverlay extends StatelessWidget {
  final Rect imageRect;
  final Rect selectionRect;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResizeTopLeft;
  final ValueChanged<Offset> onResizeTopRight;
  final ValueChanged<Offset> onResizeBottomLeft;
  final ValueChanged<Offset> onResizeBottomRight;

  const _SelectionOverlay({
    required this.imageRect,
    required this.selectionRect,
    required this.onMove,
    required this.onResizeTopLeft,
    required this.onResizeTopRight,
    required this.onResizeBottomLeft,
    required this.onResizeBottomRight,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          _shade(
            left: imageRect.left,
            top: imageRect.top,
            width: imageRect.width,
            height: selectionRect.top - imageRect.top,
          ),
          _shade(
            left: imageRect.left,
            top: selectionRect.bottom,
            width: imageRect.width,
            height: imageRect.bottom - selectionRect.bottom,
          ),
          _shade(
            left: imageRect.left,
            top: selectionRect.top,
            width: selectionRect.left - imageRect.left,
            height: selectionRect.height,
          ),
          _shade(
            left: selectionRect.right,
            top: selectionRect.top,
            width: imageRect.right - selectionRect.right,
            height: selectionRect.height,
          ),
          Positioned(
            left: selectionRect.left,
            top: selectionRect.top,
            width: selectionRect.width,
            height: selectionRect.height,
            child: GestureDetector(
              onPanUpdate: (details) => onMove(details.delta),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.lightGreenAccent, width: 3),
                ),
                child: CustomPaint(
                  painter: _GridPainter(),
                ),
              ),
            ),
          ),
          _handle(selectionRect.topLeft, onResizeTopLeft),
          _handle(selectionRect.topRight, onResizeTopRight),
          _handle(selectionRect.bottomLeft, onResizeBottomLeft),
          _handle(selectionRect.bottomRight, onResizeBottomRight),
        ],
      ),
    );
  }

  Widget _shade({
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    if (width <= 0 || height <= 0) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Container(color: Colors.black.withValues(alpha: 0.55)),
      ),
    );
  }

  Widget _handle(Offset center, ValueChanged<Offset> onDrag) {
    const size = 32.0;
    return Positioned(
      left: center.dx - size / 2,
      top: center.dy - size / 2,
      width: size,
      height: size,
      child: GestureDetector(
        onPanUpdate: (details) => onDrag(details.delta),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.lightGreenAccent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.black87, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    for (int i = 1; i < 3; i++) {
      final dx = size.width * i / 3;
      final dy = size.height * i / 3;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

