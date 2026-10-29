class Failure {
  final String message;
  final String? code;
  final Object? cause;

  const Failure(this.message, {this.code, this.cause});

  @override
  String toString() => 'Failure(message: $message, code: $code, cause: $cause)';
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.code, super.cause});
}

class CacheFailure extends Failure {
  const CacheFailure(super.message, {super.code, super.cause});
}

