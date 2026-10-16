import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

void main() {
  final index = CodeIndex.build('test/fixture');

  List<Map> findings(String name) => [
        for (final f in check(index)['findings'] as List)
          if ((f as Map)['check'] == name) f,
      ];

  test('joins nested route paths and skips generated files', () {
    final routes = [
      for (final r in routeList(index)['routes'] as List) (r as Map)['path'],
    ];
    expect(routes, [
      '/home',
      '/home/items/:id',
      '/detail',
      '/orphan',
      '/settings',
      '/login',
      '/profile',
      '/help',
      '/detail',
    ]);
  });

  test('forwards arguments through helpers and keeps both phases of conditions',
      () {
    final result = query(index, '/detail');
    final candidates = result['candidates'] as List;
    expect(candidates, hasLength(1));
    final candidate = candidates.single as Map;
    expect(candidate['root'], {
      'kind': 'callback',
      'slot': 'onPressed',
      'at': 'lib/home_screen.dart:18',
      'symbol': 'HomeScreen.build',
    });
    expect([for (final h in candidate['hops'] as List) (h as Map)['symbol']],
        ['HomeScreen.build', 'HomeScreen._openDetail', 'navigateTo']);
    expect(candidate['destination'], {
      'expression': "'\$location?id=\$id'",
      'value': '/detail?id=a',
      'forwarded': true
    });
    expect(candidate['conditions'], [
      {
        'at': 'lib/home_screen.dart:16',
        'kind': 'if',
        'expression': 'canEdit',
        'is': true,
        'phase': 'at_creation',
      },
      {
        'at': 'lib/navigation.dart:7',
        'kind': 'guard',
        'expression': 'id.isEmpty',
        'is': false
      },
    ]);
  });

  test('binds a tear-off callback at creation', () {
    final candidate =
        (query(index, '/settings')['candidates'] as List).first as Map;
    expect((candidate['root'] as Map)['slot'], 'onTap');
    expect(candidate['conditions'], [
      {
        'at': 'lib/home_screen.dart:20',
        'kind': 'if',
        'expression': 'canEdit',
        'is': true,
        'phase': 'at_creation',
      },
    ]);
  });

  test('library privacy separates same-named private functions', () {
    final home = query(index, '/home')['candidates'] as List;
    expect([for (final c in home) ((c as Map)['root'] as Map)['kind']],
        ['callback']);
    final orphan = query(index, '/orphan')['candidates'] as List;
    expect([for (final c in orphan) ((c as Map)['root'] as Map)['kind']],
        ['no_callers', 'callback_factory']);
  });

  test(
      'resolves a Provider record field and a callback inside a switch expression',
      () {
    final candidate =
        (query(index, '/settings')['candidates'] as List).last as Map;
    expect(candidate['root'], containsPair('kind', 'callback'));
    expect(candidate['destination'],
        {'expression': 'routes.settings', 'value': '/settings'});
    expect(candidate['conditions'], [
      {
        'at': 'lib/patterns.dart:34',
        'kind': 'switch',
        'expression': 'kind',
        'is': 'case Kind.a',
        'phase': 'at_creation',
      },
    ]);
  });

  test(
      'links super calls to the project superclass only and marks deferred closures',
      () {
    final candidate =
        (query(index, '/login')['candidates'] as List).single as Map;
    expect(candidate['root'], containsPair('kind', 'framework'));
    expect(candidate['hops'], [
      {
        'at': 'lib/patterns.dart:28',
        'symbol': 'Patterns.build',
        'code': 'go(...)',
        'deferred': true,
      },
    ]);
    final factory = (query(index, '/orphan')['candidates'] as List).last as Map;
    expect([for (final h in factory['hops'] as List) (h as Map)['deferred']],
        [true, true]);
  });

  test('reports dynamic suffixes as prefix matches, not candidates', () {
    final result = query(index, '/home/items/:id');
    expect(result['candidates'], isEmpty);
    expect(result['prefixMatches'], [
      {
        'at': 'lib/home_screen.dart:24',
        'expression': "'/home/items/\${DateTime.now()}'",
        'knownPrefix': '/home/items/',
      },
    ]);
  });

  test('checks unknown, unresolved, uncalled, duplicate and unnavigated routes',
      () {
    expect(findings('unknown_destination').map((f) => f['destination']),
        ['/missing']);
    expect({
      for (final f in findings('unresolved_destination'))
        f['expression']: f['reasons']
    }, {
      "'/home/items/\${DateTime.now()}'": ['dynamic_expression'],
      'dynamicPath()': ['dynamic_expression'],
      'location': ['reassigned_parameter'],
    });
    expect(findings('uncalled_navigation').map((f) => f['symbol']),
        ['reassigned', '_goHome']);
    expect(findings('duplicate_route').map((f) => f['route']), ['/detail']);
    expect({
      for (final f in findings('route_without_navigation'))
        f['route']: f['otherReferences']
    }, {
      '/home/items/:id': 0
    });
  });

  test('follows member and switch-branch tear-offs', () {
    final profile =
        (query(index, '/profile')['candidates'] as List).single as Map;
    expect(profile['root'], {
      'kind': 'callback',
      'slot': 'onTap',
      'at': 'lib/tear_offs.dart:24',
      'symbol': 'TearOffs.build',
    });
    final help = (query(index, '/help')['candidates'] as List).single as Map;
    expect(
        (help['conditions'] as List).single, containsPair('is', 'case Kind.a'));
  });

  test('reports truncated chains instead of dropping candidates silently', () {
    Map<String, Object?> queryWithCallers(int callers) {
      final root = Directory.systemTemp.createTempSync('fcq_');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/lib').createSync();
      File('${root.path}/lib/app.dart').writeAsStringSync('''
final router = GoRouter(routes: [GoRoute(path: '/x')]);

void openX(BuildContext context) => context.go('/x');

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
${List.filled(callers, '        T(onTap: () => openX(context)),').join('\n')}
      ]);
}
''');
      return query(CodeIndex.build(root.path), '/x');
    }

    final some = queryWithCallers(31);
    expect(some['candidates'], hasLength(31));
    expect(some.containsKey('truncatedSites'), isFalse);
    final many = queryWithCallers(201);
    expect(many['candidates'], hasLength(200));
    expect(many['truncatedSites'], ['lib/app.dart:3']);
  });

  test('surfaces files the parser could only partly read', () {
    final root = Directory.systemTemp.createTempSync('fcq_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/lib').createSync();
    File('${root.path}/lib/broken.dart').writeAsStringSync('void f( {\n');
    final index = CodeIndex.build(root.path);
    expect(index.parseErrors.single.at, startsWith('lib/broken.dart:'));
    expect((query(index, '/x')['parseErrors'] as List).single,
        containsPair('at', index.parseErrors.single.at));
    expect(
        [for (final f in check(index)['findings'] as List) (f as Map)['check']],
        ['parse_error']);
  });

  test('suggests registered routes for an unknown target', () {
    final result = query(index, '/home/missing');
    expect(result['registrations'], isEmpty);
    expect([for (final s in result['suggestions'] as List) (s as Map)['path']],
        ['/home', '/home/items/:id']);
  });
}
