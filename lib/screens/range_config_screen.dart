import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:asset_check/models.dart';

class RangeConfigScreen extends StatefulWidget {
  final int? initialStart;
  final int? initialEnd;

  const RangeConfigScreen({
    super.key,
    this.initialStart,
    this.initialEnd,
  });

  @override
  State<RangeConfigScreen> createState() => _RangeConfigScreenState();
}

class _RangeConfigScreenState extends State<RangeConfigScreen> {
  late final TextEditingController startController;
  late final TextEditingController endController;

  @override
  void initState() {
    super.initState();
    startController = TextEditingController(
      text: widget.initialStart?.toString() ?? '',
    );
    endController = TextEditingController(
      text: widget.initialEnd?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    startController.dispose();
    endController.dispose();
    super.dispose();
  }

  void saveRange() {
    final start = int.tryParse(startController.text);
    final end = int.tryParse(endController.text);

    if (start == null || end == null) {
      showError('開始値と終了値を入力してください');
      return;
    }

    if (start < 1 || end > 9999) {
      showError('範囲は 1 から 9999 の間で指定してください');
      return;
    }

    if (start > end) {
      showError('開始値は終了値以下にしてください');
      return;
    }

    Navigator.pop(context, RangeConfigResult(start: start, end: end));
  }

  void showError(String message) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('連番設定')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('1 から 9999 の範囲で連番を設定します'),
            const SizedBox(height: 16),
            TextField(
              controller: startController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: false,
                signed: false,
              ),
              textInputAction: TextInputAction.next,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '開始値',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: endController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: false,
                signed: false,
              ),
              textInputAction: TextInputAction.done,
              enableSuggestions: false,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '終了値',
              ),
              onSubmitted: (_) {
                saveRange();
              },
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: saveRange,
              child: const Text('この範囲で作成'),
            ),
          ],
        ),
      ),
    );
  }
}
