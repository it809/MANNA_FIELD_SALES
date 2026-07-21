import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:manna_field_sales/core/auth_store.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/screens/map/day_map_screen.dart';

/// Builds the REST path for an ERPNext doctype. Private to this library —
/// only [Api] ever needs it.
String _res(String doctype) => '/api/resource/${Uri.encodeComponent(doctype)}';

class Api {
  static Future<bool> testAuth() async {
    final r = await Session.I.dio.get('/api/method/frappe.auth.get_logged_user');
    final u = (r.data is Map) ? r.data['message'] : null;
    return r.statusCode == 200 && u is String && u.isNotEmpty && u != 'Guest';
  }

  // ---------------------------------------------------------------- auth ---
  //
  // Reps used to be logged out whenever Frappe expired the `sid` cookie
  // (6 hours by default). Auth now prefers an API key/secret pair, which
  // Frappe never expires, and falls back to a silent password re-login for
  // accounts that cannot mint one. Either way the login screen only ever
  // reappears if the credentials are genuinely rejected.

  /// Interactive login. Establishes a session, remembers the credentials, then
  /// tries to upgrade to a permanent token.
  static Future<void> login(String email, String password) async {
    await _passwordLogin(email, password);
    await AuthStore.saveLogin(
        baseUrl: Session.I.baseUrl, email: email, password: password);
    await provisionToken(email);
  }

  /// Restore the last session at app start without prompting the rep.
  /// Returns true if we ended up authenticated.
  static Future<bool> restore() async {
    final c = await AuthStore.load();
    if (c.email.isEmpty) return false;
    if (c.baseUrl.isNotEmpty) Session.I.baseUrl = c.baseUrl;
    Session.I.email = c.email;
    Session.I.sid = c.sid;
    Session.I.apiKey = c.apiKey;
    Session.I.apiSecret = c.apiSecret;
    Session.I.init();
    attachAutoReauth();
    if (!Session.I.hasToken && c.sid.isNotEmpty) await fetchCsrf();
    // A stale sid is repaired by the interceptor mid-flight, so this usually
    // succeeds on the first try even after days of idle.
    if (await testAuth()) return true;
    return c.canReauth && await _reauthenticate();
  }

  /// Lets the Dio interceptor recover from an expired credential on its own.
  static void attachAutoReauth() {
    Session.I.reauthenticate = _reauthenticate;
  }

  /// Silent re-authentication. Never shows UI, never throws.
  static Future<bool> _reauthenticate() async {
    final email = Session.I.email;
    final password = await AuthStore.password();
    if (email.isEmpty || password.isEmpty) return false;
    try {
      await _passwordLogin(email, password);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Log in with email + password. Captures the session cookie (sid) returned
  // by Frappe, then fetches a CSRF token so writes are allowed.
  static Future<void> _passwordLogin(String email, String password) async {
    // Getting here means any token we held was rejected; drop it so the
    // request below (and everything after) authenticates by cookie.
    Session.I.clearAuth();
    await AuthStore.clearToken();
    final r = await Session.I.dio.post(
      '/api/method/login',
      data: {'usr': email, 'pwd': password},
      options: Options(
          contentType: Headers.formUrlEncodedContentType,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (s) => s != null && s < 500),
    );
    if (r.statusCode != 200) {
      throw Exception('Invalid email or password.');
    }
    // Extract sid from the Set-Cookie header(s).
    final setCookies = r.headers.map['set-cookie'] ?? const <String>[];
    String sid = '';
    for (final c in setCookies) {
      final m = RegExp(r'sid=([^;]+)').firstMatch(c);
      if (m != null) sid = m.group(1) ?? '';
    }
    if (sid.isEmpty || sid == 'Guest') {
      throw Exception('Invalid email or password.');
    }
    Session.I.sid = sid;
    Session.I.email = email;
    await AuthStore.saveSid(sid);
    await fetchCsrf();
  }

  /// Best effort upgrade from cookie auth to a permanent API token.
  ///
  /// Frappe's stock `generate_keys` is System Manager only, so managers and
  /// admins get a token while ordinary reps quietly stay on the cookie +
  /// silent-re-login path. To give reps tokens too, expose a whitelisted
  /// server method that calls `generate_keys` on the caller's own user and
  /// point [_tokenMethod] at it.
  static const _tokenMethod =
      '/api/method/frappe.core.doctype.user.user.generate_keys';

  static Future<bool> provisionToken(String email) async {
    if (Session.I.hasToken) return true;
    try {
      final r = await Session.I.dio.post(_tokenMethod,
          data: {'user': email},
          options: Options(contentType: Headers.formUrlEncodedContentType));
      final m = (r.data is Map) ? r.data['message'] : null;
      final secret = (m is Map) ? '${m['api_secret'] ?? ''}' : '';
      if (secret.isEmpty) return false;
      final key = await _fetchApiKey(email);
      if (key.isEmpty) return false;
      Session.I.apiKey = key;
      Session.I.apiSecret = secret;
      await AuthStore.saveToken(key, secret);
      return true;
    } catch (_) {
      return false;
    }
  }

  // generate_keys returns only the secret; the key itself lives on the User.
  static Future<String> _fetchApiKey(String email) async {
    final r = await Session.I.dio.get(
        '${_res('User')}/${Uri.encodeComponent(email)}',
        queryParameters: {'fields': '["api_key"]'});
    final d = (r.data is Map) ? r.data['data'] : null;
    return (d is Map) ? '${d['api_key'] ?? ''}' : '';
  }

  // Best-effort CSRF token retrieval. Frappe embeds it in the desk boot.
  static Future<void> fetchCsrf() async {
    try {
      // noRetry: fetchCsrf runs inside the re-auth flow itself.
      final r = await Session.I.dio.get('/app',
          options: Session.noRetry.copyWith(
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 500));
      final html = '${r.data}';
      final m = RegExp(r'"csrf_token":\s*"([0-9a-zA-Z]+)"').firstMatch(html) ??
          RegExp(r'csrf_token\s*=\s*"([0-9a-zA-Z]+)"').firstMatch(html);
      Session.I.csrfToken = m?.group(1) ?? '';
    } catch (_) {
      Session.I.csrfToken = '';
    }
  }

  static Future<void> logout() async {
    Session.I.reauthenticate = null;
    try {
      await Session.I.dio.get('/api/method/logout');
    } catch (_) {}
    Session.I.clearAuth();
    await AuthStore.clear();
  }

  static Future<List<Map<String, dynamic>>> _list(String doctype,
      {required String fields,
        String? filters,
        String orderBy = 'creation desc',
        int limit = 0}) async {
    final qp = <String, dynamic>{
      'fields': fields,
      'order_by': orderBy,
      'limit_page_length': limit,
    };
    if (filters != null) qp['filters'] = filters;
    final r = await Session.I.dio.get(_res(doctype), queryParameters: qp);
    final data = (r.data is Map) ? r.data['data'] : null;
    if (data is List) return data.cast<Map<String, dynamic>>();
    throw Exception(_frappeError(r));
  }

  static Future<int> getCount(String doctype, String filters) async {
    final r = await Session.I.dio.get('/api/method/frappe.client.get_count',
        queryParameters: {'doctype': doctype, 'filters': filters});
    final m = r.data is Map ? r.data['message'] : null;
    return (m is num) ? m.toInt() : 0;
  }

  static Future<List<Map<String, dynamic>>> getCustomers() {
    final rep = Session.I.salesPerson;
    final filters = (rep == null || rep.isEmpty)
        ? null
        : '[["custom_assigned_reps","like","%|$rep|%"]]';
    return _list('Customer',
        fields:
        '["name","customer_name","customer_group","territory","custom_latitude","custom_longitude","custom_location_status","custom_verified_latitude","custom_verified_longitude","custom_outstanding_balance","custom_credit_limit","custom_phone"]',
        filters: filters,
        orderBy: 'customer_name asc');
  }

  static Future<String?> _loggedUser() async {
    try {
      final r =
      await Session.I.dio.get('/api/method/frappe.auth.get_logged_user');
      final m = (r.data is Map) ? r.data['message'] : null;
      return (m is String && m.isNotEmpty) ? m : null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getSalesPersons() async {
    final user = await _loggedUser();
    if (user == null) return [];
    return _list('Sales Person',
        fields: '["name","sales_person_name","custom_company"]',
        filters: '[["is_group","=",0],["custom_user","=","$user"]]');
  }

  static Future<void> resolveMySalesPerson() async {
    final list = await getSalesPersons();
    if (list.isNotEmpty) {
      Session.I.salesPerson = list.first['name'] as String;
      Session.I.salesPersonLabel =
      (list.first['sales_person_name'] ?? list.first['name']) as String;
      Session.I.company = list.first['custom_company'] as String?;
    } else {
      Session.I.salesPerson = null;
      Session.I.salesPersonLabel = null;
      Session.I.company = null;
    }
  }

  // -------- Manager context --------
  static Future<void> resolveManagerContext() async {
    Session.I.managedTeam = null;
    Session.I.teamReps = [];
    Session.I.isGM = false;
    Session.I.isHR = false;
    Session.I.isProductionManager = false;
    Session.I.productionCompany = null;
    final user = await _loggedUser();
    if (user == null) return;
    try {
      final r = await Session.I.dio.get(_res('User') + '/$user',
          queryParameters: {
            'fields': '["custom_managed_team","custom_is_general_manager","custom_is_hr_manager","custom_is_production_manager","custom_production_company"]'
          });
      final data = (r.data is Map && r.data['data'] is Map)
          ? r.data['data'] as Map
          : const {};
      final team = data['custom_managed_team'];
      Session.I.isGM = (data['custom_is_general_manager'] ?? 0) == 1;
      Session.I.isHR = (data['custom_is_hr_manager'] ?? 0) == 1;
      Session.I.isProductionManager =
          (data['custom_is_production_manager'] ?? 0) == 1;
      final pc = data['custom_production_company'];
      if (pc is String && pc.isNotEmpty) Session.I.productionCompany = pc;
      if (team is String && team.isNotEmpty) {
        Session.I.managedTeam = team;
        final reps = await _list('Sales Person',
            fields: '["name"]',
            filters: '[["custom_team_manager","=","$team"]]',
            orderBy: 'name asc');
        Session.I.teamReps = reps.map((e) => e['name'] as String).toList();
      }
    } catch (_) {}
  }

  static String _inList(List<String> xs) =>
      '[${xs.map((e) => '"${e.replaceAll('"', '')}"').join(',')}]';

  // -------- Approvals (team-scoped) --------
  static Future<List<Map<String, dynamic>>> getPendingLeadOrderApprovals() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead Order',
        fields:
        '["name","lead_name","sales_person","order_date","total_amount","status"]',
        filters:
        '[["status","=","Pending Approval"],["sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLeadOrderPOs() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead Order',
        fields:
        '["name","lead_name","sales_person","order_date","total_amount","status","po_number"]',
        filters:
        '[["status","=","PO Uploaded"],["sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingSalesOrderPOs() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Sales Order',
        fields:
        '["name","customer","custom_sales_person","grand_total","custom_po_status","custom_po_number"]',
        filters:
        '[["custom_po_status","=","PO Uploaded - Pending Approval"],["custom_sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingProformaReleases() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Sales Order',
        fields:
        '["name","customer","custom_sales_person","grand_total","custom_proforma_status"]',
        filters:
        '[["custom_proforma_status","=","Pending Release Approval"],["custom_sales_person","in",${_inList(team)}]]',
        orderBy: 'creation desc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLocationVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Customer',
        fields:
        '["name","customer_name","custom_location_captured_by","custom_latitude","custom_longitude","custom_banner_photo"]',
        filters:
        '[["custom_location_status","=","Pending Verification"],["custom_location_captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> _put(String doctype, String name,
      Map<String, dynamic> body) async {
    final r =
    await Session.I.dio.put(_res(doctype) + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<void> approveLeadOrder(String name, bool approve) =>
      _put('Lead Order', name, {'status': approve ? 'Approved' : 'Rejected'});

  static Future<void> approveLeadOrderPO(String name, bool approve) => _put(
      'Lead Order',
      name,
      {'status': approve ? 'PO Approved - Ready for SAP' : 'Rejected'});

  static Future<void> approveSalesOrderPO(String name, bool approve) => _put(
      'Sales Order',
      name,
      {'custom_po_status': approve ? 'PO Approved - Ready for SAP' : 'Rejected'});

  static Future<void> releaseProforma(String name, bool approve) => _put(
      'Sales Order',
      name,
      {'custom_proforma_status': approve ? 'Released' : 'Blocked - Credit'});

  // Approve a captured customer location: copy captured coords into the
  // verified fields so the 100 m check-in works against them. Reject sends
  // it back to "Not Captured" so the rep can re-capture.
  static Future<void> approveLocation(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Customer', name, {
        'custom_location_status': 'Verified',
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      });
    }
    return _put('Customer', name, {'custom_location_status': 'Not Captured'});
  }

  static Future<void> captureLeadLocation({
    required String lead,
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    await _put('Lead', lead, {
      'custom_latitude': lat,
      'custom_longitude': lng,
      'custom_location_status': 'Pending Verification',
      'custom_location_captured_by': salesPerson,
    });
  }

  static Future<List<Map<String, dynamic>>>
  getPendingLeadLocationVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Lead',
        fields:
        '["name","lead_name","custom_location_captured_by","custom_latitude","custom_longitude","custom_banner_photo"]',
        filters:
        '[["custom_location_status","=","Pending Verification"],["custom_location_captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> approveLeadLocation(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Lead', name, {
        'custom_location_status': 'Verified',
        'custom_verified_latitude': lat,
        'custom_verified_longitude': lng,
      });
    }
    return _put('Lead', name, {'custom_location_status': 'Rejected'});
  }

  // ---- Logged-in rep's own target (shown on their home dashboard) ----
  static Future<Map<String, dynamic>?> getMyTarget() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final now = DateTime.now();
    final month = monthNames[now.month - 1];
    final list = await _list('Sales Target',
        fields: '["name","target_amount","target_unit"]',
        filters:
        '[["sales_person","=","$me"],["month","=","$month"],["year","=",${now.year}]]',
        limit: 1);
    return list.isEmpty ? null : list.first;
  }

  // Rep currency: AED for the UAE (Renjith) team, INR otherwise.
  static Future<String> myCurrency() async {
    final me = Session.I.salesPerson;
    if (me == null) return 'INR';
    final sp = await _list('Sales Person',
        fields: '["custom_team_manager"]',
        filters: '[["name","=","$me"]]',
        limit: 1);
    final mgr =
    sp.isNotEmpty ? (sp.first['custom_team_manager'] ?? '').toString() : '';
    return mgr == 'Renjith' ? 'AED' : 'INR';
  }

  // -------- Targets --------
  static List<String> get monthNames => const [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  static Future<List<Map<String, dynamic>>> getTargets(
      String month, int year) {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Sales Target',
        fields:
        '["name","sales_person","month","year","target_amount","target_unit"]',
        filters:
        '[["month","=","$month"],["year","=",$year],["sales_person","in",${_inList(team)}]]',
        orderBy: 'sales_person asc');
  }

  // UAE team (Renjith) targets in AED; India teams (Saneesh/Pareeth) in INR.
  static String get teamCurrency =>
      Session.I.managedTeam == 'Renjith' ? 'AED' : 'INR';

  static Future<void> upsertTarget({
    required String salesPerson,
    required String month,
    required int year,
    required double amount,
    required String unit,
  }) async {
    final existing = await _list('Sales Target',
        fields: '["name"]',
        filters:
        '[["sales_person","=","$salesPerson"],["month","=","$month"],["year","=",$year]]',
        limit: 1);
    if (existing.isNotEmpty) {
      await _put('Sales Target', existing.first['name'] as String,
          {'target_amount': amount, 'target_unit': unit});
    } else {
      final r = await Session.I.dio.post(_res('Sales Target'), data: {
        'sales_person': salesPerson,
        'month': month,
        'year': year,
        'target_amount': amount,
        'target_unit': unit,
        'set_by': Session.I.managedTeam,
      });
      if (r.statusCode != 200 && r.statusCode != 201) {
        throw Exception(_frappeError(r));
      }
    }
  }

  static Future<double> getMonthCollections(String rep) async {
    final list = await _list('Collection Entry',
        fields: '["amount"]',
        filters:
        '[["sales_person","=","$rep"],["collection_date","Timespan","this month"]]');
    double t = 0;
    for (final e in list) {
      t += ((e['amount'] ?? 0) as num).toDouble();
    }
    return t;
  }

  // Sales achieved this month = manager-approved POs (ready for SAP),
  // across both Sales Orders and Lead Orders for this rep.
  static Future<double> getMonthSales(String rep) async {
    double t = 0;
    final so = await _list('Sales Order',
        fields: '["grand_total"]',
        filters:
        '[["custom_sales_person","=","$rep"],["custom_po_status","=","PO Approved - Ready for SAP"],["transaction_date","Timespan","this month"]]');
    for (final e in so) {
      t += ((e['grand_total'] ?? 0) as num).toDouble();
    }
    final lo = await _list('Lead Order',
        fields: '["total_amount"]',
        filters:
        '[["sales_person","=","$rep"],["status","=","PO Approved - Ready for SAP"],["order_date","Timespan","this month"]]');
    for (final e in lo) {
      t += ((e['total_amount'] ?? 0) as num).toDouble();
    }
    return t;
  }

  // Rep's total outstanding = sum of outstanding across customers assigned to
  // that rep (custom_assigned_reps is pipe-delimited, e.g. "|Subhash|").
  static Future<double> getRepOutstanding(String rep) async {
    final list = await _list('Customer',
        fields: '["custom_outstanding_balance"]',
        filters: '[["custom_assigned_reps","like","%|$rep|%"]]',
        limit: 0);
    double t = 0;
    for (final e in list) {
      t += ((e['custom_outstanding_balance'] ?? 0) as num).toDouble();
    }
    return t;
  }

  static Future<double> getRepOutstandingLimit(String rep) async {
    final l = await _list('Sales Person',
        fields: '["custom_outstanding_limit"]',
        filters: '[["name","=","$rep"]]',
        limit: 1);
    if (l.isEmpty) return 0;
    return ((l.first['custom_outstanding_limit'] ?? 0) as num).toDouble();
  }

  static Future<double> getCustomerOutstanding(String customer) async {
    final l = await _list('Customer',
        fields: '["custom_outstanding_balance"]',
        filters: '[["name","=","$customer"]]',
        limit: 1);
    if (l.isEmpty) return 0;
    return ((l.first['custom_outstanding_balance'] ?? 0) as num).toDouble();
  }

  static Future<void> upsertOutstandingLimit(String rep, double amount) =>
      _put('Sales Person', rep, {'custom_outstanding_limit': amount});

  // Escalation: manager approved but rep is over their outstanding limit ->
  // needs General Manager approval before it can go to SAP.
  static Future<void> escalateSalesOrderPOToGM(String name) =>
      _put('Sales Order', name, {'custom_po_status': 'Pending GM Approval'});

  static Future<void> escalateLeadOrderPOToGM(String name) =>
      _put('Lead Order', name, {'status': 'Pending GM Approval'});

  // GM queues: anything sitting at "Pending GM Approval".
  static Future<List<Map<String, dynamic>>> getPendingGMSalesOrderPOs() =>
      _list('Sales Order',
          fields:
          '["name","customer","custom_sales_person","grand_total","custom_po_status"]',
          filters: '[["custom_po_status","=","Pending GM Approval"]]',
          orderBy: 'creation desc');

  static Future<List<Map<String, dynamic>>> getPendingGMLeadOrderPOs() =>
      _list('Lead Order',
          fields: '["name","lead_name","sales_person","total_amount","status"]',
          filters: '[["status","=","Pending GM Approval"]]',
          orderBy: 'creation desc');


  static Future<List<Map<String, dynamic>>> getItems() => _list('Item',
      fields: '["name","item_name","stock_uom","standard_rate"]',
      filters: '[["disabled","=",0],["is_sales_item","=",1]]',
      orderBy: 'item_name asc');

  static Future<List<String>> getCustomerGroups() async {
    final l = await _list('Customer Group',
        fields: '["name"]',
        filters: '[["is_group","=",0]]',
        orderBy: 'name asc');
    return l.map((e) => e['name'] as String).toList();
  }

  static Future<List<String>> getTerritories() async {
    final l = await _list('Territory',
        fields: '["name"]',
        filters: '[["is_group","=",0]]',
        orderBy: 'name asc');
    return l.map((e) => e['name'] as String).toList();
  }

  static Future<String> createCustomer({
    required String name,
    required String group,
    required String territory,
    String? phone,
  }) async {
    final rep = Session.I.salesPerson;
    final body = <String, dynamic>{
      'customer_name': name,
      'customer_type': 'Company',
      'customer_group': group,
      'territory': territory,
      'custom_assigned_reps': (rep != null && rep.isNotEmpty) ? '|$rep|' : '',
      'custom_location_status': 'Not Captured',
    };
    if (phone != null && phone.trim().isNotEmpty) {
      body['custom_phone'] = phone.trim();
    }
    final r = await Session.I.dio.post(_res('Customer'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // Restrict a list to the logged-in person's own sales_person.
  // If somehow no rep is resolved, force an impossible match (show nothing)
  // rather than leaking everyone's data.
  static String _mineFilter([String field = 'sales_person']) {
    final rep = Session.I.salesPerson;
    final v = (rep == null || rep.isEmpty) ? '__none__' : rep;
    return '[["$field","=","$v"]]';
  }

  static Future<List<Map<String, dynamic>>> getMyVisits() => _list('Sales Visit',
      fields: '["name","customer","visit_date","visit_status"]',
      filters: _mineFilter(),
      limit: 50);

  // ---- Trip tagging + visit linking (Sub-chunk 4) ----
  static Future<Map<String, dynamic>?> getActiveTrip() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final list = await _list('Trip',
        fields: '["name","trip_date","purpose"]',
        filters: '[["sales_person","=","$me"],["status","=","Active"]]',
        orderBy: 'creation desc',
        limit: 1);
    return list.isNotEmpty ? list.first : null;
  }

  static Future<List<Map<String, dynamic>>> getAllSalesPersons() =>
      _list('Sales Person',
          fields: '["name"]', orderBy: 'name asc', limit: 0);

  static Future<List<Map<String, dynamic>>> getVisitsForTrip(String tripName) =>
      _list('Sales Visit',
          fields:
          '["name","customer","visit_date","visit_status","sales_person"]',
          filters: '[["custom_trip","=","$tripName"]]',
          orderBy: 'creation desc',
          limit: 0);

  static Future<void> saveTripTaggedReps(
      String tripName, List<String> reps) async {
    final rows = reps.map((r) => {'sales_person': r}).toList();
    final csv = reps.isEmpty ? '' : '|${reps.join('|')}|';
    await _put('Trip', tripName, {'tagged_reps': rows, 'tagged_csv': csv});
  }

  static Future<List<String>> _tripsTaggedForMe() async {
    final me = Session.I.salesPerson;
    if (me == null) return [];
    final rows = await _list('Trip',
        fields: '["name"]',
        filters: '[["tagged_csv","like","%|$me|%"]]',
        limit: 0);
    return rows.map((r) => '${r['name']}').toList();
  }

  // My visits + visits on trips I'm tagged on (auto-shared).
  static Future<List<Map<String, dynamic>>> getMyVisitsIncludingTagged() async {
    const f =
        '["name","customer","visit_date","visit_status","sales_person","custom_trip"]';
    final own =
    await _list('Sales Visit', fields: f, filters: _mineFilter(), limit: 50);
    final byName = <String, Map<String, dynamic>>{};
    for (final v in own) {
      byName['${v['name']}'] = v;
    }
    final tagged = await _tripsTaggedForMe();
    if (tagged.isNotEmpty) {
      final inClause = '["${tagged.join('","')}"]';
      final shared = await _list('Sales Visit',
          fields: f,
          filters: '[["custom_trip","in",$inClause]]',
          limit: 50);
      for (final v in shared) {
        byName['${v['name']}'] = v;
      }
    }
    final list = byName.values.toList();
    list.sort((a, b) => '${b['visit_date']}'.compareTo('${a['visit_date']}'));
    return list;
  }

  static Future<List<Map<String, dynamic>>> getMyOrders() => _list('Sales Order',
      fields:
      '["name","customer","grand_total","transaction_date","delivery_date","custom_proforma_status","custom_po_status","custom_production_status","custom_production_finish_date"]',
      filters: _mineFilter('custom_sales_person'),
      limit: 50);

  static Future<Map<String, dynamic>> getOrder(String name) async {
    final r = await Session.I.dio.get(_res('Sales Order') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<Map<String, dynamic>> getCustomerDoc(String name) async {
    final r = await Session.I.dio.get(_res('Customer') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<void> setOrderField(
      String name, Map<String, dynamic> body) async {
    final r =
    await Session.I.dio.put(_res('Sales Order') + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<void> uploadSignedPO({
    required String orderName,
    required String filePath,
    String? poNumber,
  }) async {
    await uploadPhoto(
        docname: orderName,
        fieldname: 'custom_po_attachment',
        filePath: filePath,
        doctype: 'Sales Order',
        filename: 'signed_po.jpg');
    final body = <String, dynamic>{
      'custom_po_status': 'PO Uploaded - Pending Approval'
    };
    if (poNumber != null && poNumber.trim().isNotEmpty) {
      body['custom_po_number'] = poNumber.trim();
    }
    await setOrderField(orderName, body);
  }

  // -------- Leads --------
  static Future<List<Map<String, dynamic>>> getLeads() {
    final rep = Session.I.salesPerson;
    final filters = (rep == null || rep.isEmpty)
        ? null
        : '[["custom_sales_person","=","$rep"]]';
    return _list('Lead',
        fields:
        '["name","lead_name","company_name","mobile_no","email_id","custom_gstin","custom_address","custom_payment_terms","territory","status"]',
        filters: filters,
        orderBy: 'creation desc');
  }

  static Future<String> createLead({
    required String leadName,
    String? company,
    String? mobile,
    String? email,
    String? gstin,
    String? address,
    String? paymentTerms,
    String? territory,
  }) async {
    final body = <String, dynamic>{
      'lead_name': leadName,
      'custom_sales_person': Session.I.salesPerson,
      'status': 'Lead',
    };
    void put(String key, String? v) {
      if (v != null && v.trim().isNotEmpty) body[key] = v.trim();
    }
    put('company_name', company);
    put('mobile_no', mobile);
    put('email_id', email);
    put('custom_gstin', gstin);
    put('custom_address', address);
    put('custom_payment_terms', paymentTerms);
    put('territory', territory);
    final r = await Session.I.dio.post(_res('Lead'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getLeadOrders({String? lead}) {
    final rep = Session.I.salesPerson;
    final f = <String>[];
    if (rep != null && rep.isNotEmpty) f.add('["sales_person","=","$rep"]');
    if (lead != null) f.add('["lead","=","$lead"]');
    final filters = f.isEmpty ? null : '[${f.join(',')}]';
    return _list('Lead Order',
        fields:
        '["name","lead","lead_name","order_date","total_amount","status","po_number"]',
        filters: filters,
        orderBy: 'creation desc');
  }

  static Future<Map<String, dynamic>> getLeadOrder(String name) async {
    final r = await Session.I.dio.get(_res('Lead Order') + '/$name');
    final d = (r.data is Map) ? r.data['data'] : null;
    if (d is Map<String, dynamic>) return d;
    throw Exception(_frappeError(r));
  }

  static Future<String> createLeadOrder({
    required String lead,
    required List<Map<String, dynamic>> items,
    required double total,
  }) async {
    final body = {
      'lead': lead,
      'sales_person': Session.I.salesPerson,
      'status': 'Pending Approval',
      'items': items,
      'total_amount': total,
    };
    final r = await Session.I.dio.post(_res('Lead Order'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> uploadLeadOrderPO({
    required String name,
    required String filePath,
    String? poNumber,
  }) async {
    await uploadPhoto(
        docname: name,
        fieldname: 'po_attachment',
        filePath: filePath,
        doctype: 'Lead Order',
        filename: 'signed_po.jpg');
    final body = <String, dynamic>{'status': 'PO Uploaded'};
    if (poNumber != null && poNumber.trim().isNotEmpty) {
      body['po_number'] = poNumber.trim();
    }
    final r = await Session.I.dio.put(_res('Lead Order') + '/$name', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<List<Map<String, dynamic>>> getMyCollections() => _list(
      'Collection Entry',
      fields: '["name","customer","amount","mode_of_payment","collection_date"]',
      filters: _mineFilter(),
      limit: 50);

  static Future<String> getCompany() async {
    final list = await _list('Company', fields: '["name"]');
    final names = list.map((e) => e['name'] as String).toList();
    return names.firstWhere((n) => !n.toLowerCase().contains('demo'),
        orElse: () => names.isNotEmpty ? names.first : '');
  }

  static Future<List<String>> getModesOfPayment() async {
    try {
      final list = await _list('Mode of Payment', fields: '["name"]');
      final modes = list.map((e) => e['name'] as String).toList();
      if (modes.isNotEmpty) return modes;
    } catch (_) {}
    return const ['Cash', 'Cheque', 'Credit Card', 'Wire Transfer', 'Bank Draft'];
  }

  static Future<String> createSalesVisit({
    required String customer,
    required String salesPerson,
    required double lat,
    required double lng,
    String purpose = 'General',
    String? trip,
    String? site,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'visit_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'customer': customer,
      'visit_purpose': purpose,
      'visit_status': 'Checked In',
      'check_in_time': stamp,
      'check_in_latitude': lat,
      'check_in_longitude': lng,
      if (trip != null && trip.isNotEmpty) 'custom_trip': trip,
      if (site != null && site.isNotEmpty) 'custom_site': site,
    };
    final r = await Session.I.dio.post(_res('Sales Visit'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<Map<String, dynamic>?> getOpenVisit(
      {String? customer, String? lead}) async {
    final rep = Session.I.salesPerson;
    if (rep == null) return null;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final party = customer != null
        ? '["customer","=","$customer"]'
        : '["custom_lead","=","$lead"]';
    final list = await _list('Sales Visit',
        fields:
        '["name","check_in_time","check_in_latitude","check_in_longitude"]',
        filters:
        '[["sales_person","=","$rep"],["visit_date","=","$today"],["check_out_time","is","not set"],$party]',
        orderBy: 'check_in_time desc',
        limit: 1);
    return list.isEmpty ? null : list.first;
  }

  static Future<String> punchInVisit(
      {String? customer,
        String? lead,
        required double lat,
        required double lng}) async {
    final rep = Session.I.salesPerson!;
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
    final body = {
      'visit_date': stamp.substring(0, 10),
      'sales_person': rep,
      if (customer != null) 'customer': customer,
      if (lead != null) 'custom_lead': lead,
      'visit_status': 'Checked In',
      'check_in_time': stamp,
      'check_in_latitude': lat,
      'check_in_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Sales Visit'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<double> punchOutVisit(
      {required String name,
        required double lat,
        required double lng,
        required String checkInTime}) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
    double mins = 0;
    try {
      final inT = DateTime.parse(checkInTime.replaceFirst(' ', 'T'));
      mins = DateTime.now().difference(inT).inSeconds / 60.0;
    } catch (_) {}
    await _put('Sales Visit', name, {
      'check_out_time': stamp,
      'check_out_latitude': lat,
      'check_out_longitude': lng,
      'custom_duration_minutes': double.parse(mins.toStringAsFixed(1)),
      'visit_status': 'Completed',
    });
    return mins;
  }

  static Future<String> createSalesOrder({
    required String customer,
    required String company,
    required List<Map<String, dynamic>> items,
    String? deliveryDate,
  }) async {
    final body = {
      'customer': customer,
      'company': company,
      'custom_sales_person': Session.I.salesPerson,
      if (Session.I.company != null && Session.I.company!.isNotEmpty)
        'custom_company': Session.I.company,
      'delivery_date': deliveryDate ??
          DateTime.now()
              .add(const Duration(days: 7))
              .toIso8601String()
              .substring(0, 10),
      'items': items,
    };
    final r = await Session.I.dio.post(_res('Sales Order'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<String> createComplaint({
    required String customer,
    required String complaintType,
    required String description,
  }) async {
    final body = {
      'customer': customer,
      'sales_person': Session.I.salesPerson,
      'complaint_type': complaintType,
      'description': description,
      'status': 'Open',
    };
    final r = await Session.I.dio.post(_res('Customer Complaint'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<String> createCollectionEntry({
    required String customer,
    required String salesPerson,
    required double amount,
    required String mode,
    String? referenceNo,
    required double lat,
    required double lng,
  }) async {
    final body = {
      'collection_date': today(),
      'sales_person': salesPerson,
      'customer': customer,
      'amount': amount,
      'mode_of_payment': mode,
      if (referenceNo != null && referenceNo.isNotEmpty)
        'reference_no': referenceNo,
      'latitude': lat,
      'longitude': lng,
      'status': 'Collected',
    };
    final r = await Session.I.dio.post(_res('Collection Entry'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // -------- Trips (rich model) --------
  static Future<List<Map<String, dynamic>>> getMyTrips() async {
    final me = Session.I.salesPerson;
    const f =
        '["name","trip_date","purpose","status","total_distance_km","odometer_distance_km","primary_mode","start_odometer","end_odometer","sales_person"]';
    final owned = await _list('Trip',
        fields: f,
        filters: '[["sales_person","=","$me"],["status","!=","Cancelled"]]',
        orderBy: 'trip_date desc',
        limit: 100);
    final byName = <String, Map<String, dynamic>>{};
    for (final t in owned) {
      t['_shared'] = false;
      byName['${t['name']}'] = t;
    }
    final shared = await _list('Trip',
        fields: f,
        filters: '[["tagged_csv","like","%|$me|%"],["status","!=","Cancelled"]]',
        orderBy: 'trip_date desc',
        limit: 100);
    for (final t in shared) {
      final n = '${t['name']}';
      if (!byName.containsKey(n)) {
        t['_shared'] = true;
        byName[n] = t;
      }
    }
    final list = byName.values.toList();
    list.sort((a, b) => '${b['trip_date']}'.compareTo('${a['trip_date']}'));
    return list;
  }

  static Future<Map<String, dynamic>?> getTrip(String name) async {
    final r =
    await Session.I.dio.get('${_res('Trip')}/${Uri.encodeComponent(name)}');
    if (r.data is Map && r.data['data'] is Map) {
      return Map<String, dynamic>.from(r.data['data']);
    }
    return null;
  }

  static Future<String> createTrip({
    required String tripDate,
    required String purpose,
    double startOdometer = 0,
    double? lat,
    double? lng,
  }) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'sales_person': Session.I.salesPerson,
      'trip_date': tripDate,
      'purpose': purpose,
      'status': 'Active',
      'start_time': now,
      'start_odometer': startOdometer,
      if (lat != null) 'start_latitude': lat,
      if (lng != null) 'start_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Trip'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> endTrip({
    required String name,
    double? lat,
    double? lng,
  }) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'status': 'Completed',
      'end_time': now,
      if (lat != null) 'end_latitude': lat,
      if (lng != null) 'end_longitude': lng,
    };
    await _put('Trip', name, body);
  }

  static Future<void> cancelTrip(String name) async {
    final now =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    await _put('Trip', name, {'status': 'Cancelled', 'end_time': now});
  }

  static Future<void> updateTrip(String name, Map<String, dynamic> body) =>
      _put('Trip', name, body);

  // ---- Trip rates (office-controlled, single-doctype) ----
  static Future<Map<String, dynamic>> getTripRates() async {
    final r = await Session.I.dio
        .get('${_res('Trip Rate Settings')}/Trip Rate Settings');
    if (r.data is Map && r.data['data'] is Map) {
      return Map<String, dynamic>.from(r.data['data']);
    }
    return {};
  }

  static Future<void> saveTripRates(Map<String, dynamic> body) =>
      _put('Trip Rate Settings', 'Trip Rate Settings', body);

  static double rateForMode(Map<String, dynamic> rates, String? mode) {
    double g(String k) => (rates[k] is num) ? (rates[k] as num).toDouble() : 0.0;
    switch (mode) {
      case 'Own Vehicle':
        return g('rate_own_car');
      case 'Bike':
        return g('rate_own_bike');
      case 'Company Vehicle (Car)':
        return g('rate_company_car');
      case 'Company Vehicle (Bike)':
        return g('rate_company_bike');
      case 'Company Vehicle': // legacy
        return g('rate_company_car');
      case 'Bus':
      case 'Taxi':
      case 'Mixed':
        return 0;
      default:
        return 0;
    }
  }

  static double _legDist(Map l) {
    final hasOdo = (l['has_odometer'] ?? 1) == 1;
    final s = (l['start_odometer'] is num)
        ? (l['start_odometer'] as num).toDouble()
        : 0.0;
    final e =
    (l['end_odometer'] is num) ? (l['end_odometer'] as num).toDouble() : 0.0;
    if (hasOdo && e > s) return e - s;
    return (l['leg_distance_km'] is num)
        ? (l['leg_distance_km'] as num).toDouble()
        : 0.0;
  }

  // Replace the trip's vehicle legs and recompute distance + cost estimate.
  static Future<void> saveTripLegs(
      String tripName, List<Map<String, dynamic>> legs) async {
    final rates = await getTripRates();
    double total = 0, odo = 0, est = 0;
    final modes = <String>{};
    final clean = <Map<String, dynamic>>[];
    for (final l in legs) {
      final d = _legDist(l);
      total += d;
      if ((l['has_odometer'] ?? 1) == 1) odo += d;
      est += d * rateForMode(rates, l['mode'] as String?);
      if (l['mode'] == 'Mixed') {
        est += ((l['claimed_amount'] ?? 0) as num).toDouble();
      }
      if (l['mode'] != null) modes.add('${l['mode']}');
      clean.add({
        if (l['name'] != null) 'name': l['name'],
        'mode': l['mode'],
        'vehicle_no': l['vehicle_no'],
        'has_odometer': l['has_odometer'] ?? 1,
        'start_odometer': l['start_odometer'] ?? 0,
        'end_odometer': l['end_odometer'] ?? 0,
        'leg_distance_km': d,
        'claimed_amount': l['claimed_amount'] ?? 0,
        'custom_approved_amount': l['custom_approved_amount'] ?? 0,
        'status': l['status'] ?? 'Pending',
        'custom_approval_remarks': l['custom_approval_remarks'],
        'custom_not_verified': l['custom_not_verified'] ?? 0,
        'custom_actual_start_odometer': l['custom_actual_start_odometer'] ?? 0,
        'custom_actual_end_odometer': l['custom_actual_end_odometer'] ?? 0,
        'start_odometer_photo': l['start_odometer_photo'],
        'end_odometer_photo': l['end_odometer_photo'],
        'remarks': l['remarks'],
      });
    }
    final body = <String, dynamic>{
      'legs': clean,
      'odometer_distance_km': odo,
      'total_distance_km': total,
      'estimated_cost': est,
      'primary_mode':
      modes.isEmpty ? null : (modes.length == 1 ? modes.first : 'Mixed'),
      'cost_basis': odo > 0 ? 'Odometer' : 'GPS Distance',
    };
    await _put('Trip', tripName, body);
  }

  // Upload a file attached to a parent doc, return its file_url (for child rows).
  static Future<String?> uploadFileGetUrl({
    required String filePath,
    String? doctype,
    String? docname,
    String filename = 'bill.jpg',
  }) async {
    final map = <String, dynamic>{
      'file': await MultipartFile.fromFile(filePath, filename: filename),
      'is_private': 1,
    };
    if (doctype != null) map['doctype'] = doctype;
    if (docname != null) map['docname'] = docname;
    final r =
    await Session.I.dio.post('/api/method/upload_file', data: FormData.fromMap(map));
    if (r.statusCode == 200 || r.statusCode == 201) {
      final d = r.data;
      if (d is Map && d['message'] is Map) {
        return d['message']['file_url'] as String?;
      }
    }
    return null;
  }

  static Future<void> saveTripExpenses(
      String tripName, List<Map<String, dynamic>> expenses) async {
    double total = 0;
    final clean = expenses.map((e) {
      if (e['amount'] is num) total += (e['amount'] as num).toDouble();
      return {
        if (e['name'] != null) 'name': e['name'],
        'category': e['category'],
        'expense_name': e['expense_name'],
        'amount': e['amount'] ?? 0,
        'has_bill': e['has_bill'] ?? 0,
        'bill_photo': e['bill_photo'],
        'status': e['status'] ?? 'Pending',
        'custom_approved_amount': e['custom_approved_amount'] ?? 0,
        'custom_approval_remarks': e['custom_approval_remarks'],
        'remarks': e['remarks'],
      };
    }).toList();
    await _put(
        'Trip', tripName, {'expenses': clean, 'total_expenses': total});
  }

  // HR: all trips with expense totals + tagged members.
  static Future<List<Map<String, dynamic>>> getAllTripsForHR() => _list('Trip',
      fields:
      '["name","trip_date","purpose","status","sales_person","estimated_cost","final_cost","total_expenses","total_distance_km","tagged_csv"]',
      orderBy: 'trip_date desc',
      limit: 200);

  static Future<List<Map<String, dynamic>>> getTrips() => _list('Trip Log',
      fields:
      '["name","sales_person","vehicle_no","trip_date","start_odometer","end_odometer","distance_km"]',
      filters: _mineFilter(),
      limit: 50);

  static Future<String> createTripStart({
    required String salesPerson,
    required String vehicleNo,
    required double startOdo,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'trip_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'vehicle_no': vehicleNo,
      'start_time': stamp,
      'start_odometer': startOdo,
      'start_latitude': lat,
      'start_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Trip Log'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<void> tripEnd({
    required String tripName,
    required double startOdo,
    required double endOdo,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'end_time': stamp,
      'end_odometer': endOdo,
      'distance_km': endOdo - startOdo,
      'end_latitude': lat,
      'end_longitude': lng,
    };
    final r = await Session.I.dio
        .put('${_res('Trip Log')}/${Uri.encodeComponent(tripName)}', data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<void> captureCustomerLocation({
    required String customer,
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'custom_latitude': lat,
      'custom_longitude': lng,
      'custom_location_status': 'Pending Verification',
      'custom_location_captured_by': salesPerson,
      'custom_location_captured_on': stamp,
    };
    final r = await Session.I.dio.put(
        '${_res('Customer')}/${Uri.encodeComponent(customer)}',
        data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<void> uploadPhoto({
    required String docname,
    required String fieldname,
    required String filePath,
    String doctype = 'Trip Log',
    String filename = 'photo.jpg',
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: filename),
      'doctype': doctype,
      'docname': docname,
      'fieldname': fieldname,
      'is_private': 1,
    });
    final r = await Session.I.dio.post('/api/method/upload_file', data: form);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  // -------- Attendance --------
  static Future<List<Map<String, dynamic>>> getTodayAttendance(
      String salesPerson) =>
      _list('Attendance Log',
          fields:
          '["name","sales_person","attendance_date","status","punch_in_time","punch_out_time","working_hours"]',
          filters:
          '[["sales_person","=","$salesPerson"],["attendance_date","=","${today()}"]]',
          limit: 1);

  // ---- Attendance calendar + regularization ----
  static String _monthBounds(int year, int month, bool last) {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    if (!last) return '$y-$m-01';
    final lastDay = DateTime(year, month + 1, 0).day;
    return '$y-$m-${lastDay.toString().padLeft(2, '0')}';
  }

  static Future<List<Map<String, dynamic>>> getAttendanceForMonth(
      String rep, int year, int month) {
    return _list('Attendance Log',
        fields:
        '["name","attendance_date","punch_in_time","punch_out_time","working_hours","status"]',
        filters:
        '[["sales_person","=","$rep"],["attendance_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'attendance_date asc');
  }

  static Future<List<Map<String, dynamic>>> getRegularizationsForMonth(
      String rep, int year, int month) {
    return _list('Attendance Regularization',
        fields:
        '["name","attendance_date","status","requested_punch_in","requested_punch_out","reason"]',
        filters:
        '[["sales_person","=","$rep"],["attendance_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'attendance_date asc');
  }

  static Future<String> myTeamManager() async {
    final me = Session.I.salesPerson;
    if (me == null) return '';
    final sp = await _list('Sales Person',
        fields: '["custom_team_manager"]',
        filters: '[["name","=","$me"]]',
        limit: 1);
    return sp.isNotEmpty
        ? (sp.first['custom_team_manager'] ?? '').toString()
        : '';
  }

  static Future<void> createRegularization({
    required String attendanceDate,
    required String? punchIn,
    required String? punchOut,
    required String reason,
  }) async {
    final isMgr = Session.I.isManager;
    final body = {
      'sales_person': Session.I.salesPerson,
      'attendance_date': attendanceDate,
      'requested_punch_in': punchIn,
      'requested_punch_out': punchOut,
      'reason': reason,
      'requester_is_manager': isMgr ? 1 : 0,
      'team_manager': await myTeamManager(),
      'approver_type': isMgr ? 'HR' : 'Sales Manager',
      'status': 'Pending Approval',
    };
    final r =
    await Session.I.dio.post(_res('Attendance Regularization'), data: body);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception(_frappeError(r));
    }
  }

  static Future<List<Map<String, dynamic>>>
  getPendingRegularizationsForManager() {
    final team = Session.I.managedTeam;
    if (team == null || team.isEmpty) return Future.value([]);
    return _list('Attendance Regularization',
        fields:
        '["name","sales_person","attendance_date","requested_punch_in","requested_punch_out","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","Sales Manager"],["team_manager","=","$team"]]',
        orderBy: 'attendance_date asc');
  }

  static Future<List<Map<String, dynamic>>> getPendingRegularizationsForHR() {
    return _list('Attendance Regularization',
        fields:
        '["name","sales_person","attendance_date","requested_punch_in","requested_punch_out","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","HR"]]',
        orderBy: 'attendance_date asc');
  }

  static Future<void> approveRegularization(
      Map<String, dynamic> reg, bool approve) async {
    final name = reg['name'] as String;
    if (!approve) {
      await _put('Attendance Regularization', name,
          {'status': 'Rejected', 'decided_by': Session.I.email});
      return;
    }
    final rep = reg['sales_person'] as String;
    final date = reg['attendance_date'] as String;
    final pin = reg['requested_punch_in'];
    final pout = reg['requested_punch_out'];
    double hours = 0;
    try {
      if (pin != null && pout != null) {
        final a = DateTime.parse('$pin'.replaceFirst(' ', 'T'));
        final b = DateTime.parse('$pout'.replaceFirst(' ', 'T'));
        hours = b.difference(a).inMinutes / 60.0;
        if (hours < 0) hours = 0;
      }
    } catch (_) {}
    hours = double.parse(hours.toStringAsFixed(2));
    final logBody = {
      'punch_in_time': pin,
      'punch_out_time': pout,
      'working_hours': hours,
      'status': pout != null ? 'Punched Out' : 'Punched In',
    };
    final existing = await _list('Attendance Log',
        fields: '["name"]',
        filters: '[["sales_person","=","$rep"],["attendance_date","=","$date"]]',
        limit: 1);
    if (existing.isNotEmpty) {
      await _put('Attendance Log', existing.first['name'] as String, logBody);
    } else {
      await Session.I.dio.post(_res('Attendance Log'),
          data: {'sales_person': rep, 'attendance_date': date, ...logBody});
    }
    await _put('Attendance Regularization', name,
        {'status': 'Approved', 'decided_by': Session.I.email});
  }

  // Missed punch-out yesterday (punched in, never out) -> alert next morning.
  static Future<Map<String, dynamic>?> getMissedPunchYesterday() async {
    final me = Session.I.salesPerson;
    if (me == null) return null;
    final y = DateTime.now().subtract(const Duration(days: 1));
    final ds =
        '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
    final list = await _list('Attendance Log',
        fields: '["name","attendance_date","punch_in_time","punch_out_time"]',
        filters: '[["sales_person","=","$me"],["attendance_date","=","$ds"]]',
        limit: 1);
    if (list.isEmpty) return null;
    final r = list.first;
    if (r['punch_in_time'] != null && r['punch_out_time'] == null) return r;
    return null;
  }

  static Future<String> punchIn({
    required String salesPerson,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'attendance_date': stamp.substring(0, 10),
      'sales_person': salesPerson,
      'status': 'Punched In',
      'punch_in_time': stamp,
      'punch_in_latitude': lat,
      'punch_in_longitude': lng,
    };
    final r = await Session.I.dio.post(_res('Attendance Log'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<double> punchOut({
    required String name,
    required String punchInTime,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    double hours = 0;
    try {
      final tin = DateTime.parse(punchInTime.replaceFirst(' ', 'T'));
      hours = DateTime.now().difference(tin).inMinutes / 60.0;
      if (hours < 0) hours = 0;
    } catch (_) {}
    hours = double.parse(hours.toStringAsFixed(2));
    final body = {
      'punch_out_time': stamp,
      'punch_out_latitude': lat,
      'punch_out_longitude': lng,
      'working_hours': hours,
      'status': 'Punched Out',
    };
    final r = await Session.I.dio.put(
        '${_res('Attendance Log')}/${Uri.encodeComponent(name)}',
        data: body);
    if (r.statusCode == 200 || r.statusCode == 201) return hours;
    throw Exception(_frappeError(r));
  }

  // -------- Expenses --------
  static Future<List<Map<String, dynamic>>> getMyExpenses() => _list(
      'Expense Entry',
      fields:
      '["name","sales_person","expense_date","category","amount","status","remarks"]',
      filters: _mineFilter(),
      limit: 50);

  static Future<String> createExpense({
    required String salesPerson,
    required String category,
    required double amount,
    String? remarks,
  }) async {
    final body = {
      'expense_date': today(),
      'sales_person': salesPerson,
      'category': category,
      'amount': amount,
      'status': 'Pending',
      if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
    };
    final r = await Session.I.dio.post(_res('Expense Entry'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  // -------- Day map (rep's day plotted on a map) --------
  // Read-only: uses coordinate fields already written by check-in, punch and
  // trip start/end. No backend changes needed.
  static Future<List<Map<String, dynamic>>> getVisitsForDay(
      String rep, String date) =>
      _list('Sales Visit',
          fields:
          '["name","customer","visit_date","visit_status","check_in_time","check_in_latitude","check_in_longitude"]',
          filters: '[["sales_person","=","$rep"],["visit_date","=","$date"]]',
          orderBy: 'check_in_time asc');

  static Future<List<Map<String, dynamic>>> getAttendanceForDay(
      String rep, String date) =>
      _list('Attendance Log',
          fields:
          '["name","attendance_date","punch_in_time","punch_out_time","punch_in_latitude","punch_in_longitude","punch_out_latitude","punch_out_longitude"]',
          filters:
          '[["sales_person","=","$rep"],["attendance_date","=","$date"]]',
          limit: 10);

  static Future<List<Map<String, dynamic>>> getTripsForDay(
      String rep, String date) =>
      _list('Trip',
          fields:
          '["name","purpose","trip_date","start_time","end_time","start_latitude","start_longitude","end_latitude","end_longitude"]',
          filters: '[["sales_person","=","$rep"],["trip_date","=","$date"]]',
          orderBy: 'creation asc');

  // Reps the current user may view on the day map.
  // HR / GM: everyone. Plain manager: their team (plus self if they're a rep).
  static Future<List<Map<String, dynamic>>> getPickableReps() async {
    if (Session.I.isHR || Session.I.isGM) {
      final list = await _list('Sales Person',
          fields: '["name","sales_person_name"]',
          filters: '[["is_group","=",0]]',
          orderBy: 'name asc');
      return list
          .map((e) => {
        'name': e['name'],
        'label': (e['sales_person_name'] ?? e['name']),
      })
          .toList();
    }
    final me = Session.I.salesPerson;
    final reps = <Map<String, dynamic>>[];
    if (me != null && me.isNotEmpty && !Session.I.teamReps.contains(me)) {
      reps.add({'name': me, 'label': Session.I.salesPersonLabel ?? me});
    }
    reps.addAll(Session.I.teamReps.map((r) => {'name': r, 'label': r}));
    return reps;
  }

  // Append one GPS point to a trip's route (read-modify-write the child list,
  // same pattern as legs/expenses). Used by the 20-min route tracker.
  static Future<void> appendTripGpsPoint(
      String tripName, double lat, double lng) async {
    final trip = await getTrip(tripName);
    final existing =
    ((trip?['gps_points'] as List?) ?? []).cast<Map<String, dynamic>>();
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
    final rows = existing
        .map((p) => {
      if (p['name'] != null) 'name': p['name'],
      'timestamp': p['timestamp'],
      'latitude': p['latitude'],
      'longitude': p['longitude'],
    })
        .toList();
    rows.add({'timestamp': stamp, 'latitude': lat, 'longitude': lng});
    await _put('Trip', tripName, {'gps_points': rows});
  }

  // -------- Leave (financial-year allowance of 12 days) --------
  static Future<List<Map<String, dynamic>>> getMyLeaves() => _list(
      'Leave Request',
      fields:
      '["name","leave_date","half_day","half_day_period","leave_days","reason","status","approver_type","is_hr_entry"]',
      filters: _mineFilter('sales_person'),
      orderBy: 'leave_date desc',
      limit: 100);

  // Balance in the current financial year: allowance 12 minus approved days.
  static Future<Map<String, double>> getLeaveBalance(String rep) async {
    final fy = financialYear(DateTime.now());
    final list = await _list('Leave Request',
        fields: '["leave_days","status"]',
        filters:
        '[["sales_person","=","$rep"],["leave_date","between",["${fy.start}","${fy.end}"]]]',
        limit: 0);
    double taken = 0, pending = 0;
    for (final e in list) {
      final d = ((e['leave_days'] ?? 0) as num).toDouble();
      final s = '${e['status']}';
      if (s == 'Approved') {
        taken += d;
      } else if (s == 'Pending Approval') {
        pending += d;
      }
    }
    return {
      'allowance': 12,
      'taken': taken,
      'pending': pending,
      'remaining': 12 - taken,
    };
  }

  static Future<String> createLeaveRequest({
    required String leaveDate,
    required bool halfDay,
    String? halfPeriod,
    required String reason,
  }) async {
    final isMgr = Session.I.isManager;
    final body = {
      'sales_person': Session.I.salesPerson,
      'leave_date': leaveDate,
      'half_day': halfDay ? 1 : 0,
      if (halfDay) 'half_day_period': halfPeriod ?? 'Morning',
      'leave_days': halfDay ? 0.5 : 1,
      'reason': reason,
      'status': 'Pending Approval',
      'approver_type': isMgr ? 'HR' : 'Sales Manager',
      'team_manager': await myTeamManager(),
      'requester_is_manager': isMgr ? 1 : 0,
    };
    final r = await Session.I.dio.post(_res('Leave Request'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getPendingLeaveForManager() {
    final team = Session.I.managedTeam;
    if (team == null || team.isEmpty) return Future.value([]);
    return _list('Leave Request',
        fields:
        '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status"]',
        filters:
        '[["status","=","Pending Approval"],["approver_type","=","Sales Manager"],["team_manager","=","$team"]]',
        orderBy: 'leave_date asc');
  }

  static Future<List<Map<String, dynamic>>> getPendingLeaveForHR() =>
      _list('Leave Request',
          fields:
          '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status"]',
          filters:
          '[["status","=","Pending Approval"],["approver_type","=","HR"]]',
          orderBy: 'leave_date asc');

  // Rep leaves (decided by their sales manager) - HR sees these read-only.
  static Future<List<Map<String, dynamic>>> getTeamLeavesForHR() => _list(
      'Leave Request',
      fields:
      '["name","sales_person","leave_date","half_day","half_day_period","leave_days","reason","status","team_manager"]',
      filters: '[["approver_type","=","Sales Manager"]]',
      orderBy: 'leave_date desc',
      limit: 40);

  static Future<void> approveLeave(String name, bool approve) => _put(
      'Leave Request',
      name,
      {'status': approve ? 'Approved' : 'Rejected', 'decided_by': Session.I.email});

  static Future<String> hrCreateLeave({
    required String rep,
    required String leaveDate,
    required bool halfDay,
    String? halfPeriod,
    required String reason,
  }) async {
    final body = {
      'sales_person': rep,
      'leave_date': leaveDate,
      'half_day': halfDay ? 1 : 0,
      if (halfDay) 'half_day_period': halfPeriod ?? 'Morning',
      'leave_days': halfDay ? 0.5 : 1,
      'reason': reason,
      'status': 'Approved',
      'approver_type': 'HR',
      'is_hr_entry': 1,
      'decided_by': Session.I.email,
    };
    final r = await Session.I.dio.post(_res('Leave Request'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getLeavesForMonth(
      String rep, int year, int month) {
    return _list('Leave Request',
        fields:
        '["leave_date","half_day","half_day_period","leave_days","status"]',
        filters:
        '[["sales_person","=","$rep"],["status","=","Approved"],["leave_date","between",["${_monthBounds(year, month, false)}","${_monthBounds(year, month, true)}"]]]',
        orderBy: 'leave_date asc');
  }

  // -------- Customer sites (multiple verified locations per customer) --------
  static Future<List<Map<String, dynamic>>> getCustomerSites(
      String customer) =>
      _list('Customer Site',
          fields:
          '["name","site_name","latitude","longitude","verified_latitude","verified_longitude","location_status"]',
          filters: '[["customer","=","$customer"]]',
          orderBy: 'creation asc',
          limit: 0);

  static Future<String> createCustomerSite({
    required String customer,
    required String siteName,
    required double lat,
    required double lng,
  }) async {
    final stamp =
    DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    final body = {
      'customer': customer,
      'site_name': siteName,
      'latitude': lat,
      'longitude': lng,
      'location_status': 'Pending Verification',
      'captured_by': Session.I.salesPerson,
      'captured_on': stamp,
    };
    final r = await Session.I.dio.post(_res('Customer Site'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getPendingSiteVerifications() {
    final team = Session.I.teamReps;
    if (team.isEmpty) return Future.value([]);
    return _list('Customer Site',
        fields:
        '["name","site_name","customer","captured_by","latitude","longitude","banner_photo"]',
        filters:
        '[["location_status","=","Pending Verification"],["captured_by","in",${_inList(team)}]]',
        orderBy: 'modified desc');
  }

  static Future<void> approveSite(
      String name, bool approve, dynamic lat, dynamic lng) {
    if (approve) {
      return _put('Customer Site', name, {
        'location_status': 'Verified',
        'verified_latitude': lat,
        'verified_longitude': lng,
      });
    }
    return _put('Customer Site', name, {'location_status': 'Rejected'});
  }

  // Approved POs (ready for SAP) for the logged-in production manager's unit.
  static Future<List<Map<String, dynamic>>> getApprovedPOsForProduction() {
    final unit = Session.I.productionCompany;
    if (unit == null || unit.isEmpty) return Future.value([]);
    return _list('Sales Order',
        fields:
        '["name","customer","customer_name","grand_total","transaction_date","delivery_date","custom_po_number","custom_sales_person","custom_production_status","custom_production_finish_date"]',
        filters:
        '[["custom_company","=","$unit"],["custom_po_status","=","PO Approved - Ready for SAP"]]',
        orderBy: 'transaction_date desc',
        limit: 100);
  }

  static Future<void> setProductionStatus({
    required String orderName,
    required String status,
    String? finishDate,
  }) async {
    await _put('Sales Order', orderName, {
      'custom_production_status': status,
      'custom_production_finish_date': finishDate,
    });
  }

  static Future<String> createRetreadProforma({
    required String customer,
    String? customerName,
    required List<Map<String, dynamic>> rates,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'customer': customer,
      if (customerName != null && customerName.isNotEmpty)
        'customer_name': customerName,
      'sales_rep': Session.I.salesPerson,
      'proforma_date': today(),
      'status': 'Shared',
      'rates': rates,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
    final r = await Session.I.dio.post(_res('Retread Proforma'), data: body);
    if (r.statusCode == 200 || r.statusCode == 201) {
      return r.data['data']['name'] as String;
    }
    throw Exception(_frappeError(r));
  }

  static Future<List<Map<String, dynamic>>> getMyRetreadProformas() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Proforma',
        fields: '["name","customer","customer_name","proforma_date","status"]',
        filters: '[["sales_rep","=","$me"]]',
        orderBy: 'proforma_date desc');
  }

  static Future<Map<String, dynamic>> getRetreadProforma(String name) async {
    final r = await Session.I.dio.get('${_res('Retread Proforma')}/$name');
    return (r.data['data'] as Map).cast<String, dynamic>();
  }

  static Future<void> supersedeProforma(String name) =>
      _put('Retread Proforma', name, {'status': 'Superseded'});

  static Future<List<Map<String, dynamic>>> getMyReadyTyres() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Tyre',
        fields:
        '["name","customer","customer_name","tyre_size","tyre_brand","retread_type","tread_pattern","tyre_number","proforma"]',
        filters: '[["sales_rep","=","$me"],["status","=","Ready"]]',
        orderBy: 'customer asc');
  }

  static Future<void> placeRetreadOrder(
      List<String> tyreNames, Map<String, double> rateByName) async {
    final orderRef = 'RO-${DateTime.now().millisecondsSinceEpoch}';
    final orderDate = today();
    for (final n in tyreNames) {
      await _put('Retread Tyre', n, {
        'status': 'Ordered',
        'rate': rateByName[n] ?? 0,
        'order_ref': orderRef,
        'order_date': orderDate,
      });
    }
  }

  static Future<List<Map<String, dynamic>>> getMyRetreadOrderedTyres() {
    final me = Session.I.salesPerson;
    if (me == null) return Future.value([]);
    return _list('Retread Tyre',
        fields:
        '["name","customer","customer_name","tyre_size","retread_type","tyre_number","rate","status","order_ref","order_date","delivery_date","vehicle"]',
        filters:
        '[["sales_rep","=","$me"],["status","in",["Ordered","Scheduled","Delivered","Invoiced"]]]',
        orderBy: 'order_date desc');
  }

  static String _frappeError(Response r) {
    try {
      final d = r.data;
      if (d is Map &&
          d['exception'] != null &&
          d['_server_messages'] == null) {
        var ex = d['exception'].toString();
        if (ex.contains(':')) ex = ex.split(':').last.trim();
        return ex.length > 160 ? ex.substring(0, 160) : ex;
      }
      if (d is Map && d['_server_messages'] != null) {
        final msgs = jsonDecode(d['_server_messages']) as List;
        return msgs.map((m) => jsonDecode(m)['message']).join('\n');
      }
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }
}

