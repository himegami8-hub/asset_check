import 'package:flutter/material.dart';

class ExtractionRuleSettingsDialog extends StatefulWidget {
  final List<String> initialPatterns;
  final String Function(String) normalizeText;

  const ExtractionRuleSettingsDialog({
    super.key,
    required this.initialPatterns,
    required this.normalizeText,
  });

  @override
  State<ExtractionRuleSettingsDialog> createState() =>
      _ExtractionRuleSettingsDialogState();
}

class _ExtractionRuleSettingsDialogState
    extends State<ExtractionRuleSettingsDialog> {
  late final TextEditingController patternController;
  late final TextEditingController testController;
  String preview = '';
  String validationError = '';
  String autoPatternHint = '';

  @override
  void initState() {
    super.initState();
    patternController = TextEditingController(
      text: widget.initialPatterns.join('\n'),
    );
    testController = TextEditingController();
    _refreshPreview();
  }

  @override
  void dispose() {
    patternController.dispose();
    testController.dispose();
    super.dispose();
  }

  List<String> _parsePatterns(String raw) {
    return raw
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  void _refreshPreview() {
    setState(() {
      preview = _buildPreview(
        _parsePatterns(patternController.text),
        testController.text,
      );
      validationError = '';
    });
  }

  String _escapeRegexLiteral(String input) {
    return input.replaceAllMapped(
      RegExp(r'[\\^$.|?*+(){}\[\]]'),
      (match) => '\\${match.group(0)}',
    );
  }

  String? _generatePatternFromTestInput(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) {
      return null;
    }

    final normalized = widget.normalizeText(input);

    final prefixed = RegExp(
      r'([A-Za-zＡ-Ｚａ-ｚ]{1,6})[\s\-_:/]*([0-9]{6,})',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (prefixed != null) {
      final rawPrefix = prefixed.group(1) ?? '';
      final digits = prefixed.group(2) ?? '';
      if (rawPrefix.isNotEmpty && digits.length >= 6) {
        final prefix = _escapeRegexLiteral(rawPrefix);
        return '$prefix[\\s\\-_:]*(\\d{${digits.length}})';
      }
    }

    final digitsOnly = RegExp(r'([0-9]{6,})').firstMatch(normalized);
    if (digitsOnly != null) {
      final digits = digitsOnly.group(1) ?? '';
      if (digits.length >= 6) {
        return '(\\d{${digits.length}})';
      }
    }
    return null;
  }

  void _applyAutoPattern() {
    final generated = _generatePatternFromTestInput(testController.text);
    if (generated == null) {
      setState(() {
        autoPatternHint =
            '自動生成できませんでした（6桁以上の数字を含む文字列を入力してください）';
      });
      return;
    }

    final existing = _parsePatterns(patternController.text);
    if (!existing.contains(generated)) {
      existing.add(generated);
    }
    patternController.text = existing.join('\n');
    patternController.selection = TextSelection.collapsed(
      offset: patternController.text.length,
    );
    setState(() {
      autoPatternHint = '自動提案を追加しました: $generated';
    });
    _refreshPreview();
  }

  String _buildPreview(List<String> patterns, String testText) {
    try {
      if (patterns.isEmpty) {
        return 'ルール未設定: 既定の抽出ロジックを使います';
      }
      if (testText.trim().isEmpty) {
        return 'テスト文字列を入力すると、マッチ候補を表示します';
      }

      final normalized = widget.normalizeText(testText);
      final matches = <String>[];

      for (final pattern in patterns) {
        final regex = RegExp(pattern, caseSensitive: false);
        for (final source in [testText, normalized]) {
          for (final match in regex.allMatches(source)) {
            if (match.groupCount >= 1) {
              for (var i = 1; i <= match.groupCount; i++) {
                final group = match.group(i);
                if (group != null && group.isNotEmpty) {
                  matches.add(group);
                }
              }
              continue;
            }
            final full = match.group(0);
            if (full != null && full.isNotEmpty) {
              matches.add(full);
            }
          }
        }
      }

      if (matches.isEmpty) {
        return 'マッチなし';
      }
      return 'マッチ: ${matches.join(', ')}';
    } catch (e) {
      return 'プレビューエラー: $e';
    }
  }

  void _save() {
    final parsed = _parsePatterns(patternController.text);
    for (final pattern in parsed) {
      try {
        RegExp(pattern, caseSensitive: false);
      } catch (_) {
        setState(() {
          validationError = '無効な正規表現: $pattern';
        });
        return;
      }
    }
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('抽出ルール設定'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1行に1つずつ正規表現を入力します'),
              const SizedBox(height: 10),
              TextField(
                controller: patternController,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: r'例: M[-_\s]*(\d{7,})',
                ),
                onChanged: (_) => _refreshPreview(),
              ),
              const SizedBox(height: 8),
              Text(
                '空なら既定ルール（M優先 + 数字補助）で抽出します',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              const Text('テスト入力'),
              const SizedBox(height: 8),
              TextField(
                controller: testController,
                maxLines: 3,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'OCR結果の1行を貼り付けて確認',
                ),
                onChanged: (_) => _refreshPreview(),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _applyAutoPattern,
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('入力から自動提案'),
                  ),
                ],
              ),
              if (autoPatternHint.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  autoPatternHint,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Text(preview),
              ),
              if (validationError.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  validationError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
