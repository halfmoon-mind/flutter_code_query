import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Values read from map literals and from getters of constant objects.
void main() {
  CodeIndex project(Map<String, String> files) {
    final root = Directory.systemTemp.createTempSync('fcq_');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final MapEntry(:key, :value) in files.entries) {
      File('${root.path}/lib/$key')
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    return CodeIndex.build(root.path);
  }

  List<Object?> destinations(CodeIndex index, String route) => [
        for (final c in query(index, route)['candidates'] as List)
          (c as Map)['destination'],
      ];

  const router = '''
final router = GoRouter(routes: [
  GoRoute(path: '/a'),
  GoRoute(path: '/b'),
  GoRoute(path: '/home'),
]);
''';

  test('reads a present key of a map constant, static field or local', () {
    final index = project({
      'paths.dart': '''
const titles = {'a': '/a', 'b': '/x'};
class Paths { static const byKey = {...titles, 'b': '/b'}; }
''',
      'app.dart': '''
import 'paths.dart' as p;
$router
class W extends StatelessWidget {
  static const own = {'h': '/home'};
  Widget build(BuildContext context) {
    const local = {'a': '/a'};
    return Column(children: [
      T(onTap: () => context.go(p.titles['a']!)),
      T(onTap: () => context.go(p.Paths.byKey['b']!)),
      T(onTap: () => context.go(own['h']!)),
      T(onTap: () => context.go(local['a']!)),
    ]);
  }
}
''',
    });
    expect(destinations(index, '/a'), [
      {'expression': "p.titles['a']!", 'value': '/a'},
      {'expression': "local['a']!", 'value': '/a'},
    ]);
    expect(destinations(index, '/b'), [
      {'expression': "p.Paths.byKey['b']!", 'value': '/b'},
    ]);
    expect(destinations(index, '/home'), [
      {'expression': "own['h']!", 'value': '/home'},
    ]);
  });

  test('takes the fallback of an absent key', () {
    final index = project({
      'app.dart': '''
$router
const titles = {'a': '/a'};
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(titles['z'] ?? '/home'));
}
''',
    });
    expect(destinations(index, '/home'), [
      {'expression': "titles['z'] ?? '/home'", 'value': '/home'},
    ]);
    expect(destinations(index, '/a'), isEmpty);
  });

  test('leaves an absent key with ! unknown', () {
    final index = project({
      'app.dart': '''
$router
const titles = {'a': '/a'};
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(titles['z']!));
}
''',
    });
    final result = query(index, '/a');
    expect(result['candidates'], isEmpty);
    expect(result['dynamicSites'], [
      {'at': 'lib/app.dart:10', 'expression': "titles['z']!"},
    ]);
  });

  test('offers every value and absence for an unknown key', () {
    final index = project({
      'app.dart': '''
$router
const titles = {'a': '/a', 'b': '/b'};
class W extends StatelessWidget {
  const W(this.tab);
  final String tab;
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(titles[tab] ?? '/home'));
}
''',
    });
    for (final route in ['/a', '/b', '/home']) {
      expect(destinations(index, route), [
        {
          'expression': "titles[tab] ?? '/home'",
          'value': route,
          'alternative': true,
        },
      ]);
    }
  });

  test('reads keys past if and for entries', () {
    final index = project({
      'app.dart': '''
$router
const titles = {'a': '/a', 'b': '/b', if (beta) 'b': '/home', if (beta) 'c': '/b'};
final nested = {for (final e in entries) if (e.on) 'k': '/b'};
class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(titles['a']!)),
        T(onTap: () => context.go(titles['b']!)),
        T(onTap: () => context.go(titles['z'] ?? '/home')),
        T(onTap: () => context.go(nested['k'] ?? '/home')),
      ]);
}
''',
    });
    expect(destinations(index, '/a'), [
      {'expression': "titles['a']!", 'value': '/a'},
    ]);
    expect(destinations(index, '/b'), [
      {'expression': "titles['b']!", 'value': '/b', 'alternative': true},
      {
        'expression': "nested['k'] ?? '/home'",
        'value': '/b',
        'alternative': true,
      },
    ]);
    expect(destinations(index, '/home'), [
      {'expression': "titles['b']!", 'value': '/home', 'alternative': true},
      {'expression': "titles['z'] ?? '/home'", 'value': '/home'},
      {
        'expression': "nested['k'] ?? '/home'",
        'value': '/home',
        'alternative': true,
      },
    ]);
  });

  test('keeps a lookup in a map that is not constant open', () {
    final index = project({
      'app.dart': '''
$router
final overrides = <String, String>{};
class Registry { static final paths = {'k': '/a'}; }
class W extends StatelessWidget {
  Widget build(BuildContext context) {
    final local = {'k': '/a'};
    return Column(children: [
      T(onTap: () => context.go(overrides['k'] ?? '/home')),
      T(onTap: () => context.go(Registry.paths['k']!)),
      T(onTap: () => context.go(local['k']!)),
    ]);
  }
}
''',
    });
    expect(destinations(index, '/home'), [
      {
        'expression': "overrides['k'] ?? '/home'",
        'value': '/home',
        'alternative': true,
      },
    ]);
    final result = query(index, '/a');
    expect(result['candidates'], hasLength(2));
    for (final c in result['candidates'] as List) {
      expect((c as Map)['destination'], containsPair('alternative', true));
    }
    expect(result['dynamicSites'], [
      {'at': 'lib/app.dart:13', 'expression': "overrides['k'] ?? '/home'"},
      {'at': 'lib/app.dart:14', 'expression': "Registry.paths['k']!"},
      {'at': 'lib/app.dart:15', 'expression': "local['k']!"},
    ]);
  });

  test('compares keys by value and kind', () {
    final index = project({
      'app.dart': '''
$router
class Tag { const Tag(this.id); final String id; }
const byHex = {0x1: '/a'};
const byTag = {Tag('/b'): '/b'};
const both = <Object, String>{1: '/a', '1': '/b'};
class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(byHex[1] ?? '/home')),
        T(onTap: () => context.go(byTag['/b'] ?? '/home')),
        T(onTap: () => context.go(both[1]!)),
      ]);
}
''',
    });
    expect(destinations(index, '/a'), [
      {'expression': "byHex[1] ?? '/home'", 'value': '/a'},
      {'expression': 'both[1]!', 'value': '/a'},
    ]);
    expect(destinations(index, '/b'), isEmpty);
    expect(destinations(index, '/home'), [
      {'expression': "byTag['/b'] ?? '/home'", 'value': '/home'},
    ]);
  });

  test('reads no constant that a member of the class hides', () {
    final index = project({
      'other.dart': '''
const _routes = {'home': '/b'};
const labels = {'home': '/b'};
const tabs = {'feed': '/b'};
''',
      'app.dart': '''
import 'other.dart';
$router
class Menu extends StatelessWidget {
  const Menu({required this.labels});
  final Map<String, String> labels;
  Map<String, String> get tabs => load();
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(_routes['home'] ?? '/a')),
        T(onTap: () => context.go(labels['home'] ?? '/a')),
        T(onTap: () => context.go(tabs['feed'] ?? '/a')),
      ]);
}
''',
    });
    expect(destinations(index, '/b'), isEmpty);
    expect(destinations(index, '/a'), hasLength(3));
  });

  test('evaluates each key of nested lookups once', () {
    final entries = [
      for (var i = 0; i < 100; i++) "'k$i': 'k${(i + 1) % 100}'",
    ].join(', ');
    final watch = Stopwatch()..start();
    final index = project({
      'app.dart': '''
final router = GoRouter(routes: [GoRoute(path: '/k5')]);
const a = {$entries};
const b = {$entries};
const c = {$entries};
const d = {$entries};
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go('/\${a[b[c[d['k1']!]!]!]!}'));
}
''',
    });
    expect(destinations(index, '/k5'), [
      {'expression': "'/\${a[b[c[d['k1']!]!]!]!}'", 'value': '/k5'},
    ]);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('keeps a lookup open past an unknown spread', () {
    final index = project({
      'app.dart': '''
$router
final titles = {...remote, 'a': '/a'};
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(titles['b'] ?? '/home'));
}
''',
    });
    expect(destinations(index, '/home'), [
      {
        'expression': "titles['b'] ?? '/home'",
        'value': '/home',
        'alternative': true,
      },
    ]);
    expect(query(index, '/home')['dynamicSites'], [
      {'at': 'lib/app.dart:10', 'expression': "titles['b'] ?? '/home'"},
    ]);
  });

  const routeInfo = '''
extension type const RouteInfo(String path) implements String {
  String get displayName => displayNames[path] ?? path;
  static const displayNames = <String, String>{
    '/home': 'Home',
    if (kDebugMode) '/debug': 'Debug',
  };
}

abstract final class RouteName {
  static const RouteInfo home = RouteInfo('/home');
  static const RouteInfo other = RouteInfo('/other');
}

final router = GoRouter(routes: [
  GoRoute(path: RouteName.home, name: RouteName.home.displayName),
  GoRoute(path: RouteName.other, name: RouteName.other.displayName),
]);

class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.goNamed(RouteName.home.displayName));
}
''';

  test('names routes by an extension type getter on a static constant', () {
    final index = project({'routes.dart': routeInfo});
    expect(routeList(index)['routes'], [
      {'path': '/home', 'name': 'Home', 'at': 'lib/routes.dart:15'},
      {'path': '/other', 'name': '/other', 'at': 'lib/routes.dart:16'},
    ]);
  });

  test('evaluates a getter of a constant object from its fields', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/docs/help')]);

class Page {
  const Page(this.slug, {this.section = 'docs'});
  final String slug;
  final String section;
  String get path => '$base/$slug';
  String get base => '/$section';
}

const help = Page('help');

class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(help.path));
}
''',
    });
    expect(destinations(index, '/docs/help'), [
      {'expression': 'help.path', 'value': '/docs/help', 'forwarded': true},
    ]);
  });

  test('resolves goNamed through a getter and queries by that name', () {
    final index = project({'routes.dart': routeInfo});
    final destination = {
      'expression': 'RouteName.home.displayName',
      'value': 'Home',
      'forwarded': true,
    };
    expect(destinations(index, '/home'), [destination]);
    final byName = query(index, 'Home');
    expect(byName['registrations'], [
      {'at': 'lib/routes.dart:15', 'path': '/home', 'name': 'Home'},
    ]);
    expect(destinations(index, 'Home'), [destination]);
  });

  test('reads no constant for a field the constructor leaves unset', () {
    final index = project({
      'app.dart': r'''
const title = 'Wrong';
const prefix = '/b';
final router = GoRouter(routes: [
  GoRoute(path: '/a', name: Items.a.name),
  GoRoute(path: '/b/docs'),
]);
class NavItem {
  const NavItem({required this.path, this.title});
  final String path;
  final String? title;
  String get name => title ?? path;
}
abstract final class Items { static const a = NavItem(path: '/a'); }
class Section {
  Section(this.path) { prefix = '/app'; }
  final String path;
  late String prefix;
  String get full => '$prefix$path';
}
final section = Section('/docs');
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(section.full));
}
''',
    });
    expect(routeList(index)['routes'], [
      {'path': '/a', 'nameExpression': 'Items.a.name', 'at': 'lib/app.dart:4'},
      {'path': '/b/docs', 'at': 'lib/app.dart:5'},
    ]);
    expect(destinations(index, '/b/docs'), isEmpty);
  });

  test('reads only final fields of an object', () {
    final index = project({
      'app.dart': '''
final router = GoRouter(routes: [
  GoRoute(path: '/login'),
  GoRoute(path: '/dashboard'),
]);
class Session {
  Session(this.home, this.start, {this.loggedIn = false});
  String home;
  final String start;
  bool loggedIn;
  String get entry => loggedIn ? '/dashboard' : start;
}
final session = Session('/login', '/login');
class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(session.home)),
        T(onTap: () => context.go(session.start)),
        T(onTap: () => context.go(session.entry)),
      ]);
}
''',
    });
    expect(destinations(index, '/login'), [
      {'expression': 'session.start', 'value': '/login', 'forwarded': true},
      {
        'expression': 'session.entry',
        'value': '/login',
        'forwarded': true,
        'alternative': true,
      },
    ]);
    expect(destinations(index, '/dashboard'), [
      {
        'expression': 'session.entry',
        'value': '/dashboard',
        'forwarded': true,
        'alternative': true,
      },
    ]);
  });

  test("reads a State's own field in its getter, not the widget's", () {
    final index = project({
      'app.dart': '''
final router = GoRouter(routes: [
  GoRoute(path: '/published', builder: (c, s) => const Detail(path: '/published')),
]);
class Detail extends StatefulWidget {
  const Detail({required this.path});
  final String path;
  State<Detail> createState() => _DetailState();
}
class _DetailState extends State<Detail> {
  String path = '/draft';
  String get target => path;
  Widget build(BuildContext context) => T(onTap: () => context.go(target));
}
''',
    });
    expect(destinations(index, '/published'), isEmpty);
  });

  test('evaluates no getter of a class name two libraries declare', () {
    final index = project({
      'a/nav_item.dart': r'''
class NavItem {
  const NavItem(this.path);
  final String path;
  String get label => '/a$path';
}
''',
      'b/nav_item.dart': '''
class NavItem {
  const NavItem(this.label, this.path);
  final String label;
  final String path;
}
''',
      'b/page.dart': '''
import 'nav_item.dart';
final router = GoRouter(routes: [GoRoute(path: '/a/settings')]);
const item = NavItem('/settings', '/x');
class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => context.go(item.label));
}
''',
    });
    expect(destinations(index, '/a/settings'), isEmpty);
  });

  test('reads this in an extension type getter as its representation', () {
    final index = project({
      'app.dart': '''
extension type const Named(String value) implements String {
  String get title => titles[this] ?? this;
  static const titles = <String, String>{'/a': 'A', '/b': 'B'};
}
abstract final class RouteName { static const Named a = Named('/a'); }
final router = GoRouter(routes: [
  GoRoute(path: '/a', name: RouteName.a.title),
  GoRoute(path: '/b', name: 'B'),
]);
class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.goNamed(RouteName.a.title));
}
''',
    });
    expect(routeList(index)['routes'], [
      {'path': '/a', 'name': 'A', 'at': 'lib/app.dart:7'},
      {'path': '/b', 'name': 'B', 'at': 'lib/app.dart:8'},
    ]);
    expect(destinations(index, '/b'), isEmpty);
  });

  test('evaluates a getter of an object with several returns', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/help')]);
class Page {
  const Page(this.slug);
  final String slug;
  String get path {
    if (beta) return '/docs/$slug';
    return '/$slug';
  }
}
const help = Page('help');
class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => context.go(help.path));
}
''',
    });
    expect(destinations(index, '/help'), [
      {
        'expression': 'help.path',
        'value': '/help',
        'forwarded': true,
        'alternative': true,
      },
    ]);
  });

  test('finds the representation field past type parameters', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/q', name: Q.b.label)]);
extension type Q<T extends void Function()>(String raw) {
  String get label => 'Q-$raw';
  static const b = Q('b');
}
''',
    });
    expect(routeList(index)['routes'], [
      {'path': '/q', 'name': 'Q-b', 'at': 'lib/app.dart:1'},
    ]);
  });
}
