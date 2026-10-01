import 'dart:isolate';

/// Executes a native task in a new isolate.
Future<R> runTask<T, R>(T input, R Function(T input) task) => Isolate.run(() => task(input));
