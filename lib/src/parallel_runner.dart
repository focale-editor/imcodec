import 'dart:async';
import 'dart:isolate';

/// Runs independent pieces of work, optionally on other isolates.
///
/// This package never starts an isolate itself: encoding stays synchronous and
/// self-contained, and the decision to spread work across cores belongs to the
/// application, which knows how many isolates it can afford and whether it
/// already has a pool. A runner receives a list of independent inputs and a
/// top-level task function, and returns one result per input **in the same
/// order**. Order matters: the encoded output depends on it, and keeping it
/// makes a parallel encode produce exactly the same bytes as a sequential one.
///
/// Inputs, results, and the task must all be sendable, so a runner may forward
/// them straight to [Isolate.run]:
///
/// ```dart
/// Future<List<R>> runOnIsolates<T, R>(List<T> inputs, R Function(T input) task) =>
///     Future.wait([for (final T input in inputs) Isolate.run(() => task(input))]);
/// ```
///
/// A pool that bounds concurrency fits the same signature, and so does a
/// runner that simply calls the task inline, which is what an encode without a
/// runner already does.
typedef ParallelRunner = Future<List<R>> Function<T, R>(List<T> inputs, R Function(T input) task);

/// Runs every task on the current isolate, in order.
///
/// Useful as a default and to check that a parallel run agrees with a
/// sequential one.
Future<List<R>> runSequentially<T, R>(List<T> inputs, R Function(T input) task) async => <R>[for (final T input in inputs) task(input)];

/// Runs one isolate per job, the shortest runner a caller can write.
Future<List<R>> onIsolates<T, R>(List<T> inputs, R Function(T input) task) => Future.wait(<Future<R>>[for (final T input in inputs) Isolate.run(() => task(input))]);

/// Runs jobs on isolates, never more than [limit] at a time.
Future<List<R>> onBoundedIsolates<T, R>(List<T> inputs, R Function(T input) task, {int limit = 2}) async {
  final List<R?> results = List<R?>.filled(inputs.length, null);
  int next = 0;
  Future<void> worker() async {
    while (true) {
      final int index = next++;
      if (index >= inputs.length) {
        return;
      }
      final T input = inputs[index];
      results[index] = await Isolate.run(() => task(input));
    }
  }

  await Future.wait(<Future<void>>[for (int i = 0; i < limit && i < inputs.length; i++) worker()]);
  return <R>[for (final R? result in results) result as R];
}
