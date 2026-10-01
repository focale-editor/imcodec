import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart';

/// Calls observed by a task in its own execution context.
int _taskCalls = 0;

/// Identifies whether successive tasks share the caller's execution context.
int _countTask(int input) => ++_taskCalls;

/// Checks the native and browser contracts of the public runners.
void main() {
  final Map<String, ParallelRunner> runners = {
    'sequential': runSequentially,
    'isolates': onIsolates,
    'bounded isolates': onBoundedIsolates,
  };

  for (final MapEntry<String, ParallelRunner> entry in runners.entries) {
    test('${entry.key} preserves result order and nullable values', () async {
      final List<String?> results = await entry.value<int, String?>(
        [3, 1, 2],
        (input) => input == 1 ? null : '$input',
      );

      expect(results, ['3', null, '2']);
      expect(await entry.value<int, int>([], (input) => input), isEmpty);
    });

    test('${entry.key} reports task errors through the future', () async {
      final Future<List<int>> result = entry.value<int, int>(
        [1, 2, 3],
        (input) {
          if (input == 2) {
            throw const FormatException('task failed');
          }
          return input;
        },
      );

      await expectLater(result, throwsA(isA<FormatException>().having((error) => error.message, 'message', 'task failed')));
    });

    test('${entry.key} produces the same PNG bytes as synchronous encoding', () async {
      final Image image = Image(width: 64, height: 32)..setPixelRgba(0, 0, 10, 20, 30, 255);

      expect(await encodePngWith(entry.value, image), encodePng(image));
    });
  }

  for (final String name in ['isolates', 'bounded isolates']) {
    test('$name uses separate contexts only on native platforms', () async {
      _taskCalls = 0;

      final List<int> results = await runners[name]!<int, int>([0, 0, 0], _countTask);

      const bool native = bool.fromEnvironment('dart.library.io');
      expect(results, native ? [1, 1, 1] : [1, 2, 3]);
      expect(_taskCalls, native ? 0 : 3);
    });
  }
}
