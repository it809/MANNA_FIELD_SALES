
import 'package:dio/dio.dart';

import 'package:manna_field_sales/core/app_bus.dart';

class Session {
  static final Session I = Session._();
  Session._();

  String baseUrl = 'https://mannarubber.m.frappe.cloud';
  String email = '';
  String sid = '';
  String csrfToken = '';
  String? salesPerson;
  String? salesPersonLabel;
  String? managedTeam;
  List<String> teamReps = [];
  bool isGM = false;
  bool isHR = false;
  String? company;
  bool isProductionManager = false;
  String? productionCompany;
  bool get isManager => managedTeam != null && managedTeam!.isNotEmpty;
  late Dio dio;

  void init() {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
      validateStatus: (s) => s != null && s < 500,
    ));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        // Authenticate every request with the session cookie.
        if (sid.isNotEmpty) {
          options.headers['Cookie'] = 'sid=$sid';
        }
        // Frappe requires a CSRF token on writes when using cookie auth.
        final m = options.method.toUpperCase();
        if (csrfToken.isNotEmpty &&
            (m == 'POST' || m == 'PUT' || m == 'DELETE')) {
          options.headers['X-Frappe-CSRF-Token'] = csrfToken;
        }
        handler.next(options);
      },
      onResponse: (response, handler) {
        final m = response.requestOptions.method.toUpperCase();
        final path = response.requestOptions.path;
        final sc = response.statusCode ?? 0;
        if (sc >= 200 &&
            sc < 300 &&
            (m == 'POST' || m == 'PUT' || m == 'DELETE') &&
            path.contains('/api/resource/')) {
          AppBus.I.bump();
        }
        handler.next(response);
      },
    ));
  }
}

