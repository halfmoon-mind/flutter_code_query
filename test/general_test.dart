import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Patterns seen across open-source go_router apps, not one app's style.
void main() {
  final index = CodeIndex.build('test/fixture/general');

  List<Map> candidates(CodeIndex index, String route) =>
      (query(index, route)['candidates'] as List).cast<Map>();
  List<Object?> symbols(Map candidate) =>
      [for (final h in candidate['hops'] as List) (h as Map)['symbol']];

  CodeIndex project(Map<String, Object> files) {
    final root = Directory.systemTemp.createTempSync('fcq_');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final MapEntry(:key, :value) in files.entries) {
      final file = File('${root.path}/lib/$key')..createSync(recursive: true);
      value is String
          ? file.writeAsStringSync(value)
          : file.writeAsBytesSync(value as List<int>);
    }
    return CodeIndex.build(root.path);
  }

  test('registers subclasses, factories, getters and evaluated paths', () {
    expect(routeList(index)['routes'], [
      {'path': '/settings', 'name': 'settings', 'at': 'lib/router.dart:22'},
      {'path': '/docs/:page', 'at': 'lib/router.dart:23'},
      {'path': '/home/detail/:id', 'at': 'lib/router.dart:20'},
      {'path': '/home', 'name': 'home', 'at': 'lib/router.dart:20'},
      {'path': '/profile', 'at': 'lib/router.dart:21'},
      {'path': '/docs', 'at': 'lib/router.dart:24'},
      {'path': '/help', 'at': 'lib/router.dart:25'},
      {'path': '/users/new', 'at': 'lib/router.dart:26'},
      {'path': '/users/:id', 'at': 'lib/router.dart:27'},
    ]);
  });

  test('binds a builder helper argument from the widget that builds it', () {
    final candidate = candidates(index, '/users/new').single;
    expect(candidate['root'], containsPair('symbol', 'Screens._tile'));
    expect((candidate['builtBy'] as Map)['kind'], 'framework');
    expect(candidate['destination'],
        {'expression': 'location', 'value': '/users/new', 'forwarded': true});
    expect(candidate['conditions'], [
      {
        'at': 'lib/screens.dart:32',
        'kind': 'if',
        'expression': 'ready',
        'is': true,
        'phase': 'at_creation',
      },
    ]);
    expect(query(index, '/home/detail/:id')['prefixMatches'], [
      {
        'at': 'lib/screens.dart:44',
        'expression': 'location',
        'knownPrefix': '/home/detail/',
      },
    ]);
  });

  test('prefers a static route over a pattern for the same location', () {
    expect([
      for (final c in candidates(index, '/users/:id')) c['destination']
    ], [
      {'expression': "'/users/42'", 'value': '/users/42'},
    ]);
  });

  test('follows ?? fallbacks, mixins, extensions and enum names', () {
    expect(candidates(index, '/docs').single['conditions'], [
      {
        'at': 'lib/screens.dart:35',
        'kind': 'if',
        'expression': 'onDone == null',
        'is': true,
        'phase': 'at_creation',
      },
    ]);
    final profile = candidates(index, '/profile');
    expect(symbols(profile.first), ['Screens.build', 'Opener.openProfile']);
    expect(
        (profile.first['hops'] as List)
            .any((h) => h.containsKey('nameMatches')),
        isFalse);
    final help = candidates(index, '/help').single;
    expect(symbols(help), ['Screens.build', 'Nav.openHelp']);
    expect((help['hops'] as List).first, containsPair('nameMatches', 1));
    expect(candidates(index, '/home').single['destination'],
        {'expression': 'AppRoute.home.name', 'value': 'home'});
  });

  test('records switch exclusions, fall-through and guards in cases', () {
    expect(candidates(index, '/profile').last['conditions'], [
      {
        'at': 'lib/screens.dart:57',
        'kind': 'switch',
        'expression': 'kind',
        'is': 'case Kind.a',
        'phase': 'at_creation',
      },
      {
        'at': 'lib/screens.dart:56',
        'kind': 'switch',
        'expression': 'kind',
        'is': 'not case Kind.a when !ok',
        'phase': 'at_creation',
      },
    ]);
    final settings = candidates(index, '/settings');
    expect([
      for (final c in settings) c['conditions']
    ], [
      [
        {
          'at': 'lib/screens.dart:67',
          'kind': 'guard',
          'expression': '!ok',
          'is': false,
        },
        {
          'at': 'lib/screens.dart:66',
          'kind': 'switch',
          'expression': 'kind',
          'is': 'case Kind.a or case Kind.b',
        },
      ],
      [
        {
          'at': 'lib/screens.dart:75',
          'kind': 'guard',
          'expression': 'a',
          'is': false
        },
      ],
    ]);
  });

  test('links private members across a `part of <library>` file', () {
    final candidate = candidates(index, '/docs/:page').single;
    expect(candidate['root'], containsPair('at', 'lib/lib_part.dart:8'));
    expect(symbols(candidate), ['B.build', 'A._openDocs']);
  });

  test('query signals every dynamic site that could reach the route', () {
    final dynamic = project({
      'app.dart': '''
final router = GoRouter(routes: [
  GoRoute(path: '/settings', name: 'settings'),
  GoRoute(path: '/users/:uid/posts'),
]);

class W extends StatelessWidget {
  W(this.page, this.routeName, this.tab);
  final String page;
  final String routeName;
  final String tab;

  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go('/\$page')),
        T(onTap: () => context.goNamed(routeName)),
        T(onTap: () => context.go('/users/me/\$tab')),
        T(onTap: () => context.go('details')),
      ]);
}
''',
    });
    expect(query(dynamic, '/settings')['fullyDynamicSites'], 3);
    final posts = query(dynamic, '/users/:uid/posts');
    expect(posts['fullyDynamicSites'], 3);
    expect([for (final m in posts['prefixMatches'] as List) m['knownPrefix']],
        ['/users/me/']);
    final relative = (check(dynamic)['findings'] as List)
        .cast<Map>()
        .where((f) => f['expression'] == "'details'");
    expect(relative.single['reasons'], ['relative_location']);
  });

  test('caps name-only links and leaves lifecycle calls to the framework', () {
    final guessed = project({
      'app.dart': '''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);

class One { void open() {} }
class Two { void open() {} }
class Three { void open() {} }
class Four {
  Four(this.context);
  final BuildContext context;
  void open() => context.go('/a');
}

class Page extends StatefulWidget {
  State<Page> createState() => _PageState();
}

class _PageState extends State<Page> {
  void dispose() { context.go('/b'); }
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => thing.open()),
        T(onTap: () => controller.dispose()),
      ]);
}
''',
    });
    expect(candidates(guessed, '/a').single['root'],
        containsPair('kind', 'ambiguous_callers'));
    expect(candidates(guessed, '/b').single['root'],
        containsPair('kind', 'framework'));
    expect(
        (check(guessed)['findings'] as List)
            .where((f) => (f as Map)['check'] == 'uncalled_navigation'),
        isEmpty);
  });

  test('keeps one chain per root and roots recursion as a cycle', () {
    final shapes = project({
      'app.dart': '''
final router = GoRouter(routes: [GoRoute(path: '/d'), GoRoute(path: '/r')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => _a(context));
  void _a(BuildContext context) { _b(context); _c(context); }
  void _b(BuildContext context) => _d(context);
  void _c(BuildContext context) => _d(context);
  void _d(BuildContext context) => context.go('/d');
  void _r(BuildContext context, int n) { if (n > 0) _r(context, n - 1); context.go('/r'); }
}
''',
    });
    expect(candidates(shapes, '/d'), hasLength(1));
    expect(
        candidates(shapes, '/r').single['root'], containsPair('kind', 'cycle'));
  });

  test('downgrades unknown destinations when some route paths are unknown', () {
    final partial = project({
      'app.dart': '''
final router = GoRouter(routes: [GoRoute(path: '/known'), GoRoute(path: pathFromServer())]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => context.go('/elsewhere'));
}
''',
    });
    final unknown = (check(partial)['findings'] as List)
        .cast<Map>()
        .singleWhere((f) => f['check'] == 'unknown_destination');
    expect(unknown['severity'], 'info');
  });

  test('reads a malformed file instead of crashing', () {
    final broken = project({
      'ok.dart': "final router = GoRouter(routes: [GoRoute(path: '/ok')]);",
      'bad.dart': [0xff, 0xfe, 0x00, 0x41],
    });
    expect(routeList(broken)['routes'], hasLength(1));
  });
}
