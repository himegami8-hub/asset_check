enum CheckMode { csv, range }

enum InputMode { manual, tap, voice }

enum StatusFilter { all, unchecked, ok, review, ng }

enum AppMenuAction {
  viewLog,
  manageExtractionRules,
  toggleKeepAwake,
  exportCsv,
  createBackup,
  restoreBackup,
  clearNgItems,
  resetAll,
  versionInfo,
}

enum SwipeItemAction { ok, pending, delete }

enum SyncMenuAction {
  showInitialSessionQr,
  scanInitialSessionQrAndImport,
  showDiffQr,
  scanDiffQrAndImport,
  exportSession,
  importSession,
  importDiff,
}

class Item {
  final String name;
  final String key6;
  String status;
  String? previousStatus;
  bool? needsSelection;

  Item(
    this.name,
    this.key6, {
    this.status = '未処理',
    this.previousStatus,
    this.needsSelection = false,
  });

  factory Item.fromJson(Map<String, dynamic> json) {
    return Item(
      json['name'] as String? ?? '',
      json['key6'] as String? ?? '',
      status: json['status'] as String? ?? '未処理',
      previousStatus: json['previousStatus'] as String?,
      needsSelection: json['needsSelection'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'key6': key6,
      'status': status,
      'previousStatus': previousStatus,
      'needsSelection': needsSelection ?? false,
    };
  }
}

class OperationLogEntry {
  final String timestamp;
  final String message;

  const OperationLogEntry({required this.timestamp, required this.message});

  factory OperationLogEntry.fromJson(Map<String, dynamic> json) {
    return OperationLogEntry(
      timestamp: json['timestamp'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'timestamp': timestamp, 'message': message};
  }
}

class SyncEvent {
  final String eventId;
  final String sessionId;
  final String deviceId;
  final int seq;
  final String occurredAt;
  final String action;
  final String key6;
  final String? status;
  final String? itemName;

  const SyncEvent({
    required this.eventId,
    required this.sessionId,
    required this.deviceId,
    required this.seq,
    required this.occurredAt,
    required this.action,
    required this.key6,
    this.status,
    this.itemName,
  });

  factory SyncEvent.fromJson(Map<String, dynamic> json) {
    return SyncEvent(
      eventId: json['eventId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      seq: json['seq'] as int? ?? 0,
      occurredAt: json['occurredAt'] as String? ?? '',
      action: json['action'] as String? ?? '',
      key6: json['key6'] as String? ?? '',
      status: json['status'] as String?,
      itemName: json['itemName'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'eventId': eventId,
      'sessionId': sessionId,
      'deviceId': deviceId,
      'seq': seq,
      'occurredAt': occurredAt,
      'action': action,
      'key6': key6,
      'status': status,
      'itemName': itemName,
    };
  }
}

class SyncIncomingParseResult {
  final List<SyncEvent> incoming;
  final int skippedSession;
  final int skippedDuplicate;

  const SyncIncomingParseResult({
    required this.incoming,
    required this.skippedSession,
    required this.skippedDuplicate,
  });
}

class SyncMergeResult {
  final int imported;
  final int duplicatePendingCount;

  const SyncMergeResult({
    required this.imported,
    required this.duplicatePendingCount,
  });
}

class RangeConfigResult {
  final int start;
  final int end;

  const RangeConfigResult({required this.start, required this.end});
}
