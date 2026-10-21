import 'dart:convert';
import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';

// Run from the package root: dart run example/example.dart
void main() {
  final app =
      Directory.systemTemp.createTempSync('flutter_code_query_example_');
  try {
    // This source is parsed, never executed: Flutter and go_router are not
    // needed to run the example.
    File('${app.path}/lib/app.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
final router = GoRouter(routes: [
  GoRoute(path: '/', name: 'home'),
  GoRoute(path: '/settings', name: 'settings'),
]);

class HomeScreen extends StatelessWidget {
  Widget build(BuildContext context) => TextButton(
    onPressed: () => context.goNamed('settings'),
    child: const Text('Settings'),
  );
}
''');

    final index = CodeIndex.build(app.path);
    const json = JsonEncoder.withIndent('  ');

    print('Registered routes:');
    print(json.convert(routeList(index)));

    print('Controls that can reach /settings:');
    print(json.convert(query(index, '/settings')));

    print('Navigation findings:');
    print(json.convert(check(index)));
  } finally {
    app.deleteSync(recursive: true);
  }
}
