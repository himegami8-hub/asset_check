import 'dart:convert';
import 'dart:io';
import 'package:qr_flutter/qr_flutter.dart';

String encodeCompressedJsonPayload(Map<String, dynamic> payload) {
  final raw = utf8.encode(jsonEncode(payload));
  final compressed = gzip.encode(raw);
  return base64UrlEncode(compressed);
}

String makeQrData(int count, {required int nameLen}) {
  const syncProtocolName = 'asset_check_sync_v1';
  const sessionId = 'abcdef12';
  final name = 'A' * nameLen;
  final items = List.generate(count, (i) => {
    'name': '$name${i.toString().padLeft(4, '0')}',
    'key6': (100000 + (i % 900000)).toString(),
    'status': 'pending',
  });
  final payload = {
    'format': 'asset_check_session_v1',
    'sessionId': sessionId,
    'createdAt': '2026-04-20T00:00:00Z',
    'mode': 'csv',
    'rangeStart': 1,
    'rangeEnd': count,
    'items': items,
  };
  final qrEnvelope = {
    'protocol': syncProtocolName,
    'type': 'initial_session_packet',
    'payload': encodeCompressedJsonPayload(payload),
  };
  return jsonEncode(qrEnvelope);
}

bool validQr(String data) {
  final v = QrValidator.validate(
    data: data,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
  );
  return v.status == QrValidationStatus.valid;
}

int findLimit({required int nameLen}) {
  var lo = 1;
  var hi = 5000;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    final ok = validQr(makeQrData(mid, nameLen: nameLen));
    if (ok) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

void main() {
  final lengths = [4, 8, 12, 20, 32];
  for (final len in lengths) {
    final limit = findLimit(nameLen: len);
    final sample = makeQrData(limit, nameLen: len);
    final next = makeQrData(limit + 1, nameLen: len);
    print('nameLen=$len => maxItems=$limit, qrDataLen=${sample.length}, nextValid=${validQr(next)}');
  }
}
