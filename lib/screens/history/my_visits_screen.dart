
import 'package:flutter/material.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/widgets/history_list.dart';

class MyVisitsScreen extends StatelessWidget {
  const MyVisitsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final me = Session.I.salesPerson;
    return HistoryList(
      title: 'My Visits',
      loader: Api.getMyVisitsIncludingTagged,
      tileBuilder: (_, r) {
        final by = '${r['sales_person'] ?? ''}';
        final shared = by.isNotEmpty && by != me;
        return ListTile(
          leading: Icon(shared ? Icons.group : Icons.location_on,
              color: shared ? const Color(0xFFF46A21) : null),
          title: Text(r['customer'] ?? r['name']),
          subtitle: Text(
              '${r['visit_date'] ?? ''}  ·  ${r['visit_status'] ?? ''}'
                  '${shared ? '  ·  logged by $by' : ''}'),
          trailing: shared
              ? const Chip(
              label: Text('Shared', style: TextStyle(fontSize: 10)),
              visualDensity: VisualDensity.compact,
              backgroundColor: Color(0xFFFFE8DC))
              : Text(r['name'] ?? ''),
        );
      },
    );
  }
}

