/// Executes a browser task inline and reports failures through its future.
Future<R> runTask<T, R>(T input, R Function(T input) task) => Future<R>.sync(() => task(input));
