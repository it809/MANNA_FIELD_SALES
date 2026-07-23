import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/net_error.dart';

RequestOptions _req() => RequestOptions(path: '/api/resource/Customer');

void main() {
  group('isOffline', () {
    test('true for the ways a request never reaches the server', () {
      for (final t in const [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(isOffline(DioException(requestOptions: _req(), type: t)), isTrue,
            reason: '$t');
      }
      expect(
          isOffline(DioException(
              requestOptions: _req(),
              type: DioExceptionType.unknown,
              error: const SocketException('Failed host lookup'))),
          isTrue);
      expect(isOffline(const SocketException('Network is unreachable')), isTrue);
      expect(isOffline(TimeoutException('gave up')), isTrue);
    });

    test('false when the server answered — it has something to say', () {
      final refused = DioException(
        requestOptions: _req(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: _req(), statusCode: 500),
      );
      expect(isOffline(refused), isFalse);
      expect(isOffline(Exception('Insufficient permission for Customer')),
          isFalse);
    });

    test('reads a socket failure that survived only as a string', () {
      expect(isOffline('SocketException: Failed host lookup: erp.example.com'),
          isTrue);
    });
  });

  group('wording', () {
    test('offline says what to do about it', () {
      final e = DioException(
          requestOptions: _req(), type: DioExceptionType.connectionError);
      expect(errorTitle(e), kNoConnectionTitle);
      expect(errorDetail(e), kNoConnectionBody);
      expect(errorLine(e), contains(kNoConnectionBody));
    });

    test('a server message reaches the rep intact', () {
      final e = Exception('Credit limit exceeded for ACME');
      expect(errorDetail(e), 'Credit limit exceeded for ACME');
      expect(errorLine(e), 'Failed: Credit limit exceeded for ACME');
    });

    test('a raw DioException never reaches the rep', () {
      final e = DioException(
        requestOptions: _req(),
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: _req(), statusCode: 500),
      );
      expect(errorDetail(e), 'The server returned an error (HTTP 500).');
    });
  });
}
