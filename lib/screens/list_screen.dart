import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:asset_check/models.dart';
import 'package:asset_check/ocr_import_flow.dart';
import 'package:asset_check/screens/qr_scan_screen.dart';
import 'package:asset_check/screens/range_config_screen.dart';
import 'package:asset_check/widgets/extraction_rule_settings_dialog.dart';

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  static const String syncProtocolName = 'asset_check_sync_v1';
  static const String chunkPacketType = 'chunk_packet_v1';
  static const String initialSessionPacketType = 'initial_session_packet';
  static const String diffPacketType = 'diff_packet';
  static const int qrChunkSizeDefault = 680;
  static const int qrChunkSizeMinimum = 240;
  static const int qrChunkSizeStep = 40;
  static const double listItemBaseMinHeight = 72;
  static const double listItemExpandedMinHeight = 92;
  static const double swipeActionButtonWidth = 76;
  static const double swipeActionRevealWidth = swipeActionButtonWidth * 3;
  static const double swipeUpdateThreshold = 0.75;
  static const Duration highlightDuration = Duration(seconds: 2);
  static const String autoBackupFileName = 'asset_check_autosave.json';
  static const String manualBackupFileName = 'asset_check_manual_backup.json';

  CheckMode mode = CheckMode.csv;
  InputMode inputMode = InputMode.manual;
  StatusFilter statusFilter = StatusFilter.all;
  List<Item> csvItems = [];
  List<Item> rangeItems = [];
  List<OperationLogEntry> operationLogs = [];
  final List<String> checkHistory = [];
  String lastInput = '';
  String lastResult = '';
  String duplicateInfo = '';
  int? rangeStart;
  int? rangeEnd;
  Item? highlightedItem;
  OverlayEntry? messageOverlayEntry;
  final ScrollController listScrollController = ScrollController();
  final Map<Item, GlobalKey> itemTileKeys = {};
  final Map<Item, ValueNotifier<double>> itemSwipeOffsetNotifiers = {};
  Item? activeSwipeItem;
  final TextEditingController inputController = TextEditingController();
  final FocusNode inputFocusNode = FocusNode();
  final SpeechToText speechToText = SpeechToText();
  String liveInput = '';
  bool speechEnabled = false;
  bool isListening = false;
  bool isAutoSaving = false;
  bool autoSavePending = false;
  bool isDialogShowing = false;
  bool keepAwakeEnabled = false;
  List<String> customExtractionPatterns = [];
  String deviceId = '';
  String deviceLabel = '';
  String syncSessionId = '';
  int nextSyncEventSeq = 1;
  int lastExportedSyncSeq = 0;
  List<SyncEvent> syncEvents = [];
  String syncReceiverToken = '';

  @override
  void initState() {
    super.initState();
    csvItems = buildInitialCsvItems();
    initSpeech();
    restoreAutoBackup().then((_) {
      ensureSyncIdentity();
    });
    syncKeepAwakeState();
  }

  @override
  void dispose() {
    messageOverlayEntry?.remove();
    speechToText.stop();
    for (final notifier in itemSwipeOffsetNotifiers.values) {
      notifier.dispose();
    }
    listScrollController.dispose();
    inputController.dispose();
    inputFocusNode.dispose();
    super.dispose();
  }

  List<Item> get currentItems {
    return mode == CheckMode.csv ? csvItems : rangeItems;
  }

  List<Item> get filteredItems {
    switch (statusFilter) {
      case StatusFilter.all:
        return currentItems;
      case StatusFilter.unchecked:
        return currentItems.where((item) => item.status == '未処理').toList();
      case StatusFilter.ok:
        return currentItems.where((item) => item.status == 'OK').toList();
      case StatusFilter.review:
        return currentItems.where((item) => item.status == '保留').toList();
      case StatusFilter.ng:
        return currentItems.where((item) => item.status == 'NG').toList();
    }
  }

  String normalizeToKey6(String input) {
    final digitsOnly = input.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.isEmpty) return '';
    if (digitsOnly.length > 6) {
      return digitsOnly.substring(digitsOnly.length - 6);
    }
    return digitsOnly.padLeft(6, '0');
  }

  String normalizeIdentifierForExactMatch(String input) {
    // ID照合は英数字の表記ゆれを吸収して照合する。
    return normalizeIdentifierStrict(input);
  }

  String normalizeIdentifierStrict(String input) {
    if (input.isEmpty) {
      return '';
    }
    final buffer = StringBuffer();
    for (final unit in input.codeUnits) {
      if (unit >= 0xFF10 && unit <= 0xFF19) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else if (unit >= 0xFF21 && unit <= 0xFF3A) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else if (unit >= 0xFF41 && unit <= 0xFF5A) {
        buffer.writeCharCode(unit - 0xFEE0);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    var normalized = buffer.toString().toUpperCase();
    normalized = normalized.replaceAll(RegExp(r'[\s\-_/:：．.・\\]+'), '');
    normalized = normalized.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    normalized = normalized.replaceAll('O', '0');
    return normalized;
  }

  bool isAmbiguousMStyleInput(String input) {
    final normalized = normalizeIdentifierStrict(input);
    return RegExp(r'^M0\d{5,7}$').hasMatch(normalized);
  }

  Set<String> buildItemExactMatchTokens(Item item) {
    return buildItemExactMatchTokensByNormalizer(
      item,
      normalize: normalizeIdentifierForExactMatch,
    );
  }

  Set<String> buildItemStrictMatchTokens(Item item) {
    return buildItemExactMatchTokensByNormalizer(
      item,
      normalize: normalizeIdentifierStrict,
    );
  }

  Set<String> buildItemExactMatchTokensByNormalizer(
    Item item, {
    required String Function(String) normalize,
  }) {
    final tokens = <String>{};

    void push(String raw) {
      final normalized = normalize(raw);
      if (normalized.isEmpty) {
        return;
      }
      final hasDigit = RegExp(r'\d').hasMatch(normalized);
      if (!hasDigit) {
        return;
      }
      if (normalized.length >= 4) {
        tokens.add(normalized);
      }
    }

    push(item.name);
    push(item.key6);

    final name = item.name;
    for (final part in name.split(RegExp(r'[\s、,，;；\|()（）\[\]【】]+'))) {
      push(part);
    }

    for (final pattern in customExtractionPatterns) {
      try {
        final regex = RegExp(pattern, caseSensitive: false);
        for (final match in regex.allMatches(name)) {
          if (match.groupCount >= 1) {
            for (var i = 1; i <= match.groupCount; i++) {
              final group = match.group(i);
              if (group != null && group.isNotEmpty) {
                push(group);
              }
            }
          }
          final full = match.group(0);
          if (full != null && full.isNotEmpty) {
            push(full);
          }
        }
      } catch (_) {
        // Ignore invalid custom expressions while matching.
      }
    }
    return tokens;
  }

  String? extractPrimaryIdentifierFromText(String text) {
    final normalized = normalizeIdentifierForExactMatch(text);
    final alphaNum = RegExp(r'[A-Z]{1,8}\d{6,}').firstMatch(normalized);
    if (alphaNum != null) {
      return alphaNum.group(0);
    }
    final longDigits = RegExp(r'\d{7,}').firstMatch(normalized);
    return longDigits?.group(0);
  }

  String chooseBestKeyFromLine(String line, List<String> candidates) {
    if (candidates.isEmpty) {
      return '';
    }
    final primary = extractPrimaryIdentifierFromText(line);
    if (primary != null && primary.isNotEmpty) {
      final derived = normalizeToKey6(primary);
      if (derived.isNotEmpty) {
        return derived;
      }
    }
    return candidates.first;
  }

  String normalizeOcrDigits(String input) {
    var normalized = input;
    const replacements = <String, String>{
      '０': '0',
      '１': '1',
      '２': '2',
      '３': '3',
      '４': '4',
      '５': '5',
      '６': '6',
      '７': '7',
      '８': '8',
      '９': '9',
      'Ｏ': '0',
      'ｏ': '0',
      'o': '0',
      'O': '0',
      'I': '1',
      'l': '1',
      '|': '1',
      'S': '5',
      's': '5',
    };
    for (final entry in replacements.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized;
  }

  String normalizeIdLikeTextForDisplay(String input) {
    if (input.isEmpty) {
      return input;
    }
    final ocrUnifiedInput = input
        .replaceAll('Ｏ', '0')
        .replaceAll('ｏ', '0')
        .replaceAll('O', '0')
        .replaceAll('o', '0');
    final separatorPattern = RegExp(r'[\s\-_/:：．.・\\]+');

    String normalizeAscii(String value) {
      final buffer = StringBuffer();
      for (final unit in value.codeUnits) {
        if (unit >= 0xFF10 && unit <= 0xFF19) {
          buffer.writeCharCode(unit - 0xFEE0);
        } else if (unit >= 0xFF21 && unit <= 0xFF3A) {
          buffer.writeCharCode(unit - 0xFEE0);
        } else if (unit >= 0xFF41 && unit <= 0xFF5A) {
          buffer.writeCharCode(unit - 0xFEE0);
        } else {
          buffer.writeCharCode(unit);
        }
      }
      return buffer.toString().toUpperCase();
    }

    String normalizeMStyleToken(String token) {
      var normalized = normalizeAscii(token);
      normalized = normalized.replaceAll(separatorPattern, '');
      normalized = normalized.replaceAll('Ｏ', '0').replaceAll('O', '0');
      final mStyle = RegExp(r'^M(?:0)?([0-9]{5,7})$').firstMatch(normalized);
      if (mStyle == null) {
        return normalized;
      }
      final digits = mStyle.group(1) ?? '';
      if (digits.isEmpty) {
        return normalized;
      }
      return 'M${digits.padLeft(7, '0')}';
    }

    return ocrUnifiedInput.replaceAllMapped(
      RegExp(
        r'(?<![A-Z0-9])[MＭ](?:[\s\-_/:：．.・\\]*[0０])?(?:[\s\-_/:：．.・\\]*[0-9０-９0０]){5,7}(?![A-Z0-9])',
        caseSensitive: false,
      ),
      (match) => normalizeMStyleToken(match.group(0) ?? ''),
    );
  }

  String addBoundaryAfterAlphaPrefix(String input) {
    if (input.isEmpty) {
      return input;
    }
    return input.replaceAllMapped(
      RegExp(r'\b([A-Za-zＡ-Ｚａ-ｚ]{1,4})([OＯoｏ0０0-9０-９]{5,})\b'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
  }

  List<String> extractKey6CandidatesFromText(String line) {
    final normalizedLine = normalizeOcrDigits(line);
    if (normalizedLine.trim().isEmpty) {
      return const [];
    }
    final hasMMarker = RegExp(r'[mMＭｍ]').hasMatch(line);

    final candidates = <String>[];
    final seen = <String>{};

    void pushCandidate(String rawDigits) {
      final digitsOnly = rawDigits.replaceAll(RegExp(r'\D'), '');
      if (digitsOnly.length < 6) {
        return;
      }
      final key6 = normalizeToKey6(digitsOnly);
      if (seen.add(key6)) {
        candidates.add(key6);
      }
    }

    for (final pattern in customExtractionPatterns) {
      try {
        final regex = RegExp(pattern, caseSensitive: false);
        for (final source in [line, normalizedLine]) {
          for (final match in regex.allMatches(source)) {
            if (match.groupCount >= 1) {
              var captured = false;
              for (var i = 1; i <= match.groupCount; i++) {
                final group = match.group(i);
                if (group == null || group.isEmpty) {
                  continue;
                }
                pushCandidate(group);
                captured = true;
              }
              if (captured) {
                continue;
              }
            }

            final fullMatch = match.group(0);
            if (fullMatch != null && fullMatch.isNotEmpty) {
              pushCandidate(fullMatch);
            }
          }
        }
      } catch (_) {
        // Ignore invalid custom expressions while extracting.
      }
    }
    if (candidates.isNotEmpty) {
      return candidates;
    }

    final mPrefixedMatches = RegExp(r'M[\s\-_:]*\d{6,}', caseSensitive: false)
        .allMatches(normalizedLine)
        .map((match) => match.group(0))
        .whereType<String>();
    for (final token in mPrefixedMatches) {
      pushCandidate(token);
    }
    if (candidates.isNotEmpty) {
      return candidates;
    }

    // Mが欠けても長い連番(7桁以上)は機器番号である可能性が高いため先に拾う。
    final longDigitMatches = RegExp(r'\d{7,}')
        .allMatches(normalizedLine)
        .map((match) => match.group(0))
        .whereType<String>();
    for (final token in longDigitMatches) {
      pushCandidate(token);
    }
    if (candidates.isNotEmpty) {
      return candidates;
    }

    // 誤検出を減らすため、M系の文字がない行は6桁単体抽出をしない。
    if (!hasMMarker) {
      return const [];
    }

    final sixDigitMatches = RegExp(r'(?<!\d)\d{6}(?!\d)')
        .allMatches(normalizedLine)
        .map((match) => match.group(0))
        .whereType<String>();
    for (final token in sixDigitMatches) {
      pushCandidate(token);
    }

    if (candidates.isNotEmpty) {
      return candidates;
    }

    final digitsOnly = normalizedLine.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.length >= 6) {
      pushCandidate(digitsOnly);
    }
    return candidates;
  }

  String formatRangeValue(int value) {
    return value.toString().padLeft(4, '0');
  }

  String normalizeSpeechInput(String input) {
    if (input.trim().isEmpty) {
      return '';
    }

    var normalized = input.toLowerCase();

    const speechReplacements = <String, String>{
      '０': '0',
      '１': '1',
      '２': '2',
      '３': '3',
      '４': '4',
      '５': '5',
      '６': '6',
      '７': '7',
      '８': '8',
      '９': '9',
      'ゼロ': '0',
      'れい': '0',
      '零': '0',
      '〇': '0',
      'まる': '0',
      '丸': '0',
      'いち': '1',
      '一': '1',
      'に': '2',
      '二': '2',
      'さん': '3',
      '三': '3',
      'よん': '4',
      'し': '4',
      '四': '4',
      'ご': '5',
      '五': '5',
      'ろく': '6',
      '六': '6',
      'なな': '7',
      'しち': '7',
      '七': '7',
      'はち': '8',
      '八': '8',
      'きゅう': '9',
      'く': '9',
      '九': '9',
      'zero': '0',
      'one': '1',
      'two': '2',
      'three': '3',
      'four': '4',
      'five': '5',
      'six': '6',
      'seven': '7',
      'eight': '8',
      'nine': '9',
      'エムオー': 'm0',
      'えむおー': 'm0',
      'エムゼロ': 'm0',
      'えむぜろ': 'm0',
      'エム': 'm',
      'えむ': 'm',
      'オー': '0',
      'おー': '0',
    };

    for (final entry in speechReplacements.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }

    normalized = normalized.replaceAll(RegExp(r'[\s、。,.，・/\\\-_ー－]+'), '');
    normalized = normalized.replaceAll(RegExp(r'[^0-9m]'), '');
    return normalized.toUpperCase();
  }

  String get inputPreview {
    return normalizeToKey6(liveInput);
  }

  Future<File> getBackupFile(String fileName) async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$fileName');
  }

  Future<void> saveBackup(String fileName) async {
    final file = await getBackupFile(fileName);
    final payload = {
      'mode': mode.name,
      'inputMode': inputMode.name,
      'csvItems': csvItems.map((item) => item.toJson()).toList(),
      'rangeItems': rangeItems.map((item) => item.toJson()).toList(),
      'operationLogs': operationLogs.map((entry) => entry.toJson()).toList(),
      'checkHistory': List<String>.from(checkHistory),
      'lastInput': lastInput,
      'lastResult': lastResult,
      'duplicateInfo': duplicateInfo,
      'rangeStart': rangeStart,
      'rangeEnd': rangeEnd,
      'liveInput': liveInput,
      'customExtractionPatterns': List<String>.from(customExtractionPatterns),
      'deviceId': deviceId,
      'deviceLabel': deviceLabel,
      'syncSessionId': syncSessionId,
      'nextSyncEventSeq': nextSyncEventSeq,
      'lastExportedSyncSeq': lastExportedSyncSeq,
      'syncEvents': syncEvents.map((event) => event.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(payload), flush: true);
  }

  Future<void> restoreBackup(String fileName) async {
    try {
      final file = await getBackupFile(fileName);
      if (!await file.exists()) {
        return;
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return;
      }

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final restoredCsvItems = (data['csvItems'] as List<dynamic>? ?? [])
          .map((item) => Item.fromJson(item as Map<String, dynamic>))
          .toList();
      final restoredRangeItems = (data['rangeItems'] as List<dynamic>? ?? [])
          .map((item) => Item.fromJson(item as Map<String, dynamic>))
          .toList();

      if (!mounted) {
        return;
      }

      setState(() {
        mode = CheckMode.values.firstWhere(
          (value) => value.name == data['mode'],
          orElse: () => CheckMode.csv,
        );
        inputMode = InputMode.values.firstWhere(
          (value) => value.name == data['inputMode'],
          orElse: () => InputMode.manual,
        );
        csvItems = restoredCsvItems;
        rangeItems = restoredRangeItems;
        operationLogs = (data['operationLogs'] as List<dynamic>? ?? [])
            .map(
              (item) =>
                  OperationLogEntry.fromJson(item as Map<String, dynamic>),
            )
            .toList();
        checkHistory
          ..clear()
          ..addAll(
            (data['checkHistory'] as List<dynamic>? ?? []).cast<String>(),
          );
        lastInput = data['lastInput'] as String? ?? '';
        lastResult = data['lastResult'] as String? ?? '';
        duplicateInfo = data['duplicateInfo'] as String? ?? '';
        rangeStart = data['rangeStart'] as int?;
        rangeEnd = data['rangeEnd'] as int?;
        liveInput = data['liveInput'] as String? ?? '';
        customExtractionPatterns =
            (data['customExtractionPatterns'] as List<dynamic>? ?? [])
                .map((entry) => entry.toString().trim())
                .where((entry) => entry.isNotEmpty)
                .toList();
        deviceId = data['deviceId'] as String? ?? '';
        deviceLabel = data['deviceLabel'] as String? ?? '';
        syncSessionId = data['syncSessionId'] as String? ?? '';
        nextSyncEventSeq = data['nextSyncEventSeq'] as int? ?? 1;
        lastExportedSyncSeq = data['lastExportedSyncSeq'] as int? ?? 0;
        syncEvents = (data['syncEvents'] as List<dynamic>? ?? [])
            .map((item) => SyncEvent.fromJson(item as Map<String, dynamic>))
            .toList();
        highlightedItem = null;
        cleanupItemUiCaches();
      });
      inputController.text = liveInput;
      inputController.selection = TextSelection.collapsed(
        offset: inputController.text.length,
      );
    } catch (_) {
      // Ignore backup restore errors and continue with the default state.
    }
  }

  Future<void> saveAutoBackup() async {
    await saveBackup(autoBackupFileName);
  }

  Future<void> saveManualBackup() async {
    await saveBackup(manualBackupFileName);
  }

  Future<void> restoreAutoBackup() async {
    await restoreBackup(autoBackupFileName);
  }

  Future<void> restoreManualBackup() async {
    await restoreBackup(manualBackupFileName);
  }

  void queueAutoSave() {
    autoSavePending = true;
    if (isAutoSaving) {
      return;
    }
    processAutoSaveQueue();
  }

  String buildTimestamp() {
    final now = DateTime.now();
    final yyyy = now.year.toString().padLeft(4, '0');
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$min:$ss';
  }

  void addOperationLog(String message) {
    final nextLogs = [
      OperationLogEntry(timestamp: buildTimestamp(), message: message),
      ...operationLogs,
    ];

    operationLogs = nextLogs.take(200).toList();
  }

  String buildUtcIsoTimestamp() {
    return DateTime.now().toUtc().toIso8601String();
  }

  String buildRandomToken(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  String generateDeviceId() {
    return 'dev_${DateTime.now().millisecondsSinceEpoch}_${buildRandomToken(6)}';
  }

  String generateSessionId() {
    return 'sess_${DateTime.now().millisecondsSinceEpoch}_${buildRandomToken(5)}';
  }

  void ensureSyncIdentity() {
    if (!mounted) {
      return;
    }

    var changed = false;
    setState(() {
      if (deviceId.trim().isEmpty) {
        deviceId = generateDeviceId();
        changed = true;
      }
      if (deviceLabel.trim().isEmpty) {
        final suffix = deviceId.length >= 4
            ? deviceId.substring(deviceId.length - 4)
            : deviceId;
        deviceLabel = '端末-$suffix';
        changed = true;
      }
      if (syncSessionId.trim().isEmpty) {
        syncSessionId = generateSessionId();
        changed = true;
      }
      if (nextSyncEventSeq < 1) {
        nextSyncEventSeq = 1;
        changed = true;
      }
    });

    if (changed) {
      queueAutoSave();
    }
  }

  void resetSyncForNewSession(String reason) {
    syncSessionId = generateSessionId();
    nextSyncEventSeq = 1;
    lastExportedSyncSeq = 0;
    syncEvents = [];
    addOperationLog('同期セッションを開始しました: $reason');
  }

  int compareSyncEvents(SyncEvent a, SyncEvent b) {
    final aTime = DateTime.tryParse(a.occurredAt)?.toUtc();
    final bTime = DateTime.tryParse(b.occurredAt)?.toUtc();
    if (aTime != null && bTime != null) {
      final cmp = aTime.compareTo(bTime);
      if (cmp != 0) {
        return cmp;
      }
    } else if (aTime != null && bTime == null) {
      return 1;
    } else if (aTime == null && bTime != null) {
      return -1;
    }

    final seqCmp = a.seq.compareTo(b.seq);
    if (seqCmp != 0) {
      return seqCmp;
    }
    return a.deviceId.compareTo(b.deviceId);
  }

  void recordLocalSyncEvent({
    required String action,
    required String key6,
    String? status,
    String? itemName,
  }) {
    if (deviceId.isEmpty || syncSessionId.isEmpty || key6.isEmpty) {
      return;
    }
    final event = SyncEvent(
      eventId: '$deviceId-$nextSyncEventSeq',
      sessionId: syncSessionId,
      deviceId: deviceId,
      seq: nextSyncEventSeq,
      occurredAt: buildUtcIsoTimestamp(),
      action: action,
      key6: key6,
      status: status,
      itemName: itemName,
    );
    nextSyncEventSeq += 1;
    syncEvents.add(event);
  }

  void applyEventToItems(SyncEvent event, List<Item> items) {
    if (event.key6.isEmpty) {
      return;
    }

    if (event.action == 'delete_item') {
      items.removeWhere((item) => item.key6 == event.key6);
      return;
    }

    if (event.action == 'add_ng') {
      final existing = items.where((item) => item.key6 == event.key6).toList();
      if (existing.isEmpty) {
        items.add(Item(event.itemName ?? '未登録', event.key6, status: 'NG'));
      } else {
        for (final item in existing) {
          item.status = 'NG';
          item.needsSelection = false;
          item.previousStatus = null;
        }
      }
      return;
    }

    if (event.action != 'set_status') {
      return;
    }

    final targetStatus = event.status ?? '';
    if (targetStatus.isEmpty) {
      return;
    }
    final matched = items.where((item) => item.key6 == event.key6).toList();
    if (matched.isEmpty) {
      if (targetStatus == 'NG') {
        items.add(Item(event.itemName ?? '未登録', event.key6, status: 'NG'));
      }
      return;
    }

    for (final item in matched) {
      if (targetStatus == '保留') {
        item.previousStatus ??= item.status;
        item.status = '保留';
        item.needsSelection = true;
      } else {
        item.status = targetStatus;
        item.needsSelection = false;
        item.previousStatus = null;
      }
    }
  }

  int applyCrossDeviceDuplicateHold(List<Item> items) {
    final keyToDevices = <String, Set<String>>{};
    for (final event in syncEvents) {
      if (event.sessionId != syncSessionId) {
        continue;
      }
      if (event.action != 'set_status' ||
          event.status != 'OK' ||
          event.key6.isEmpty) {
        continue;
      }
      keyToDevices
          .putIfAbsent(event.key6, () => <String>{})
          .add(event.deviceId);
    }

    var affected = 0;
    for (final entry in keyToDevices.entries) {
      if (entry.value.length < 2) {
        continue;
      }
      final sameKeys = items.where((item) => item.key6 == entry.key).toList();
      if (sameKeys.isEmpty) {
        continue;
      }
      for (final item in sameKeys) {
        final wasPending = item.status == '保留' && item.needsSelection == true;
        item.previousStatus = item.status == 'OK' ? 'OK' : item.previousStatus;
        item.status = '保留';
        item.needsSelection = true;
        if (!wasPending) {
          affected += 1;
        }
      }
    }
    return affected;
  }

  void cleanupItemUiCaches() {
    final existingItems = <Item>{...csvItems, ...rangeItems};
    itemTileKeys.removeWhere((item, _) => !existingItems.contains(item));
    final removed = itemSwipeOffsetNotifiers.entries
        .where((entry) => !existingItems.contains(entry.key))
        .map((entry) => entry.key)
        .toList();
    for (final item in removed) {
      final notifier = itemSwipeOffsetNotifiers.remove(item);
      notifier?.dispose();
    }
    if (activeSwipeItem != null && !existingItems.contains(activeSwipeItem)) {
      activeSwipeItem = null;
    }
  }

  Future<void> processAutoSaveQueue() async {
    if (isAutoSaving) {
      return;
    }

    isAutoSaving = true;
    try {
      while (autoSavePending) {
        autoSavePending = false;
        await saveAutoBackup();
      }
    } catch (_) {
      // Ignore autosave errors to avoid breaking the main workflow.
    } finally {
      isAutoSaving = false;
    }
  }

  void showCenterMessage(String message) {
    if (!mounted) {
      return;
    }

    try {
      messageOverlayEntry?.remove();
    } catch (_) {}
    final overlay = Overlay.of(context);

    final entry = OverlayEntry(
      builder: (context) {
        return IgnorePointer(
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
        );
      },
    );

    messageOverlayEntry = entry;
    overlay.insert(entry);

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      if (identical(messageOverlayEntry, entry)) {
        messageOverlayEntry = null;
      }
      try {
        entry.remove();
      } catch (_) {}
    });
  }

  Future<void> showOperationLogDialog() async {
    if (isDialogShowing) {
      return;
    }
    isDialogShowing = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('操作ログ'),
          content: SizedBox(
            width: double.maxFinite,
            child: operationLogs.isEmpty
                ? const Text('まだ操作ログはありません')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: operationLogs.length,
                    separatorBuilder: (_, _) => const Divider(height: 16),
                    itemBuilder: (context, index) {
                      final entry = operationLogs[index];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.timestamp,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          Text(entry.message),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;
  }

  Future<void> showExtractionRuleSettingsDialog() async {
    if (isDialogShowing) {
      return;
    }

    bool saved = false;
    isDialogShowing = true;
    try {
      final result = await showDialog<List<String>>(
        context: context,
        builder: (dialogContext) {
          return ExtractionRuleSettingsDialog(
            initialPatterns: customExtractionPatterns,
            normalizeText: normalizeOcrDigits,
          );
        },
      );
      if (result != null) {
        setState(() {
          customExtractionPatterns = result;
          addOperationLog(
            result.isEmpty
                ? '抽出ルールを既定値に戻しました'
                : '抽出ルールを更新しました: ${result.length}件',
          );
        });
        queueAutoSave();
        saved = true;
      }
    } catch (_) {
      if (mounted) {
        showCenterMessage('抽出ルール設定の表示中にエラーが発生しました');
      }
    } finally {
      isDialogShowing = false;
    }

    if (saved && mounted) {
      showCenterMessage(
        customExtractionPatterns.isEmpty ? '抽出ルールを既定値に戻しました' : '抽出ルールを保存しました',
      );
    }
  }

  Future<void> initSpeech() async {
    speechEnabled = await speechToText.initialize(
      onStatus: handleSpeechStatus,
      onError: (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          isListening = false;
        });
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {});
  }

  Future<void> syncKeepAwakeState() async {
    final enabled = await WakelockPlus.enabled;
    if (!mounted) {
      return;
    }
    setState(() {
      keepAwakeEnabled = enabled;
    });
  }

  Future<void> toggleKeepAwake() async {
    final nextValue = !keepAwakeEnabled;
    await WakelockPlus.toggle(enable: nextValue);
    if (!mounted) {
      return;
    }
    setState(() {
      keepAwakeEnabled = nextValue;
    });
    showCenterMessage(nextValue ? 'スリープ防止をONにしました' : 'スリープ防止をOFFにしました');
  }

  void handleSpeechStatus(String status) {
    if (!mounted) {
      return;
    }

    setState(() {
      isListening = speechToText.isListening;
    });

    if (status == 'done' && inputPreview.isNotEmpty) {
      submitCurrentInput();
    }
  }

  Future<void> loadCsv() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        allowMultiple: false,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;
      final Uint8List? bytes = await readPickedFileBytes(file);

      if (bytes == null) {
        throw Exception('ファイルの読み込みに失敗しました');
      }

      final csvString = utf8.decode(bytes).replaceFirst('\uFEFF', '');
      final rows = const CsvToListConverter().convert(csvString);

      if (rows.isEmpty) {
        throw Exception('CSV が空です');
      }

      final header = rows.first.map((e) => e.toString().trim()).toList();
      final displayNameIndex = header.indexOf('display_name');
      final key6Index = header.indexOf('key6');

      if (displayNameIndex == -1 || key6Index == -1) {
        throw Exception('CSV のヘッダーに display_name,key6 が必要です');
      }

      final List<Item> loadedItems = [];

      for (int i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.length <= key6Index || row.length <= displayNameIndex) {
          continue;
        }

        final name = row[displayNameIndex].toString().trim();
        final normalizedKey = normalizeToKey6(row[key6Index].toString());

        if (name.isEmpty || normalizedKey.isEmpty) {
          continue;
        }

        loadedItems.add(Item(name, normalizedKey));
      }

      if (loadedItems.isEmpty) {
        throw Exception('有効なデータ行がありません');
      }

      setState(() {
        mode = CheckMode.csv;
        csvItems = loadedItems;
        resetSyncForNewSession('CSV読込');
        addOperationLog('CSVを読み込みました: ${loadedItems.length}件');
        checkHistory.clear();
        lastInput = '';
        lastResult = 'CSV読込完了: ${loadedItems.length}件';
        duplicateInfo = '';
        highlightedItem = null;
        cleanupItemUiCaches();
      });
      clearInput();
      queueAutoSave();

      if (!mounted) return;
      showCenterMessage('${loadedItems.length}件 読み込みました');
    } catch (e) {
      if (!mounted) return;
      showCenterMessage('CSV読込エラー: $e');
    }
  }

  Future<void> importListFromCamera() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      showCenterMessage('カメラOCR取込は Android / iPhone で利用できます');
      return;
    }

    final imagePicker = ImagePicker();
    final textRecognizer = TextRecognizer(
      script: TextRecognitionScript.japanese,
    );
    final List<Item> collectedItems = [];
    int scannedPages = 0;

    try {
      while (true) {
        final image = await imagePicker.pickImage(
          source: ImageSource.camera,
          preferredCameraDevice: CameraDevice.rear,
          imageQuality: 88,
          maxWidth: 2200,
          maxHeight: 2200,
        );

        if (image == null) {
          return;
        }

        if (!mounted) {
          return;
        }

        final selectionResult = await Navigator.push<OcrSelectionResult>(
          context,
          MaterialPageRoute(
            builder: (_) => OcrCropSelectionScreen(imagePath: image.path),
          ),
        );

        if (selectionResult == null) {
          return;
        }

        final pageItems = await extractItemsFromImageWithFallback(
          textRecognizer,
          imagePath: selectionResult.imagePath,
          selectionRect: selectionResult.normalizedRect,
        );
        scannedPages++;

        if (!mounted) {
          return;
        }

        final action = await showOcrImportPreviewDialog(
          pageItems: pageItems,
          pageNumber: scannedPages,
          accumulatedCount: collectedItems.length + pageItems.length,
        );

        if (action == null || action == OcrImportReviewAction.cancel) {
          return;
        }

        collectedItems.addAll(pageItems);

        if (action == OcrImportReviewAction.finishImport) {
          break;
        }
      }

      if (collectedItems.isEmpty) {
        showCenterMessage('OCRで有効な6桁コードを抽出できませんでした');
        return;
      }

      setState(() {
        mode = CheckMode.csv;
        csvItems = collectedItems;
        resetSyncForNewSession('カメラOCR読込');
        addOperationLog(
          'カメラOCRで一覧を読み込みました: ${collectedItems.length}件 / $scannedPages枚',
        );
        checkHistory.clear();
        lastInput = '';
        lastResult = 'OCR読込完了: ${collectedItems.length}件';
        duplicateInfo = '';
        highlightedItem = null;
        cleanupItemUiCaches();
      });
      clearInput();
      queueAutoSave();

      if (!mounted) {
        return;
      }
      showCenterMessage('${collectedItems.length}件をカメラOCRで読み込みました');
    } catch (e) {
      if (!mounted) {
        return;
      }
      showCenterMessage('カメラOCR読込エラー: $e');
    } finally {
      textRecognizer.close();
    }
  }

  List<Item> extractItemsFromRecognizedText(
    RecognizedText recognizedText, {
    Rect? selectionRect,
  }) {
    final lines = <String>[];
    var maxRight = 0.0;
    var maxBottom = 0.0;

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final box = line.boundingBox;
        if (box.right > maxRight) {
          maxRight = box.right;
        }
        if (box.bottom > maxBottom) {
          maxBottom = box.bottom;
        }
      }
    }

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) {
          continue;
        }

        if (selectionRect != null) {
          final box = line.boundingBox;
          if (!isLineInsideSelection(
            box,
            selectionRect,
            maxRight: maxRight,
            maxBottom: maxBottom,
          )) {
            continue;
          }
        }
        lines.add(text);
      }
    }

    if (lines.isEmpty) {
      lines.addAll(
        recognizedText.text
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
    }

    final extractedItems = <Item>[];
    final seenLineSignatures = <String>{};
    for (final line in lines) {
      final compactLine = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      final boundaryAdjustedLine = addBoundaryAfterAlphaPrefix(compactLine);
      final normalizedKeys = extractKey6CandidatesFromText(
        boundaryAdjustedLine,
      );
      if (normalizedKeys.isEmpty) {
        continue;
      }

      final displayLine = normalizeIdLikeTextForDisplay(compactLine);
      final firstKey = chooseBestKeyFromLine(
        boundaryAdjustedLine,
        normalizedKeys,
      );
      if (firstKey.isEmpty) {
        continue;
      }
      final lineSignature =
          '${normalizeIdentifierForExactMatch(displayLine)}|$firstKey';
      if (!seenLineSignatures.add(lineSignature)) {
        continue;
      }

      extractedItems.add(
        Item(displayLine.isEmpty ? 'OCR $firstKey' : displayLine, firstKey),
      );
    }

    return extractedItems;
  }

  Future<List<Item>> extractItemsFromImageWithFallback(
    TextRecognizer textRecognizer, {
    required String imagePath,
    Rect? selectionRect,
  }) async {
    final attemptFiles = <String>[imagePath];
    final attempts = <({String path, Rect? selectionRect})>[
      (path: imagePath, selectionRect: selectionRect),
    ];

    final rotatedPaths = await createRotatedImagePaths(imagePath);
    attemptFiles.addAll(rotatedPaths);
    for (var i = 0; i < rotatedPaths.length; i++) {
      final rotatedPath = rotatedPaths[i];
      final transformedSelection = selectionRect == null
          ? null
          : transformSelectionRectForRotation(selectionRect, i == 0 ? 90 : -90);
      attempts.add((path: rotatedPath, selectionRect: transformedSelection));
    }

    List<Item> bestItems = const [];
    final selectedItems = <Item>[];
    final itemByKey = <String, Item>{};
    final keyFrequency = <String, int>{};

    try {
      for (var i = 0; i < attempts.length; i++) {
        final attempt = attempts[i];
        final recognizedText = await textRecognizer.processImage(
          InputImage.fromFilePath(attempt.path),
        );
        final items = dedupeItems(
          extractItemsFromRecognizedText(
            recognizedText,
            selectionRect: attempt.selectionRect,
          ),
        );
        if (items.length > bestItems.length) {
          bestItems = items;
        }
        if (i == 0) {
          selectedItems
            ..clear()
            ..addAll(items);
        }
        for (final item in items.where((entry) => entry.key6.isNotEmpty)) {
          itemByKey.putIfAbsent(item.key6, () => item);
          keyFrequency.update(
            item.key6,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
      }
    } finally {
      for (final path in attemptFiles) {
        if (path == imagePath) {
          continue;
        }
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }

    final votedItems = <Item>[];
    final addedKeys = <String>{};

    for (final item in selectedItems) {
      if (addedKeys.add(item.key6)) {
        votedItems.add(item);
      }
    }

    for (final entry in keyFrequency.entries) {
      if (entry.value < 2) {
        continue;
      }
      final item = itemByKey[entry.key];
      if (item == null) {
        continue;
      }
      if (addedKeys.add(item.key6)) {
        votedItems.add(item);
      }
    }

    // 精度優先: 既に1st試行 + 複数回一致で候補を構成できている場合、
    // bestItems(最大件数試行)の単発キーは混入させない。
    // 1st試行が空のときだけ bestItems を採用して取りこぼしを補う。
    if (votedItems.isEmpty) {
      for (final item in bestItems) {
        if (addedKeys.add(item.key6)) {
          votedItems.add(item);
        }
      }
    }

    final withPrimaryCount = votedItems
        .where((item) => extractPrimaryIdentifierFromText(item.name) != null)
        .length;
    final primaryRatio = votedItems.isEmpty
        ? 0.0
        : (withPrimaryCount / votedItems.length);
    final shouldSuppressPrimaryLessSingletons =
        votedItems.length >= 10 && primaryRatio >= 0.8;

    List<Item> filteredItems = votedItems;
    if (shouldSuppressPrimaryLessSingletons) {
      final removable = votedItems.where((item) {
        final hasPrimary = extractPrimaryIdentifierFromText(item.name) != null;
        if (hasPrimary) {
          return false;
        }
        final freq = keyFrequency[item.key6] ?? 0;
        return freq <= 1;
      }).toList();

      // 取りこぼしを防ぐため、除外は最大1件までに限定する。
      if (removable.length == 1) {
        filteredItems = votedItems
            .where((item) => !identical(item, removable.first))
            .toList();
      }
    }

    if (filteredItems.isNotEmpty) {
      return dedupeItems(filteredItems);
    }
    return dedupeItems(bestItems);
  }

  Rect transformSelectionRectForRotation(Rect source, int angle) {
    Offset rotatePoint(Offset p) {
      if (angle == 90) {
        return Offset(1 - p.dy, p.dx);
      }
      if (angle == -90) {
        return Offset(p.dy, 1 - p.dx);
      }
      return p;
    }

    final rotatedPoints = <Offset>[
      rotatePoint(source.topLeft),
      rotatePoint(source.topRight),
      rotatePoint(source.bottomLeft),
      rotatePoint(source.bottomRight),
    ];

    var minX = rotatedPoints.first.dx;
    var maxX = rotatedPoints.first.dx;
    var minY = rotatedPoints.first.dy;
    var maxY = rotatedPoints.first.dy;
    for (final point in rotatedPoints.skip(1)) {
      if (point.dx < minX) {
        minX = point.dx;
      }
      if (point.dx > maxX) {
        maxX = point.dx;
      }
      if (point.dy < minY) {
        minY = point.dy;
      }
      if (point.dy > maxY) {
        maxY = point.dy;
      }
    }

    return Rect.fromLTRB(
      minX.clamp(0.0, 1.0),
      minY.clamp(0.0, 1.0),
      maxX.clamp(0.0, 1.0),
      maxY.clamp(0.0, 1.0),
    );
  }

  Future<List<String>> createRotatedImagePaths(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final source = img.decodeImage(bytes);
      if (source == null) {
        return const [];
      }

      final directory = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final rotated90 = img.copyRotate(source, angle: 90);
      final rotated270 = img.copyRotate(source, angle: -90);

      final path90 = '${directory.path}/ocr_rot90_$stamp.jpg';
      final path270 = '${directory.path}/ocr_rot270_$stamp.jpg';

      await File(
        path90,
      ).writeAsBytes(img.encodeJpg(rotated90, quality: 92), flush: true);
      await File(
        path270,
      ).writeAsBytes(img.encodeJpg(rotated270, quality: 92), flush: true);
      return [path90, path270];
    } catch (_) {
      return const [];
    }
  }

  List<Item> dedupeItems(List<Item> items) {
    int buildQualityScore(Item item) {
      var score = 0;
      final primary = extractPrimaryIdentifierFromText(item.name);
      if (primary != null && primary.isNotEmpty) {
        score += 3;
        if (normalizeToKey6(primary) == item.key6) {
          score += 4;
        }
      }
      if (item.name.contains('M') || item.name.contains('m')) {
        score += 1;
      }
      if (RegExp(r'\d{7,}').hasMatch(item.name)) {
        score += 1;
      }
      return score;
    }

    final pickedByGroup = <String, Item>{};
    for (final item in items) {
      final key = item.key6;
      if (key.isEmpty) {
        continue;
      }

      final primary = extractPrimaryIdentifierFromText(item.name);
      final groupKey = primary == null ? 'K:$key' : 'P:$primary';
      final current = pickedByGroup[groupKey];
      if (current == null) {
        pickedByGroup[groupKey] = item;
        continue;
      }

      final currentScore = buildQualityScore(current);
      final nextScore = buildQualityScore(item);
      if (nextScore > currentScore) {
        pickedByGroup[groupKey] = item;
      }
    }

    final deduped = <Item>[];
    final seenKey = <String>{};
    for (final item in pickedByGroup.values) {
      if (seenKey.add(item.key6)) {
        deduped.add(item);
      }
    }
    return deduped;
  }

  bool isLineInsideSelection(
    Rect box,
    Rect selectionRect, {
    required double maxRight,
    required double maxBottom,
  }) {
    if (maxRight <= 0 || maxBottom <= 0) {
      return true;
    }
    const edgeMargin = 0.015;

    final normalizedBox = Rect.fromLTRB(
      (box.left / maxRight).clamp(0.0, 1.0),
      (box.top / maxBottom).clamp(0.0, 1.0),
      (box.right / maxRight).clamp(0.0, 1.0),
      (box.bottom / maxBottom).clamp(0.0, 1.0),
    );
    final expandedSelection = Rect.fromLTRB(
      (selectionRect.left - edgeMargin).clamp(0.0, 1.0),
      (selectionRect.top - edgeMargin).clamp(0.0, 1.0),
      (selectionRect.right + edgeMargin).clamp(0.0, 1.0),
      (selectionRect.bottom + edgeMargin).clamp(0.0, 1.0),
    );

    final intersects = normalizedBox.overlaps(expandedSelection);
    if (!intersects) {
      return false;
    }

    final overlapLeft = normalizedBox.left > expandedSelection.left
        ? normalizedBox.left
        : expandedSelection.left;
    final overlapTop = normalizedBox.top > expandedSelection.top
        ? normalizedBox.top
        : expandedSelection.top;
    final overlapRight = normalizedBox.right < expandedSelection.right
        ? normalizedBox.right
        : expandedSelection.right;
    final overlapBottom = normalizedBox.bottom < expandedSelection.bottom
        ? normalizedBox.bottom
        : expandedSelection.bottom;

    final overlapWidth = (overlapRight - overlapLeft).clamp(0.0, 1.0);
    final overlapHeight = (overlapBottom - overlapTop).clamp(0.0, 1.0);
    final overlapArea = overlapWidth * overlapHeight;
    final boxArea = normalizedBox.width * normalizedBox.height;
    if (boxArea <= 0) {
      return false;
    }
    return (overlapArea / boxArea) >= 0.25;
  }

  Future<OcrImportReviewAction?> showOcrImportPreviewDialog({
    required List<Item> pageItems,
    required int pageNumber,
    required int accumulatedCount,
  }) async {
    if (isDialogShowing) {
      return null;
    }

    isDialogShowing = true;
    final action = await showDialog<OcrImportReviewAction>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('OCR結果 $pageNumber枚目'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pageItems.isEmpty
                      ? 'このページでは6桁コードを抽出できませんでした。'
                      : '${pageItems.length}件を抽出しました。累計 $accumulatedCount 件になります。',
                ),
                const SizedBox(height: 12),
                if (pageItems.isEmpty)
                  const Text('必要なら撮り直すか、このまま次の書類へ進めます。')
                else
                  SizedBox(
                    height: 260,
                    child: ListView.separated(
                      itemCount: pageItems.length.clamp(0, 12),
                      separatorBuilder: (_, _) => const Divider(height: 12),
                      itemBuilder: (context, index) {
                        final item = pageItems[index];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(item.name),
                          subtitle: Text(item.key6),
                        );
                      },
                    ),
                  ),
                if (pageItems.length > 12)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('ほか ${pageItems.length - 12} 件'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, OcrImportReviewAction.cancel),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                OcrImportReviewAction.continueShooting,
              ),
              child: const Text('続けて撮影'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                OcrImportReviewAction.finishImport,
              ),
              child: const Text('この内容で読込'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;
    return action;
  }

  Future<Uint8List?> readPickedFileBytes(PlatformFile file) async {
    if (file.bytes != null) {
      return file.bytes;
    }

    final path = file.path;
    if (path == null || path.isEmpty) {
      return null;
    }

    final pickedFile = File(path);
    if (!await pickedFile.exists()) {
      return null;
    }

    return pickedFile.readAsBytes();
  }

  Future<void> configureRange() async {
    final result = await Navigator.push<RangeConfigResult>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            RangeConfigScreen(initialStart: rangeStart, initialEnd: rangeEnd),
      ),
    );

    if (result == null) {
      return;
    }

    final List<Item> generatedItems = [];
    for (int value = result.start; value <= result.end; value++) {
      generatedItems.add(Item('', normalizeToKey6(value.toString())));
    }

    setState(() {
      mode = CheckMode.range;
      resetSyncForNewSession('連番設定');
      addOperationLog(
        '連番を設定しました: ${formatRangeValue(result.start)}-${formatRangeValue(result.end)}',
      );
      rangeStart = result.start;
      rangeEnd = result.end;
      rangeItems = generatedItems;
      checkHistory.clear();
      lastInput = '';
      lastResult = '連番設定完了: ${generatedItems.length}件';
      duplicateInfo = '';
      highlightedItem = null;
      cleanupItemUiCaches();
    });
    clearInput();
    queueAutoSave();

    if (!mounted) return;
    showCenterMessage(
      '連番 ${formatRangeValue(result.start)}-${formatRangeValue(result.end)} を設定しました',
    );
  }

  Future<void> confirmDuplicateItem(Item item) async {
    if (isDialogShowing) {
      return;
    }
    if (item.needsSelection != true && item.status != '保留') {
      return;
    }

    final statusLabel = item.needsSelection == true ? '候補' : item.status;

    isDialogShowing = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('$statusLabel をOKにする'),
          content: Text('${item.key6} を手動で OK にしますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('OKにする'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      item.status = 'OK';
      item.needsSelection = false;
      item.previousStatus = null;
      lastResult = 'OK';
      duplicateInfo = '';
      recordLocalSyncEvent(
        action: 'set_status',
        key6: item.key6,
        status: 'OK',
        itemName: item.name,
      );
      addOperationLog('${item.key6} を OK にしました');

      if (statusLabel == '候補' || statusLabel == '保留') {
        final relatedItems = currentItems
            .where((e) => e.key6 == item.key6)
            .toList();
        for (final relatedItem in relatedItems) {
          if (identical(relatedItem, item)) {
            relatedItem.previousStatus = null;
            relatedItem.needsSelection = false;
            continue;
          }
          if (relatedItem.needsSelection == true ||
              relatedItem.status == '保留') {
            relatedItem.status = relatedItem.previousStatus ?? '未処理';
          }
          relatedItem.needsSelection = false;
          relatedItem.previousStatus = null;
        }
      } else {
        item.previousStatus = null;
      }
      applyCrossDeviceDuplicateHold(currentItems);
    });
    queueAutoSave();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollToItem(item);
      highlightItem(item);
    });

    showCenterMessage('${item.key6} を OK にしました');
  }

  void switchMode(CheckMode nextMode) {
    if (mode == nextMode) {
      return;
    }

    setState(() {
      mode = nextMode;
      addOperationLog(
        'モードを切り替えました: ${nextMode == CheckMode.csv ? 'CSV照合' : '連番チェック'}',
      );
      checkHistory.clear();
      lastInput = '';
      lastResult = '';
      duplicateInfo = '';
      highlightedItem = null;
    });
    clearInput();
    queueAutoSave();
  }

  void check(String input) {
    final trimmedInput = input.trim();
    final normalized = normalizeToKey6(trimmedInput);
    final strictExactTokenRaw = normalizeIdentifierStrict(trimmedInput);
    final strictExactToken = strictExactTokenRaw;
    final exactToken = normalizeIdentifierForExactMatch(trimmedInput);
    final inputLabel = trimmedInput.isEmpty ? normalized : trimmedInput;
    final targetItems = currentItems;
    Item? targetItemForScroll;

    clearSelectionCandidates();

    setState(() {
      lastInput = inputLabel;
    });

    if (normalized.isEmpty && exactToken.isEmpty) {
      setState(() {
        lastResult = 'NG';
        duplicateInfo = '';
        addOperationLog('空入力のため NG');
      });
      queueAutoSave();
      showCenterMessage('入力値を確認してください');
      return;
    }

    final key6Matches = targetItems
        .where(
          (e) =>
              e.status != 'NG' && normalized.isNotEmpty && e.key6 == normalized,
        )
        .toList();
    final exactMatches = targetItems
        .where(
          (e) =>
              e.status != 'NG' &&
              strictExactToken.isNotEmpty &&
              buildItemStrictMatchTokens(e).contains(strictExactToken),
        )
        .toList();
    final correctedExactMatches = targetItems
        .where(
          (e) =>
              e.status != 'NG' &&
              exactToken.isNotEmpty &&
              exactToken != strictExactToken &&
              buildItemExactMatchTokens(e).contains(exactToken),
        )
        .toList();

    final matches = <Item>[];
    for (final item in [
      ...key6Matches,
      ...exactMatches,
      ...correctedExactMatches,
    ]) {
      if (!matches.contains(item)) {
        matches.add(item);
      }
    }

    String getMatchSourceLabelForItem(Item item) {
      final byKey6 = normalized.isNotEmpty && item.key6 == normalized;
      final byStrictExact =
          strictExactToken.isNotEmpty && exactMatches.contains(item);
      final byCorrectedExact =
          exactToken.isNotEmpty && correctedExactMatches.contains(item);
      if (byKey6 && byStrictExact) {
        return '6桁+完全一致';
      }
      if (byStrictExact) {
        return '完全一致';
      }
      if (byKey6 && byCorrectedExact) {
        return '6桁+補正一致';
      }
      if (byCorrectedExact) {
        return '補正一致';
      }
      return '6桁一致';
    }

    String getMatchSourceLabelForGroup(List<Item> group) {
      if (group.isEmpty) {
        return '';
      }
      final labels = group.map(getMatchSourceLabelForItem).toSet();
      if (labels.length == 1) {
        return labels.first;
      }
      return '混在';
    }

    final matchSourceLabel = getMatchSourceLabelForGroup(matches);
    final duplicateChecksAgo = normalized.isNotEmpty
        ? findPreviousCheckDistance(normalized)
        : null;
    final repeatedSingleMatch =
        matches.length == 1 && duplicateChecksAgo != null;

    if (repeatedSingleMatch) {
      lastInput = inputLabel;
      lastResult =
          '${matches.first.status}（${getMatchSourceLabelForItem(matches.first)}）';
      duplicateInfo = '$duplicateChecksAgo回前のチェックと重複';
      addOperationLog('$inputLabel を再チェックしました');
      queueAutoSave();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        scrollToItem(matches.first);
        highlightItem(matches.first);
        await handleAlreadyOkSelection(matches.first, duplicateChecksAgo);
      });
      return;
    }

    setState(() {
      if (matches.length == 1) {
        matches.first.needsSelection = false;
        matches.first.status = 'OK';
        matches.first.previousStatus = null;
        lastResult = 'OK（${getMatchSourceLabelForItem(matches.first)}）';
        duplicateInfo = '';
        if (normalized.isNotEmpty) {
          checkHistory.add(normalized);
        }
        recordLocalSyncEvent(
          action: 'set_status',
          key6: matches.first.key6,
          status: 'OK',
          itemName: matches.first.name,
        );
        addOperationLog('$inputLabel を OK にしました');
        targetItemForScroll = matches.first;
      } else if (matches.isEmpty) {
        Item? ngItem;
        if (normalized.isNotEmpty) {
          ngItem = Item(
            mode == CheckMode.csv ? '未登録' : '',
            normalized,
            status: 'NG',
          );
          targetItems.add(ngItem);
          recordLocalSyncEvent(
            action: 'add_ng',
            key6: normalized,
            status: 'NG',
            itemName: mode == CheckMode.csv ? '未登録' : '',
          );
        }
        lastResult = 'NG';
        duplicateInfo = '';
        addOperationLog('$inputLabel は NG でした');
        targetItemForScroll = ngItem;
      } else {
        for (final item in matches) {
          item.previousStatus ??= item.status;
          item.needsSelection = true;
          if (item.status != 'OK') {
            item.status = '保留';
            recordLocalSyncEvent(
              action: 'set_status',
              key6: item.key6,
              status: '保留',
              itemName: item.name,
            );
          }
        }
        lastResult = '重複 ${matches.length}件';
        duplicateInfo = '';
        addOperationLog('$inputLabel は重複候補のため保留にしました（$matchSourceLabel）');
        targetItemForScroll = matches.first;
      }
      applyCrossDeviceDuplicateHold(targetItems);
    });
    queueAutoSave();

    if (targetItemForScroll != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollToItem(targetItemForScroll!);
        highlightItem(targetItemForScroll!);
      });
    }

    if (matches.isEmpty) {
      showCenterMessage('NG: $inputLabel');
    } else if (matches.length > 1) {
      showCenterMessage(
        matchSourceLabel.isEmpty ? '保留' : '保留（$matchSourceLabel）',
      );
    } else if (duplicateChecksAgo != null) {
      showCenterMessage('再チェック: $duplicateInfo');
    }
  }

  int? findPreviousCheckDistance(String normalized) {
    for (int i = checkHistory.length - 1; i >= 0; i--) {
      if (checkHistory[i] == normalized) {
        return checkHistory.length - i;
      }
    }
    return null;
  }

  Color getColor(String status) {
    switch (status) {
      case 'OK':
        return Colors.green.shade300;
      case '保留':
        return Colors.yellow.shade300;
      case 'NG':
        return Colors.red.shade300;
      default:
        return Colors.white;
    }
  }

  String get modeLabel {
    switch (mode) {
      case CheckMode.csv:
        return 'CSV照合';
      case CheckMode.range:
        return '連番チェック';
    }
  }

  String get inputModeLabel {
    switch (inputMode) {
      case InputMode.manual:
        return '手入力';
      case InputMode.tap:
        return 'タップチェック';
      case InputMode.voice:
        return '音声入力';
    }
  }

  String get statusFilterLabel {
    switch (statusFilter) {
      case StatusFilter.all:
        return 'すべて';
      case StatusFilter.unchecked:
        return '未処理';
      case StatusFilter.ok:
        return 'OK';
      case StatusFilter.review:
        return '保留';
      case StatusFilter.ng:
        return 'NG';
    }
  }

  String get rangeSummary {
    if (rangeStart == null || rangeEnd == null) {
      return '未設定';
    }
    return '${formatRangeValue(rangeStart!)} - ${formatRangeValue(rangeEnd!)}';
  }

  int get uncheckedCount {
    return currentItems.where((item) => item.status == '未処理').length;
  }

  int get okCount {
    return currentItems.where((item) => item.status == 'OK').length;
  }

  void clearSelectionCandidates() {
    for (final item in currentItems) {
      if (item.needsSelection == true || item.status == '保留') {
        item.status = item.previousStatus ?? item.status;
        item.previousStatus = null;
        item.needsSelection = false;
      }
    }
  }

  void removeLatestCheckFromHistory(String key6) {
    for (int i = checkHistory.length - 1; i >= 0; i--) {
      if (checkHistory[i] == key6) {
        checkHistory.removeAt(i);
        return;
      }
    }
  }

  void handleItemTap(Item item) {
    if (item.status == '保留' || item.needsSelection == true) {
      confirmDuplicateItem(item);
      return;
    }

    if (inputMode == InputMode.tap) {
      if (item.status == 'OK') {
        handleAlreadyOkSelection(item, findPreviousCheckDistance(item.key6));
        return;
      }
      check(item.key6);
    }
  }

  ValueNotifier<double> swipeOffsetNotifierForItem(Item item) {
    return itemSwipeOffsetNotifiers.putIfAbsent(
      item,
      () => ValueNotifier<double>(0),
    );
  }

  void closeSwipeActions({Item? except}) {
    final keysToClose = itemSwipeOffsetNotifiers.keys
        .where((item) => !identical(item, except))
        .toList();
    for (final item in keysToClose) {
      final notifier = itemSwipeOffsetNotifiers[item];
      if (notifier != null && notifier.value != 0) {
        notifier.value = 0;
      }
    }
    if (except == null) {
      activeSwipeItem = null;
    }
  }

  void handleItemHorizontalDragStart(Item item) {
    if (!identical(activeSwipeItem, item)) {
      closeSwipeActions(except: item);
      activeSwipeItem = item;
    }
  }

  void handleItemHorizontalDragUpdate(Item item, DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta.abs() < swipeUpdateThreshold) {
      return;
    }
    final notifier = swipeOffsetNotifierForItem(item);
    final currentOffset = notifier.value;
    final nextOffset = (currentOffset + delta).clamp(
      -swipeActionRevealWidth,
      0.0,
    );
    if ((nextOffset - currentOffset).abs() < swipeUpdateThreshold) {
      return;
    }
    if (!identical(activeSwipeItem, item)) {
      activeSwipeItem = item;
    }
    notifier.value = nextOffset;
  }

  void handleItemHorizontalDragEnd(Item item, DragEndDetails details) {
    final notifier = swipeOffsetNotifierForItem(item);
    final currentOffset = notifier.value;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final shouldOpen =
        velocity < -200 ||
        currentOffset.abs() > (swipeActionRevealWidth * 0.35);
    notifier.value = shouldOpen ? -swipeActionRevealWidth : 0;
    if (!shouldOpen && identical(activeSwipeItem, item)) {
      activeSwipeItem = null;
    }
  }

  void applySwipeAction(Item item, SwipeItemAction action) {
    if (action == SwipeItemAction.delete) {
      setState(() {
        recordLocalSyncEvent(
          action: 'delete_item',
          key6: item.key6,
          status: '削除',
          itemName: item.name,
        );
        currentItems.remove(item);
        itemTileKeys.remove(item);
        final notifier = itemSwipeOffsetNotifiers.remove(item);
        notifier?.dispose();
        if (identical(activeSwipeItem, item)) {
          activeSwipeItem = null;
        }
        if (identical(highlightedItem, item)) {
          highlightedItem = null;
        }
        lastInput = item.key6;
        lastResult = '削除';
        duplicateInfo = '';
        addOperationLog('${item.key6} を削除しました');
      });
      queueAutoSave();
      showCenterMessage('${item.key6} を削除しました');
      return;
    }

    setState(() {
      final relatedItems = currentItems
          .where((e) => e.key6 == item.key6)
          .toList();
      for (final relatedItem in relatedItems) {
        relatedItem.needsSelection = false;
        relatedItem.previousStatus = null;
        if (!identical(relatedItem, item) && relatedItem.status == '保留') {
          relatedItem.status = '未処理';
        }
      }

      item.status = action == SwipeItemAction.ok ? 'OK' : '保留';
      item.needsSelection = false;
      item.previousStatus = null;
      recordLocalSyncEvent(
        action: 'set_status',
        key6: item.key6,
        status: item.status,
        itemName: item.name,
      );
      swipeOffsetNotifierForItem(item).value = 0;
      activeSwipeItem = null;
      lastInput = item.key6;
      lastResult = item.status;
      duplicateInfo = '';
      addOperationLog('${item.key6} を${item.status}にしました（スワイプ）');
      applyCrossDeviceDuplicateHold(currentItems);
    });
    queueAutoSave();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      scrollToItem(item);
      highlightItem(item);
    });

    showCenterMessage(
      action == SwipeItemAction.ok
          ? '${item.key6} をOKにしました'
          : '${item.key6} を保留にしました',
    );
  }

  Widget buildSwipeActionButton({
    required IconData icon,
    required String label,
    required Color backgroundColor,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: swipeActionButtonWidth,
      child: Material(
        color: backgroundColor,
        child: InkWell(
          onTap: onPressed,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> handleAlreadyOkSelection(
    Item item,
    int? duplicateChecksAgo,
  ) async {
    if (isDialogShowing) {
      return;
    }
    isDialogShowing = true;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('再チェックの確認'),
          content: Text(
            '${item.key6} は過去にチェック済みです。'
            '${duplicateChecksAgo != null ? '\n$duplicateChecksAgo回前のチェックと重複しています。' : ''}'
            '\n保留にするか、未チェックに戻すか選んでください。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'pending'),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'unchecked'),
              child: const Text('未チェックに戻す'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;

    if (!mounted || action == null) {
      return;
    }

    setState(() {
      item.needsSelection = false;
      item.previousStatus = null;

      final relatedItems = currentItems
          .where((e) => e.key6 == item.key6)
          .toList();
      for (final relatedItem in relatedItems) {
        relatedItem.needsSelection = false;
        if (!identical(relatedItem, item) && relatedItem.status == '保留') {
          relatedItem.status = relatedItem.previousStatus ?? '未処理';
        }
        if (!identical(relatedItem, item)) {
          relatedItem.previousStatus = null;
        }
      }

      if (action == 'pending') {
        item.status = '保留';
        item.needsSelection = true;
        lastResult = '保留';
        duplicateInfo = '';
        recordLocalSyncEvent(
          action: 'set_status',
          key6: item.key6,
          status: '保留',
          itemName: item.name,
        );
        addOperationLog('${item.key6} を保留にしました');
      } else {
        item.status = '未処理';
        item.needsSelection = false;
        removeLatestCheckFromHistory(item.key6);
        lastResult = '未処理';
        duplicateInfo = '';
        recordLocalSyncEvent(
          action: 'set_status',
          key6: item.key6,
          status: '未処理',
          itemName: item.name,
        );
        addOperationLog('${item.key6} を未処理に戻しました');
      }
      applyCrossDeviceDuplicateHold(currentItems);
    });
    queueAutoSave();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollToItem(item);
      highlightItem(item);
    });

    showCenterMessage(
      action == 'pending'
          ? '${item.key6} を保留にしました'
          : '${item.key6} を未チェックに戻しました',
    );
  }

  void clearInput() {
    inputController.clear();
    liveInput = '';
  }

  List<Item> buildInitialCsvItems() {
    return [
      Item('PC-001', '000001'),
      Item('PC-002', '000002'),
      Item('PC-003', '000003'),
    ];
  }

  Future<void> resetAllState() async {
    if (isDialogShowing) {
      return;
    }
    isDialogShowing = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('全状態をリセット'),
          content: const Text('一覧の状態、履歴、入力内容をすべてリセットしますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('リセット'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      mode = CheckMode.csv;
      inputMode = InputMode.manual;
      csvItems = buildInitialCsvItems();
      rangeItems = [];
      resetSyncForNewSession('全状態リセット');
      addOperationLog('全状態をリセットしました');
      checkHistory.clear();
      lastInput = '';
      lastResult = '';
      duplicateInfo = '';
      rangeStart = null;
      rangeEnd = null;
      highlightedItem = null;
      cleanupItemUiCaches();
    });
    clearInput();
    await saveAutoBackup();

    if (!mounted) {
      return;
    }

    showCenterMessage('全状態をリセットしました');
  }

  Future<void> createBackupFromMenu() async {
    setState(() {
      addOperationLog('手動バックアップを作成しました');
    });
    await saveManualBackup();
    if (!mounted) {
      return;
    }
    showCenterMessage('現在の状態をバックアップしました');
  }

  Future<void> restoreBackupFromMenu() async {
    await restoreManualBackup();
    ensureSyncIdentity();
    if (!mounted) {
      return;
    }
    setState(() {
      addOperationLog('手動バックアップから復元しました');
    });
    await saveAutoBackup();
    if (!mounted) {
      return;
    }
    showCenterMessage('バックアップから復元しました');
  }

  Future<void> clearNgItems() async {
    if (isDialogShowing) {
      return;
    }
    isDialogShowing = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('NG一覧を削除'),
          content: const Text('現在のモードで追加された NG 行を削除しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );
    isDialogShowing = false;

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      currentItems.removeWhere((item) => item.status == 'NG');
      addOperationLog('NG一覧を削除しました');
      duplicateInfo = '';
      highlightedItem = null;
    });
    await saveAutoBackup();

    if (!mounted) {
      return;
    }

    showCenterMessage('NG一覧を削除しました');
  }

  Future<void> showVersionInfoDialog() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('バージョン情報'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('アプリ名: ${info.appName}'),
                Text('バージョン: ${info.version}'),
                Text('ビルド番号: ${info.buildNumber}'),
                Text('パッケージ: ${info.packageName}'),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('閉じる'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      showCenterMessage('バージョン情報の取得に失敗しました: $e');
    }
  }

  Future<void> exportCurrentListAsCsv() async {
    try {
      final rows = <List<String>>[
        ['display_name', 'key6', 'status'],
        ...currentItems.map((item) => [item.name, item.key6, item.status]),
      ];

      final csvBody = const ListToCsvConverter(eol: '\r\n').convert(rows);
      final csv = '\uFEFF$csvBody';
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${directory.path}/asset_check_export_$timestamp.csv');
      await file.writeAsString(csv, encoding: utf8, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'asset_check の一覧をCSV出力しました',
          subject: 'asset_check_export.csv',
        ),
      );

      showCenterMessage('CSVを出力しました');
    } catch (e) {
      showCenterMessage('CSV出力エラー: $e');
    }
  }

  Future<void> exportInitialSession() async {
    try {
      ensureSyncIdentity();
      if (currentItems.isEmpty) {
        showCenterMessage('共有する一覧がありません');
        return;
      }

      final payload = {
        'format': 'asset_check_session_v1',
        'sessionId': syncSessionId,
        'createdAt': buildUtcIsoTimestamp(),
        'mode': mode.name,
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
        'items': currentItems
            .map(
              (item) => {
                'name': item.name,
                'key6': item.key6,
                'status': item.status,
              },
            )
            .toList(),
      };

      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(
        '${directory.path}/asset_check_session_$timestamp.json',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        encoding: utf8,
        flush: true,
      );

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'asset_check の初期セッションを共有します',
          subject: 'asset_check_session.json',
        ),
      );

      setState(() {
        addOperationLog('初期セッションを書き出しました: ${currentItems.length}件');
      });
      queueAutoSave();
      showCenterMessage('初期セッションを出力しました');
    } catch (e) {
      showCenterMessage('初期セッション出力エラー: $e');
    }
  }

  Future<void> importInitialSession() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      ensureSyncIdentity();
      final picked = result.files.first;
      final bytes = await readPickedFileBytes(picked);
      if (bytes == null || bytes.isEmpty) {
        showCenterMessage('ファイルを読み込めませんでした');
        return;
      }

      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        showCenterMessage('セッション形式が不正です');
        return;
      }
      await applyInitialSessionPayload(decoded, sourceLabel: 'ファイル');
    } catch (e) {
      showCenterMessage('初期セッション取込エラー: $e');
    }
  }

  Future<void> applyInitialSessionPayload(
    Map<String, dynamic> decoded, {
    required String sourceLabel,
  }) async {
    final format = decoded['format'] as String? ?? '';
    if (format != 'asset_check_session_v1') {
      showCenterMessage('対応していないセッション形式です');
      return;
    }

    final sessionId = (decoded['sessionId'] as String? ?? '').trim();
    if (sessionId.isEmpty) {
      showCenterMessage('sessionId がありません');
      return;
    }

    final modeName = decoded['mode'] as String? ?? CheckMode.csv.name;
    final importedMode = CheckMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => CheckMode.csv,
    );

    final rawItems = decoded['items'] as List<dynamic>? ?? const [];
    final importedItems = <Item>[];
    for (final raw in rawItems) {
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      final key6 = normalizeToKey6(raw['key6']?.toString() ?? '');
      if (key6.isEmpty) {
        continue;
      }
      final name = raw['name']?.toString() ?? '';
      final status = raw['status']?.toString() ?? '未処理';
      importedItems.add(
        Item(
          name,
          key6,
          status: status,
          previousStatus: null,
          needsSelection: false,
        ),
      );
    }

    if (importedItems.isEmpty) {
      showCenterMessage('有効な一覧データがありません');
      return;
    }

    final importedRangeStart = decoded['rangeStart'] as int?;
    final importedRangeEnd = decoded['rangeEnd'] as int?;

    setState(() {
      mode = importedMode;
      if (importedMode == CheckMode.csv) {
        csvItems = importedItems;
        rangeItems = [];
        rangeStart = null;
        rangeEnd = null;
      } else {
        rangeItems = importedItems;
        csvItems = [];
        rangeStart = importedRangeStart;
        rangeEnd = importedRangeEnd;
      }
      syncSessionId = sessionId;
      nextSyncEventSeq = 1;
      lastExportedSyncSeq = 0;
      syncEvents = [];
      checkHistory.clear();
      lastInput = '';
      lastResult = '初期セッション取込: ${importedItems.length}件';
      duplicateInfo = '';
      highlightedItem = null;
      cleanupItemUiCaches();
      addOperationLog(
        '初期セッションを取り込みました($sourceLabel): ${importedItems.length}件 / ${importedMode == CheckMode.csv ? 'CSV照合' : '連番チェック'}',
      );
    });
    clearInput();
    queueAutoSave();
    showCenterMessage('初期セッションを取り込みました');
  }

  Future<void> importSyncDiff() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      ensureSyncIdentity();

      final existingEventIds = syncEvents.map((event) => event.eventId).toSet();
      final incoming = <SyncEvent>[];
      var skippedSession = 0;
      var skippedDuplicate = 0;
      var skippedToken = 0;
      var parseErrors = 0;
      final incomingIds = <String>{};

      for (final file in result.files) {
        try {
          final bytes = await readPickedFileBytes(file);
          if (bytes == null || bytes.isEmpty) {
            continue;
          }
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is! Map<String, dynamic>) {
            parseErrors += 1;
            continue;
          }
          Map<String, dynamic> diffPayload = decoded;
          final format = decoded['format'] as String? ?? '';
          if (format == 'asset_check_diff_relay_v1') {
            final relaySessionId = decoded['sessionId'] as String? ?? '';
            if (relaySessionId.isEmpty || relaySessionId != syncSessionId) {
              skippedSession += 1;
              continue;
            }
            final relayToken = decoded['receiverToken'] as String? ?? '';
            if (syncReceiverToken.isNotEmpty &&
                relayToken.isNotEmpty &&
                relayToken != syncReceiverToken) {
              skippedToken += 1;
              continue;
            }
            final payload = decoded['payload'];
            if (payload is! Map<String, dynamic>) {
              parseErrors += 1;
              continue;
            }
            diffPayload = payload;
          }

          final parsed = parseIncomingSyncEventsFromPayload(
            diffPayload,
            existingEventIds: existingEventIds,
            incomingEventIds: incomingIds,
          );
          skippedSession += parsed.skippedSession;
          skippedDuplicate += parsed.skippedDuplicate;
          incoming.addAll(parsed.incoming);
        } catch (_) {
          parseErrors += 1;
        }
      }

      if (incoming.isEmpty) {
        final messages = <String>[];
        if (skippedDuplicate > 0) {
          messages.add('重複 $skippedDuplicate');
        }
        if (skippedSession > 0) {
          messages.add('別セッション $skippedSession');
        }
        if (skippedToken > 0) {
          messages.add('受信コード不一致 $skippedToken');
        }
        if (parseErrors > 0) {
          messages.add('読込失敗 $parseErrors');
        }
        final detail = messages.isEmpty ? '' : '（${messages.join(' / ')}）';
        showCenterMessage('取り込める差分がありません$detail');
        return;
      }

      incoming.sort(compareSyncEvents);

      setState(() {
        for (final event in incoming) {
          syncEvents.add(event);
          applyEventToItems(event, currentItems);
        }
        final duplicatePendingCount = applyCrossDeviceDuplicateHold(
          currentItems,
        );
        cleanupItemUiCaches();
        addOperationLog(
          '差分を取り込みました: ${incoming.length}件'
          '${duplicatePendingCount > 0 ? ' / 端末間重複を保留化: $duplicatePendingCount件' : ''}',
        );
        if (incoming.isNotEmpty) {
          lastResult = '差分取込: ${incoming.length}件';
          duplicateInfo = '';
        }
      });
      queueAutoSave();

      showCenterMessage(
        '差分 ${incoming.length}件を統合しました'
        '${skippedDuplicate > 0 ? '（重複除外 $skippedDuplicate 件）' : ''}',
      );
    } catch (e) {
      showCenterMessage('差分取込エラー: $e');
    }
  }

  String encodeCompressedJsonPayload(Map<String, dynamic> payload) {
    final raw = utf8.encode(jsonEncode(payload));
    final compressed = gzip.encode(raw);
    return base64UrlEncode(compressed);
  }

  Map<String, dynamic>? decodeCompressedJsonPayload(String encoded) {
    try {
      final compressed = base64Url.decode(encoded);
      final raw = gzip.decode(compressed);
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  bool canEncodeQrData(String data) {
    final validation = QrValidator.validate(
      data: data,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    );
    return validation.status == QrValidationStatus.valid;
  }

  List<String> buildChunkedQrFrames({
    required String packetType,
    required Map<String, dynamic> payload,
  }) {
    ensureSyncIdentity();
    final encodedPayload = encodeCompressedJsonPayload(payload);
    final seed = DateTime.now().millisecondsSinceEpoch;
    final nonce = Random().nextInt(1 << 20);

    for (
      var chunkSize = qrChunkSizeDefault;
      chunkSize >= qrChunkSizeMinimum;
      chunkSize -= qrChunkSizeStep
    ) {
      final total = (encodedPayload.length / chunkSize).ceil();
      if (total <= 0) {
        continue;
      }

      final transferId = '$syncSessionId-$seed-$nonce-$chunkSize';
      final frames = <String>[];
      var valid = true;
      for (var i = 0; i < total; i++) {
        final start = i * chunkSize;
        final end = min(start + chunkSize, encodedPayload.length);
        final chunk = encodedPayload.substring(start, end);
        final frame = jsonEncode({
          'protocol': syncProtocolName,
          'type': chunkPacketType,
          'packetType': packetType,
          'transferId': transferId,
          'sessionId': syncSessionId,
          'index': i + 1,
          'total': total,
          'payloadChunk': chunk,
        });
        if (!canEncodeQrData(frame)) {
          valid = false;
          break;
        }
        frames.add(frame);
      }
      if (valid) {
        return frames;
      }
    }
    return [];
  }

  Widget buildValidatedQr({
    required String data,
    required double size,
    required String overflowMessage,
  }) {
    final validation = QrValidator.validate(
      data: data,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    );
    if (validation.status != QrValidationStatus.valid) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(overflowMessage, textAlign: TextAlign.center),
      );
    }
    return QrImageView.withQr(
      qr: validation.qrCode!,
      size: size,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
    );
  }

  Future<void> showChunkedQrDialog({
    required String title,
    required List<String> frames,
    required String subtitle,
  }) async {
    if (frames.isEmpty) {
      showCenterMessage('QRの生成に失敗しました');
      return;
    }

    var index = 0;
    var autoPlay = true;
    Timer? timer;
    var timerStarted = false;

    void restartTimer(StateSetter setState) {
      timer?.cancel();
      if (!autoPlay || frames.length <= 1) {
        return;
      }
      timer = Timer.periodic(const Duration(milliseconds: 850), (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          index = (index + 1) % frames.length;
        });
      });
    }

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (statefulContext, setState) {
              if (!timerStarted) {
                timerStarted = true;
                restartTimer(setState);
              }
              return AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 340,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      buildValidatedQr(
                        data: frames[index],
                        size: 250,
                        overflowMessage: 'QR生成に失敗しました',
                      ),
                      const SizedBox(height: 10),
                      Text('QR ${index + 1}/${frames.length}'),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        index = (index - 1 + frames.length) % frames.length;
                      });
                    },
                    child: const Text('前へ'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        autoPlay = !autoPlay;
                        restartTimer(setState);
                      });
                    },
                    child: Text(autoPlay ? '自動:ON' : '自動:OFF'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        index = (index + 1) % frames.length;
                      });
                    },
                    child: const Text('次へ'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('閉じる'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      timer?.cancel();
    }
  }

  Future<Map<String, dynamic>?> scanChunkedPayload({
    required String packetType,
    required String invalidMessage,
    required String decodeErrorMessage,
  }) async {
    final scanned = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            QrScanScreen(chunkMode: true, expectedPacketType: packetType),
      ),
    );
    if (scanned == null) {
      return null;
    }
    if (scanned['packetType'] != packetType) {
      showCenterMessage(invalidMessage);
      return null;
    }
    final encoded = scanned['payload'] as String? ?? '';
    if (encoded.isEmpty) {
      showCenterMessage(invalidMessage);
      return null;
    }
    final payload = decodeCompressedJsonPayload(encoded);
    if (payload == null) {
      showCenterMessage(decodeErrorMessage);
      return null;
    }
    return payload;
  }

  Future<void> showInitialSessionQr() async {
    try {
      ensureSyncIdentity();
      if (currentItems.isEmpty) {
        showCenterMessage('共有する一覧がありません');
        return;
      }

      final payload = {
        'format': 'asset_check_session_v1',
        'sessionId': syncSessionId,
        'createdAt': buildUtcIsoTimestamp(),
        'mode': mode.name,
        'rangeStart': rangeStart,
        'rangeEnd': rangeEnd,
        'items': currentItems
            .map(
              (item) => {
                'name': item.name,
                'key6': item.key6,
                'status': item.status,
              },
            )
            .toList(),
      };
      final frames = buildChunkedQrFrames(
        packetType: initialSessionPacketType,
        payload: payload,
      );
      if (frames.isEmpty) {
        showCenterMessage('初期セッションQRの生成に失敗しました');
        return;
      }

      await showChunkedQrDialog(
        title: '初期セッション連続QR',
        frames: frames,
        subtitle: '件数 ${currentItems.length} / session $syncSessionId',
      );

      setState(() {
        addOperationLog(
          '初期セッション連続QRを表示しました: ${currentItems.length}件 / ${frames.length}枚',
        );
      });
      queueAutoSave();
    } catch (e) {
      showCenterMessage('初期セッションQR表示エラー: $e');
    }
  }

  Future<void> scanInitialSessionQrAndImport() async {
    try {
      final payload = await scanChunkedPayload(
        packetType: initialSessionPacketType,
        invalidMessage: '初期セッションQR形式が不正です',
        decodeErrorMessage: '初期セッションQRの復号に失敗しました',
      );
      if (payload == null) {
        return;
      }
      if (payload['format'] != 'asset_check_session_v1') {
        showCenterMessage('初期セッションQR形式が不正です');
        return;
      }
      await applyInitialSessionPayload(payload, sourceLabel: 'QR');
    } catch (e) {
      showCenterMessage('初期セッションQR取込エラー: $e');
    }
  }

  Future<void> showDiffQr() async {
    try {
      final payload = buildSyncDiffPayload(unexportedOnly: true);
      if (payload == null) {
        showCenterMessage('未送信の差分はありません');
        return;
      }

      final frames = buildChunkedQrFrames(
        packetType: diffPacketType,
        payload: payload,
      );
      if (frames.isEmpty) {
        showCenterMessage('差分連続QRの生成に失敗しました');
        return;
      }

      final events = (payload['events'] as List<dynamic>? ?? const []);
      await showChunkedQrDialog(
        title: '差分連続QR',
        frames: frames,
        subtitle: '差分 ${events.length}件 / session $syncSessionId',
      );

      if (events.isNotEmpty) {
        final lastSeq =
            (events.last as Map<String, dynamic>)['seq'] as int? ?? 0;
        setState(() {
          if (lastSeq > lastExportedSyncSeq) {
            lastExportedSyncSeq = lastSeq;
          }
          addOperationLog(
            '差分連続QRを表示しました: ${events.length}件 / ${frames.length}枚',
          );
        });
        queueAutoSave();
      }
      showCenterMessage('差分連続QRを表示しました');
    } catch (e) {
      showCenterMessage('差分QR表示エラー: $e');
    }
  }

  Future<void> scanDiffQrAndImport() async {
    try {
      ensureSyncIdentity();
      final payload = await scanChunkedPayload(
        packetType: diffPacketType,
        invalidMessage: '差分QR形式が不正です',
        decodeErrorMessage: '差分QRの復号に失敗しました',
      );
      if (payload == null) {
        return;
      }
      if (payload['format'] != 'asset_check_diff_v1') {
        showCenterMessage('差分QR形式が不正です');
        return;
      }

      final parsed = parseIncomingSyncEventsFromPayload(
        payload,
        existingEventIds: syncEvents.map((event) => event.eventId).toSet(),
        incomingEventIds: <String>{},
      );
      final incoming = parsed.incoming;
      if (incoming.isEmpty) {
        final details = <String>[];
        if (parsed.skippedDuplicate > 0) {
          details.add('重複 ${parsed.skippedDuplicate}');
        }
        if (parsed.skippedSession > 0) {
          details.add('別セッション ${parsed.skippedSession}');
        }
        final suffix = details.isEmpty ? '' : '（${details.join(' / ')}）';
        showCenterMessage('取り込める差分がありません$suffix');
        return;
      }

      incoming.sort(compareSyncEvents);
      setState(() {
        for (final event in incoming) {
          syncEvents.add(event);
          applyEventToItems(event, currentItems);
        }
        final duplicatePendingCount = applyCrossDeviceDuplicateHold(
          currentItems,
        );
        cleanupItemUiCaches();
        addOperationLog(
          '差分QRを取り込みました: ${incoming.length}件'
          '${duplicatePendingCount > 0 ? ' / 端末間重複を保留化: $duplicatePendingCount件' : ''}',
        );
        lastResult = '差分取込: ${incoming.length}件';
        duplicateInfo = '';
      });
      queueAutoSave();

      showCenterMessage(
        '差分 ${incoming.length}件を統合しました'
        '${parsed.skippedDuplicate > 0 ? '（重複除外 ${parsed.skippedDuplicate} 件）' : ''}',
      );
    } catch (e) {
      showCenterMessage('差分QR取込エラー: $e');
    }
  }

  Map<String, dynamic>? buildSyncDiffPayload({required bool unexportedOnly}) {
    ensureSyncIdentity();
    final eventsToExport =
        syncEvents
            .where(
              (event) =>
                  event.sessionId == syncSessionId &&
                  event.deviceId == deviceId &&
                  (!unexportedOnly || event.seq > lastExportedSyncSeq),
            )
            .toList()
          ..sort(compareSyncEvents);
    if (eventsToExport.isEmpty) {
      return null;
    }

    return {
      'format': 'asset_check_diff_v1',
      'sessionId': syncSessionId,
      'deviceId': deviceId,
      'deviceLabel': deviceLabel,
      'createdAt': buildUtcIsoTimestamp(),
      'events': eventsToExport.map((event) => event.toJson()).toList(),
    };
  }

  SyncIncomingParseResult parseIncomingSyncEventsFromPayload(
    Map<String, dynamic> decoded, {
    required Set<String> existingEventIds,
    required Set<String> incomingEventIds,
  }) {
    var skippedSession = 0;
    var skippedDuplicate = 0;
    final incoming = <SyncEvent>[];

    final fileSessionId = decoded['sessionId'] as String? ?? '';
    if (fileSessionId.isEmpty || fileSessionId != syncSessionId) {
      return const SyncIncomingParseResult(
        incoming: [],
        skippedSession: 1,
        skippedDuplicate: 0,
      );
    }

    final rawEvents = decoded['events'] as List<dynamic>? ?? const [];
    for (final rawEvent in rawEvents) {
      if (rawEvent is! Map<String, dynamic>) {
        continue;
      }
      final event = SyncEvent.fromJson(rawEvent);
      if (event.eventId.isEmpty || event.key6.isEmpty) {
        continue;
      }
      if (event.sessionId.isEmpty || event.sessionId != syncSessionId) {
        skippedSession += 1;
        continue;
      }
      if (existingEventIds.contains(event.eventId) ||
          incomingEventIds.contains(event.eventId)) {
        skippedDuplicate += 1;
        continue;
      }
      incomingEventIds.add(event.eventId);
      incoming.add(event);
    }

    return SyncIncomingParseResult(
      incoming: incoming,
      skippedSession: skippedSession,
      skippedDuplicate: skippedDuplicate,
    );
  }

  SyncMergeResult mergeIncomingSyncEvents({
    required List<SyncEvent> incoming,
    required String logPrefix,
  }) {
    if (incoming.isEmpty) {
      return const SyncMergeResult(imported: 0, duplicatePendingCount: 0);
    }

    incoming.sort(compareSyncEvents);
    var duplicatePendingCount = 0;
    setState(() {
      for (final event in incoming) {
        syncEvents.add(event);
        applyEventToItems(event, currentItems);
      }
      duplicatePendingCount = applyCrossDeviceDuplicateHold(currentItems);
      cleanupItemUiCaches();
      addOperationLog(
        '$logPrefix: ${incoming.length}件'
        '${duplicatePendingCount > 0 ? ' / 端末間重複を保留化: $duplicatePendingCount件' : ''}',
      );
      lastResult = '$logPrefix: ${incoming.length}件';
      duplicateInfo = '';
    });
    queueAutoSave();

    return SyncMergeResult(
      imported: incoming.length,
      duplicatePendingCount: duplicatePendingCount,
    );
  }

  String buildSyncReceiverToken() {
    final random = Random.secure();
    return (100000 + random.nextInt(900000)).toString();
  }

  Future<void> toggleVoiceInput() async {
    if (!speechEnabled) {
      await initSpeech();
    }

    if (!speechEnabled) {
      if (!mounted) {
        return;
      }
      showCenterMessage('音声入力を開始できませんでした');
      return;
    }

    if (speechToText.isListening) {
      await speechToText.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        isListening = false;
      });
      if (inputPreview.isNotEmpty) {
        submitCurrentInput();
      }
      return;
    }

    clearInput();
    await speechToText.listen(
      onResult: handleSpeechResult,
      localeId: 'ja_JP',
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 4),
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.search,
        partialResults: true,
        cancelOnError: true,
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      isListening = true;
    });
  }

  void handleSpeechResult(SpeechRecognitionResult result) {
    if (!mounted) {
      return;
    }

    final normalizedSpeech = normalizeSpeechInput(result.recognizedWords);

    setState(() {
      liveInput = normalizedSpeech;
      inputController.text = normalizedSpeech;
      inputController.selection = TextSelection.collapsed(
        offset: inputController.text.length,
      );
    });
  }

  void submitCurrentInput() {
    if (currentItems.isEmpty) {
      final message = mode == CheckMode.csv
          ? '先に CSV またはカメラOCRで一覧を読み込んでください'
          : '先に連番範囲を設定してください';
      showCenterMessage(message);
      return;
    }

    final rawInput = inputController.text;
    check(rawInput);
    setState(() {
      clearInput();
    });
    inputFocusNode.requestFocus();
  }

  void highlightItem(Item target) {
    setState(() {
      highlightedItem = target;
    });

    Future.delayed(highlightDuration, () {
      if (!mounted || highlightedItem != target) {
        return;
      }
      setState(() {
        highlightedItem = null;
      });
    });
  }

  void scrollToItem(Item target) {
    if (!mounted) {
      return;
    }

    final targetKey = itemTileKeys[target];
    final targetContext = targetKey?.currentContext;
    if (targetContext != null) {
      try {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
      } catch (_) {}
      return;
    }

    if (!listScrollController.hasClients) {
      return;
    }

    final visibleItems = filteredItems;
    final targetIndex = visibleItems.indexOf(target);
    if (targetIndex < 0) {
      return;
    }

    double estimatedOffset = 0;
    for (var i = 0; i < targetIndex; i++) {
      final item = visibleItems[i];
      final hasSelectionHint =
          item.status == '保留' || item.needsSelection == true;
      estimatedOffset += hasSelectionHint
          ? listItemExpandedMinHeight
          : listItemBaseMinHeight;
    }

    final position = listScrollController.position;
    final clampedOffset = estimatedOffset.clamp(0.0, position.maxScrollExtent);

    listScrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = filteredItems;

    return Scaffold(
      appBar: AppBar(
        title: Text(modeLabel),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<InputMode>(
                value: inputMode,
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    inputMode = value;
                  });
                  if (value != InputMode.voice && speechToText.isListening) {
                    speechToText.stop();
                    setState(() {
                      isListening = false;
                    });
                  }
                  if (value != InputMode.manual) {
                    clearInput();
                  }
                },
                items: const [
                  DropdownMenuItem(value: InputMode.manual, child: Text('手入力')),
                  DropdownMenuItem(value: InputMode.tap, child: Text('タップ')),
                  DropdownMenuItem(value: InputMode.voice, child: Text('音声')),
                ],
              ),
            ),
          ),
          if (mode == CheckMode.csv)
            IconButton(
              onPressed: loadCsv,
              icon: const Icon(Icons.upload_file),
              tooltip: 'CSV読込',
            ),
          if (mode == CheckMode.csv)
            IconButton(
              onPressed: importListFromCamera,
              icon: const Icon(Icons.camera_alt_outlined),
              tooltip: 'カメラOCR読込',
            ),
          if (mode == CheckMode.range)
            IconButton(
              onPressed: configureRange,
              icon: const Icon(Icons.format_list_numbered),
              tooltip: '連番設定',
            ),
          PopupMenuButton<SyncMenuAction>(
            tooltip: '同期メニュー',
            icon: const Icon(Icons.sync_alt),
            onSelected: (action) async {
              switch (action) {
                case SyncMenuAction.showInitialSessionQr:
                  await showInitialSessionQr();
                  return;
                case SyncMenuAction.scanInitialSessionQrAndImport:
                  await scanInitialSessionQrAndImport();
                  return;
                case SyncMenuAction.showDiffQr:
                  await showDiffQr();
                  return;
                case SyncMenuAction.scanDiffQrAndImport:
                  await scanDiffQrAndImport();
                  return;
                case SyncMenuAction.exportSession:
                  await exportInitialSession();
                  return;
                case SyncMenuAction.importSession:
                  await importInitialSession();
                  return;
                case SyncMenuAction.importDiff:
                  await importSyncDiff();
                  return;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: SyncMenuAction.showInitialSessionQr,
                child: Text('初期リスト連続QRを表示（送信側）'),
              ),
              PopupMenuItem(
                value: SyncMenuAction.scanInitialSessionQrAndImport,
                child: Text('初期リスト連続QRを読取して取込（受信側）'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: SyncMenuAction.showDiffQr,
                child: Text('差分連続QRを表示（送信側）'),
              ),
              PopupMenuItem(
                value: SyncMenuAction.scanDiffQrAndImport,
                child: Text('差分連続QRを読取して取込（受信側）'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: SyncMenuAction.exportSession,
                child: Text('初期セッションを書き出し'),
              ),
              PopupMenuItem(
                value: SyncMenuAction.importSession,
                child: Text('初期セッションを取り込む'),
              ),
              PopupMenuItem(
                value: SyncMenuAction.importDiff,
                child: Text('差分を取り込む'),
              ),
            ],
          ),
          PopupMenuButton<AppMenuAction>(
            onSelected: (action) async {
              switch (action) {
                case AppMenuAction.viewLog:
                  await showOperationLogDialog();
                  return;
                case AppMenuAction.manageExtractionRules:
                  await showExtractionRuleSettingsDialog();
                  return;
                case AppMenuAction.toggleKeepAwake:
                  await toggleKeepAwake();
                  return;
                case AppMenuAction.exportCsv:
                  await exportCurrentListAsCsv();
                  return;
                case AppMenuAction.createBackup:
                  await createBackupFromMenu();
                  return;
                case AppMenuAction.restoreBackup:
                  await restoreBackupFromMenu();
                  return;
                case AppMenuAction.clearNgItems:
                  await clearNgItems();
                  return;
                case AppMenuAction.resetAll:
                  await resetAllState();
                  return;
                case AppMenuAction.versionInfo:
                  await showVersionInfoDialog();
                  return;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: AppMenuAction.viewLog,
                child: Text('操作ログ'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.manageExtractionRules,
                child: Text('抽出ルール設定'),
              ),
              PopupMenuItem(
                value: AppMenuAction.toggleKeepAwake,
                child: Text(keepAwakeEnabled ? 'スリープ防止をOFF' : 'スリープ防止をON'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.exportCsv,
                child: Text('状態をCSV出力'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.createBackup,
                child: Text('バックアップを作成'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.restoreBackup,
                child: Text('バックアップから復元'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.clearNgItems,
                child: Text('NG一覧を削除'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.resetAll,
                child: Text('全状態をリセット'),
              ),
              const PopupMenuItem(
                value: AppMenuAction.versionInfo,
                child: Text('バージョン情報'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<CheckMode>(
              segments: const [
                ButtonSegment(value: CheckMode.csv, label: Text('CSV照合')),
                ButtonSegment(value: CheckMode.range, label: Text('連番チェック')),
              ],
              selected: {mode},
              onSelectionChanged: (selection) {
                switchMode(selection.first);
              },
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.grey.shade200,
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '直前入力: ${lastInput.isEmpty ? '---' : lastInput}',
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '判定結果: ${lastResult.isEmpty ? '---' : lastResult}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(
                      child: Text('総件数', textAlign: TextAlign.center),
                    ),
                    const Expanded(
                      child: Text('未処理', textAlign: TextAlign.center),
                    ),
                    const Expanded(
                      child: Text('OK', textAlign: TextAlign.center),
                    ),
                    const Expanded(
                      child: Text('フィルタ', textAlign: TextAlign.left),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${currentItems.length}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '$uncheckedCount',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Expanded(
                      child: Text('$okCount', textAlign: TextAlign.center),
                    ),
                    Expanded(
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<StatusFilter>(
                          value: statusFilter,
                          isDense: true,
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              statusFilter = value;
                            });
                          },
                          items: const [
                            DropdownMenuItem(
                              value: StatusFilter.all,
                              child: Text('すべて'),
                            ),
                            DropdownMenuItem(
                              value: StatusFilter.unchecked,
                              child: Text('未処理'),
                            ),
                            DropdownMenuItem(
                              value: StatusFilter.ok,
                              child: Text('OK'),
                            ),
                            DropdownMenuItem(
                              value: StatusFilter.review,
                              child: Text('保留'),
                            ),
                            DropdownMenuItem(
                              value: StatusFilter.ng,
                              child: Text('NG'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      mode == CheckMode.csv
                          ? 'CSV またはカメラOCRで一覧を読み込んでください'
                          : '連番範囲を設定してください',
                    ),
                  )
                : ListView.builder(
                    controller: listScrollController,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final tileKey = itemTileKeys.putIfAbsent(
                        item,
                        () => GlobalKey(),
                      );
                      final isHighlighted = identical(item, highlightedItem);
                      final isSelectionCandidate = item.needsSelection == true;
                      final isDuplicateOkCandidate =
                          isSelectionCandidate && item.status == 'OK';
                      final hasSelectionHint =
                          item.status == '保留' || item.needsSelection == true;
                      final baseColor = getColor(item.status);
                      final flashColor = Color.alphaBlend(
                        Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.22),
                        baseColor,
                      );
                      final borderColor = isDuplicateOkCandidate
                          ? Colors.deepOrange.shade700
                          : (isHighlighted || isSelectionCandidate
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent);
                      final borderWidth = isDuplicateOkCandidate ? 4.0 : 3.0;
                      final swipeOffsetNotifier = swipeOffsetNotifierForItem(
                        item,
                      );
                      return ClipRect(
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(
                                  width: swipeActionRevealWidth,
                                  child: Row(
                                    children: [
                                      buildSwipeActionButton(
                                        icon: Icons.check,
                                        label: 'OK',
                                        backgroundColor: Colors.green.shade600,
                                        onPressed: () => applySwipeAction(
                                          item,
                                          SwipeItemAction.ok,
                                        ),
                                      ),
                                      buildSwipeActionButton(
                                        icon: Icons.pause,
                                        label: '保留',
                                        backgroundColor: Colors.orange.shade700,
                                        onPressed: () => applySwipeAction(
                                          item,
                                          SwipeItemAction.pending,
                                        ),
                                      ),
                                      buildSwipeActionButton(
                                        icon: Icons.delete_outline,
                                        label: '削除',
                                        backgroundColor: Colors.red.shade700,
                                        onPressed: () => applySwipeAction(
                                          item,
                                          SwipeItemAction.delete,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            ValueListenableBuilder<double>(
                              valueListenable: swipeOffsetNotifier,
                              builder: (context, swipeOffset, child) {
                                return Transform.translate(
                                  offset: Offset(swipeOffset, 0),
                                  child: child,
                                );
                              },
                              child: Container(
                                key: tileKey,
                                color: isHighlighted ? flashColor : baseColor,
                                child: Material(
                                  color: Colors.transparent,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragStart: (_) =>
                                        handleItemHorizontalDragStart(item),
                                    onHorizontalDragUpdate: (details) =>
                                        handleItemHorizontalDragUpdate(
                                          item,
                                          details,
                                        ),
                                    onHorizontalDragEnd: (details) =>
                                        handleItemHorizontalDragEnd(
                                          item,
                                          details,
                                        ),
                                    child: InkWell(
                                      onTap: () {
                                        if (swipeOffsetNotifier.value != 0) {
                                          closeSwipeActions();
                                          return;
                                        }
                                        handleItemTap(item);
                                      },
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: borderColor,
                                            width: borderWidth,
                                          ),
                                        ),
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            minHeight: hasSelectionHint
                                                ? listItemExpandedMinHeight
                                                : listItemBaseMinHeight,
                                          ),
                                          child: ListTile(
                                            title: Text(
                                              mode == CheckMode.range
                                                  ? item.key6
                                                  : item.name,
                                            ),
                                            subtitle: mode == CheckMode.range
                                                ? (hasSelectionHint
                                                      ? Text(
                                                          item.needsSelection ==
                                                                  true
                                                              ? '候補: タップでOK確定'
                                                              : 'タップでOKに変更',
                                                        )
                                                      : null)
                                                : Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(item.key6),
                                                      if (hasSelectionHint)
                                                        Text(
                                                          item.needsSelection ==
                                                                  true
                                                              ? '候補: タップでOK確定'
                                                              : 'タップでOKに変更',
                                                        ),
                                                    ],
                                                  ),
                                            trailing: Text(item.status),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (inputMode == InputMode.manual) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: inputController,
                            focusNode: inputFocusNode,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: false,
                              signed: false,
                            ),
                            textInputAction: TextInputAction.done,
                            enableSuggestions: false,
                            autocorrect: false,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(12),
                            ],
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                liveInput = value;
                              });
                            },
                            onSubmitted: (_) {
                              submitCurrentInput();
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: submitCurrentInput,
                            child: const Text('決定'),
                          ),
                        ),
                      ],
                    ),
                  ] else if (inputMode == InputMode.voice) ...[
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (inputPreview.isNotEmpty) ...[
                          Text(
                            inputPreview,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Center(
                          child: SizedBox(
                            width: 92,
                            height: 92,
                            child: FilledButton(
                              onPressed: toggleVoiceInput,
                              style: FilledButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: EdgeInsets.zero,
                              ),
                              child: Icon(
                                isListening ? Icons.mic_off : Icons.mic,
                                size: 42,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else
                    Text(
                      '一覧をタップしてチェック',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
