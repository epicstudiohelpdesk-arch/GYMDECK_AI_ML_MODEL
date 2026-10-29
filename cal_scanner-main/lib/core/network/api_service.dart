import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:http/http.dart' as http;

import '../error/failure.dart';

class ApiService {
  final http.Client _client;

  ApiService(this._client);

  Future<Either<Failure, Map<String, dynamic>>> postJson(
    Uri url, {
    required Map<String, String> headers,
    required Object body,
  }) async {
    try {
      final response = await _client.post(
        url,
        headers: headers,
        body: jsonEncode(body),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return left(
          NetworkFailure(
            'API error: ${response.statusCode}',
            cause: response.body,
          ),
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return right(decoded);
      }
      return left(
        NetworkFailure('Unexpected response shape', cause: response.body),
      );
    } catch (e) {
      return left(NetworkFailure('Network request failed', cause: e));
    }
  }
}

