import 'dart:convert';
import 'dart:io';
import 'package:qr/qr.dart';

String encodeCompressedJsonPayload(Map<String, dynamic> payload) {
  final raw = utf8.encode(jsonEncode(payload));
  final compressed = gzip.encode(raw);
  return base64UrlEncode(compressed);
}

bool encodable(String data) {
  try {
    final qr = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
    final _ = qr.dataCache;
    return true;
  } catch (_) {
    return false;
  }
}

String buildInitialQrData(int itemCount) {
  final items = List.generate(itemCount, (i) => {
    'name': 'ITEM${i.toString().padLeft(5, '0')}',
    'key6': (100000 + i).toString(),
    'status': '–¢ˆ—',
  });
  final payload = {
    'format': 'asset_check_session_v1',
    'sessionId': 'abcdef12',
    'createdAt': '2026-04-20T00:00:00Z',
    'mode': 'csv',
    'rangeStart': 1,
    'rangeEnd': itemCount,
    'items': items,
  };
  final env = {
    'protocol': 'asset_check_sync_v1',
    'type': 'initial_session_packet',
    'payload': encodeCompressedJsonPayload(payload),
  };
  return jsonEncode(env);
}

String buildDiffQrData(int eventCount, {required String action, required bool withItemName}) {
  final events = List.generate(eventCount, (i) => {
    'eventId': 'dev1234-${i + 1}',
    'sessionId': 'abcdef12',
    'deviceId': 'dev1234',
    'seq': i + 1,
    'occurredAt': '2026-04-20T00:00:${(i % 60).toString().padLeft(2, '0')}Z',
    'action': action,
    'key6': (100000 + i).toString(),
    'status': action == 'set_status' ? 'OK' : null,
    'itemName': withItemName ? 'ITEM${i.toString().padLeft(5, '0')}' : null,
  });

  final payload = {
    'format': 'asset_check_diff_v1',
    'sessionId': 'abcdef12',
    'deviceId': 'dev1234',
    'deviceLabel': 'Device A',
    'createdAt': '2026-04-20T00:00:00Z',
    'events': events,
  };

  final env = {
    'protocol': 'asset_check_sync_v1',
    'type': 'diff_packet',
    'payload': encodeCompressedJsonPayload(payload),
  };
  return jsonEncode(env);
}

int findLimit(String Function(int) builder, int hi) {
  var lo = 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    final ok = encodable(builder(mid));
    if (ok) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

void main() {
  final initial = findLimit(buildInitialQrData, 1200);
  final diffSetStatus = findLimit((n) => buildDiffQrData(n, action: 'set_status', withItemName: false), 1200);
  final diffAddNg = findLimit((n) => buildDiffQrData(n, action: 'add_ng', withItemName: true), 1200);
  final diffDelete = findLimit((n) => buildDiffQrData(n, action: 'delete_item', withItemName: true), 1200);

  print('initial_limit=$initial');
  print('diff_set_status_limit=$diffSetStatus');
  print('diff_add_ng_limit=$diffAddNg');
  print('diff_delete_item_limit=$diffDelete');
}
