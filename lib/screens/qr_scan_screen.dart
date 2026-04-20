import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({
    super.key,
    this.chunkMode = false,
    this.expectedPacketType,
  });

  final bool chunkMode;
  final String? expectedPacketType;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  static const String syncProtocolName = 'asset_check_sync_v1';

  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool handled = false;
  String activeTransferId = '';
  String activePacketType = '';
  int expectedChunks = 0;
  final Map<int, String> chunkMap = {};
  String statusMessage = '送信側のQRを枠内に合わせてください';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void handleChunkScan(String raw) {
    Map<String, dynamic> decoded;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        return;
      }
      decoded = json;
    } catch (_) {
      return;
    }

    if (decoded['protocol'] != syncProtocolName ||
        decoded['type'] != 'chunk_packet_v1') {
      return;
    }

    final packetType = decoded['packetType'] as String? ?? '';
    if (packetType.isEmpty) {
      return;
    }
    final expectedType = widget.expectedPacketType;
    if (expectedType != null &&
        expectedType.isNotEmpty &&
        expectedType != packetType) {
      setState(() {
        statusMessage = '別タイプのQRです（$packetType）';
      });
      return;
    }

    final transferId = decoded['transferId'] as String? ?? '';
    final total = decoded['total'] as int? ?? 0;
    final index = decoded['index'] as int? ?? 0;
    final chunk = decoded['payloadChunk'] as String? ?? '';
    if (transferId.isEmpty ||
        total <= 0 ||
        index <= 0 ||
        index > total ||
        chunk.isEmpty) {
      return;
    }

    if (activeTransferId.isEmpty) {
      activeTransferId = transferId;
      activePacketType = packetType;
      expectedChunks = total;
    } else if (activeTransferId != transferId) {
      setState(() {
        statusMessage = '別転送のQRを検出しました（現在の転送を優先）';
      });
      return;
    }

    if (expectedChunks != total) {
      return;
    }

    if (!chunkMap.containsKey(index)) {
      chunkMap[index] = chunk;
      setState(() {
        statusMessage = '受信中 ${chunkMap.length}/$expectedChunks';
      });
    }

    if (chunkMap.length != expectedChunks || handled) {
      return;
    }

    final buffer = StringBuffer();
    for (var i = 1; i <= expectedChunks; i++) {
      final value = chunkMap[i];
      if (value == null) {
        return;
      }
      buffer.write(value);
    }

    handled = true;
    Navigator.pop<Map<String, dynamic>>(context, {
      'transferId': activeTransferId,
      'packetType': activePacketType,
      'total': expectedChunks,
      'payload': buffer.toString(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chunkMode ? '連続QRを読み取り' : '受信QRを読み取り')),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              if (handled) {
                return;
              }
              final code = capture.barcodes
                  .map((entry) => entry.rawValue)
                  .whereType<String>()
                  .firstWhere(
                    (value) => value.trim().isNotEmpty,
                    orElse: () => '',
                  );
              if (code.isEmpty) {
                return;
              }

              if (widget.chunkMode) {
                handleChunkScan(code);
                return;
              }

              handled = true;
              Navigator.pop(context, code);
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.black.withValues(alpha: 0.45),
              child: Text(
                widget.chunkMode
                    ? (expectedChunks > 0
                          ? '$statusMessage\n同じ転送のQRを順に読み取ってください'
                          : '連続QRを読み取ってください')
                    : '受信側のQRを枠内に合わせてください',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
