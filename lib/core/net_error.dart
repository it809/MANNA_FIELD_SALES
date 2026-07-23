// Turning a failed request into something a rep can act on.
//
// Reps work out of vans and warehouses where coverage drops constantly, so
// "the phone never reached the server" is the single most common failure in
// the app — and the only one they can fix themselves. It gets its own wording
// and its own retry, instead of a raw `DioException` dump.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

const String kNoConnectionTitle = 'No Connection';
const String kNoConnectionBody =
    'Please check your internet connectivity and try again.';

/// True when the request never got an answer: no signal, no Wi-Fi, DNS down,
/// or a socket that sat there until it timed out.
///
/// A refusal the server actually sent back is *not* offline — it has something
/// to say, and telling the rep to check their signal would be a lie.
bool isOffline(Object? e) {
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.unknown:
        // Dio parks the real cause here — usually a SocketException.
        return e.error != null ? isOffline(e.error) : _looksOffline('$e');
      default:
        return false;
    }
  }
  if (e is SocketException || e is HttpException) return true;
  if (e is TimeoutException) return true;
  return _looksOffline('$e');
}

// Last resort, for callers that kept only the string form of the error.
bool _looksOffline(String s) {
  final t = s.toLowerCase();
  return const [
    'socketexception',
    'timeoutexception',
    'failed host lookup',
    'network is unreachable',
    'no address associated with hostname',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection timed out',
    'connection error',
    'software caused connection abort',
  ].any(t.contains);
}

/// Headline for a screen that has nothing to show because the load failed.
String errorTitle(Object? e) =>
    isOffline(e) ? kNoConnectionTitle : 'Something went wrong';

/// The line under [errorTitle] — what to do about it, or what the server said.
String errorDetail(Object? e) => isOffline(e) ? kNoConnectionBody : _clean(e);

/// One line, for a snack bar reporting an action that did not go through.
String errorLine(Object? e) => isOffline(e)
    ? '$kNoConnectionTitle. $kNoConnectionBody'
    : 'Failed: ${_clean(e)}';

// Strip the wrapper Dart puts on a thrown Exception, and never show a raw
// DioException — its toString() is a stack of URLs and options.
String _clean(Object? e) {
  if (e == null) return 'Please try again.';
  if (e is DioException) {
    final sc = e.response?.statusCode;
    return sc == null
        ? 'Could not reach the server. Please try again.'
        : 'The server returned an error (HTTP $sc).';
  }
  final s = '$e'.replaceFirst('Exception: ', '').trim();
  if (s.isEmpty) return 'Please try again.';
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
