import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Reduced cases from the real repositories listed in doc/validation.md.
void main() {
  CodeIndex project(String source) {
    final root = Directory.systemTemp.createTempSync('fcq_oss_');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/lib/app.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(source);
    return CodeIndex.build(root.path);
  }

  List<Map> candidates(CodeIndex index, String route) =>
      (query(index, route)['candidates'] as List).cast<Map>();

  test('namedLocation keeps paths from alternative router configurations', () {
    final index = project(r'''
final router = GoRouter(routes: [
  if (mobile)
    GoRoute(path: '/settings/logs', name: 'logs')
  else
    GoRoute(path: '/logs', name: 'logs'),
]);

class Tile extends StatelessWidget {
  const Tile({required this.location});
  final String location;
  Widget build(BuildContext context) =>
      ListTile(onTap: () => context.go(location));
}

class Settings extends StatelessWidget {
  Widget build(BuildContext context) =>
      Tile(location: context.namedLocation('logs'));
}
''');
    for (final route in ['/settings/logs', '/logs']) {
      final candidate = candidates(index, route).single;
      expect(candidate['root'], containsPair('slot', 'onTap'));
      expect(candidate['destination'], containsPair('value', route));
      expect(candidate['destination'], containsPair('alternative', true));
    }
    expect(candidates(index, 'logs'), hasLength(2));
    expect(check(index)['findings'], isEmpty);
  });

  test('goBranch expands spreads and keeps conditional indices uncertain', () {
    final index = project(r'''
final tail = [
  StatefulShellBranch(routes: [GoRoute(path: '/logs')]),
  StatefulShellBranch(routes: [GoRoute(path: '/about')]),
];
final router = GoRouter(routes: [
  StatefulShellRoute.indexedStack(branches: [
    StatefulShellBranch(routes: [GoRoute(path: '/home')]),
    if (showProfiles)
      StatefulShellBranch(routes: [GoRoute(path: '/profiles')]),
    StatefulShellBranch(routes: [GoRoute(path: '/settings')]),
    if (desktop) ...tail,
  ]),
]);

class Tabs extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
    Bar(onDestinationSelected: (index) => shell.goBranch(index)),
    Button(onPressed: () => shell.goBranch(0)),
    Button(onPressed: () => shell.goBranch(2)),
    Button(onPressed: () => shell.goBranch(3)),
  ]);
}
''');
    final about = candidates(index, '/about');
    expect(about, hasLength(2));
    expect(about.first['destination'], containsPair('branch', 'any'));
    expect(about.last['destination'], containsPair('branch', 3));
    expect(about.last['destination'], containsPair('alternative', true));
    final home = candidates(index, '/home');
    expect(home, hasLength(2));
    expect(home.last['destination'], containsPair('branch', 0));
    expect(home.last['destination'], isNot(contains('alternative')));
    expect(candidates(index, '/profiles'), hasLength(1));
    expect(candidates(index, '/settings'), hasLength(2));
    expect(candidates(index, '/logs'), hasLength(3));
    expect(check(index)['findings'], isEmpty);
  });

  test('goBranch preserves indices through unconditional spreads', () {
    final index = project(r'''
final extra = [
  StatefulShellBranch(routes: [GoRoute(path: '/logs')]),
  StatefulShellBranch(routes: [GoRoute(path: '/about')]),
];
final router = GoRouter(routes: [
  StatefulShellRoute.indexedStack(branches: [
    StatefulShellBranch(routes: [GoRoute(path: '/home')]),
    ...extra,
  ]),
]);
void open(BuildContext context) => shell.goBranch(2);
''');
    expect(candidates(index, '/home'), isEmpty);
    expect(candidates(index, '/logs'), isEmpty);
    expect(candidates(index, '/about').single['destination'],
        {'expression': '2', 'branch': 2});
  });

  test('routes exposes parse errors instead of appearing complete', () {
    final index = project(
        "final router = GoRouter(routes: [GoRoute(path: '/x')]);\nvoid broken( {");
    final result = routeList(index);
    expect(result['routes'], hasLength(1));
    expect(result['parseErrors'], query(index, '/x')['parseErrors']);
    expect(result['parseErrors'], isNotEmpty);
  });
}
