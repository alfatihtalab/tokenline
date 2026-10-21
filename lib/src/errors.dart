/// A user-facing failure: bad token data, bad config, or a Figma problem.
///
/// Commands print [message] and exit with [exitCode]; anything else that is
/// thrown is a bug in tokenline itself.
class TokenlineException implements Exception {
  TokenlineException(this.message, {this.exitCode = 1});

  final String message;

  /// 1 = error, 2 = drift (something is out of date, nothing is broken).
  final int exitCode;

  @override
  String toString() => message;
}
