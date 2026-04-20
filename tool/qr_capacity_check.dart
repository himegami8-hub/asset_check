import 'dart:convert';
import 'dart:io';
import 'package:qr/qr.dart';

String encodeCompressedJsonPayload(Map<String, dynamic> payload) {
  final raw = utf8.encode(jsonEncode(payload));
  final compressed = gzip.encode(raw);
  return base64UrlEncode(compressed);
}

String makeQrData(int count, {required int nameLen}) {
  const syncProtocolName = 'asset_check_sync_v1';
  const sessionId = 'abcdef12';
  final base = 'A' * nameLen;
  final items = List.generate(count, (i) => {
    'name': '$base${i.toString().padLeft(4, '0')}',
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

bool actuallyEncodable(String data) {
  try {
    final qr = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
    final _ = qr.dataCache; // force encoding
    return true;
  } catch (_) {
    return false;
  }
}

int findLimit({required int nameLen}) {
  var lo = 1;
  var hi = 2000;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    final ok = actuallyEncodable(makeQrData(mid, nameLen: nameLen));
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
    final ok = makeQrData(limit, nameLen: len);
    final ng = makeQrData(limit + 1, nameLen: len);
    print('nameLen=$len => maxItems=$limit, okLen=${ok.length}, nextOk=${actuallyEncodable(ng)}');
  }
}
