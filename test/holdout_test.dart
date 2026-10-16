import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Idioms from go_router apps the tool was not tuned on, one project each.
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

  List<Map> candidates(CodeIndex index, String route) =>
      (query(index, route)['candidates'] as List).cast<Map>();
  List<Object?> symbols(Map candidate) =>
      [for (final h in candidate['hops'] as List) (h as Map)['symbol']];
  List<Map> findings(CodeIndex index, String name) => [
        for (final f in check(index)['findings'] as List)
          if ((f as Map)['check'] == name) f,
      ];

  test('handles private widget and route classes like public ones', () {
    final index = project({
      'app.dart': r'''
class _AppRoute extends GoRoute {
  _AppRoute({required super.path});
}

final router = GoRouter(routes: [_AppRoute(path: '/x'), GoRoute(path: '/y')]);

class Page extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        if (ready) _Tile(route: '/y'),
      ]);
}

class _Tile extends StatelessWidget {
  _Tile({required this.route});
  final String route;
  Widget build(BuildContext context) => ListTile(onTap: () => context.go(route));
}
''',
    });
    expect([
      for (final r in routeList(index)['routes'] as List) (r as Map)['path']
    ], [
      '/x',
      '/y'
    ]);
    final tile = candidates(index, '/y').single;
    expect((tile['builtBy'] as Map)['kind'], 'framework');
    expect((tile['conditions'] as List).single,
        containsPair('expression', 'ready'));
  });

  test('evaluates enum index for goBranch and dot-shorthand arguments', () {
    final index = project({
      'app.dart': r'''
enum Tab { a, b }

enum Routes {
  home('/a'),
  settings('/b');

  const Routes(this.path);
  final String path;
}

final router = GoRouter(routes: [
  StatefulShellRoute.indexedStack(branches: [
    StatefulShellBranch(routes: [GoRoute(path: '/a')]),
    StatefulShellBranch(routes: [GoRoute(path: '/b')]),
  ]),
]);

void _goTo(BuildContext context, Routes route) => context.go(route.path);

class W extends StatelessWidget {
  W(this.shell);
  final StatefulNavigationShell shell;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => shell.goBranch(Tab.a.index)),
        T(onTap: () => _goTo(context, .settings)),
      ]);
}
''',
    });
    expect(candidates(index, '/a').single['destination'],
        containsPair('branch', 0));
    expect(candidates(index, '/b').single['destination'],
        containsPair('value', '/b'));
  });

  test('links extension members by the receiver type', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c')]);

extension Nav on BuildContext {
  void openA() => this.go('/a');
}

extension RouterNav on GoRouter {
  void openB() => go('/b');
}

class Wizard {
  void pop(BuildContext context) => context.go('/c');
}

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.openA()),
        T(onTap: () => GoRouter.of(context).openB()),
        T(onTap: () => context.pop()),
      ]);
}
''',
    });
    expect(symbols(candidates(index, '/a').single), ['W.build', 'Nav.openA']);
    expect(symbols(candidates(index, '/b').single),
        ['W.build', 'RouterNav.openB']);
    // go_router's own `context.pop()` is not Wizard.pop.
    expect(candidates(index, '/c').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('reads static lists, import prefixes and GoRouter fields', () {
    final index = project({
      'paths.dart': r'''
const kSettings = '/settings';
class Paths { static const profile = '/profile'; }
''',
      'nav.dart': r'''
void openHelp(BuildContext context) => context.go('/help');
''',
      'app.dart': r'''
import 'paths.dart' as paths;
import 'nav.dart' as nav;

final router = GoRouter(routes: [
  GoRoute(path: '/'), GoRoute(path: '/settings'), GoRoute(path: '/profile'),
  GoRoute(path: '/help'), GoRoute(path: '/tabs'),
]);

class _Tab { const _Tab(this.route); final String route; }

class Home extends StatefulWidget { State<Home> createState() => _HomeState(); }

class _HomeState extends State<Home> {
  static const _tabs = [_Tab('/'), _Tab('/tabs')];
  late final nav = GoRouter.of(context);

  void _select(int i) => context.go(_tabs[i].route);

  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(paths.kSettings)),
        T(onTap: () => this.nav.go(paths.Paths.profile)),
        T(onTap: () => nav.openHelp(context)),
        Bar(onDestinationSelected: _select),
      ]);
}
''',
    });
    for (final route in ['/settings', '/profile', '/help', '/', '/tabs']) {
      expect(candidates(index, route), isNotEmpty, reason: route);
    }
  });

  test('records the condition that picks a conditional destination', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/'), GoRoute(path: '/onboarding')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) =>
      T(onTap: () => context.go(seen ? '/' : '/onboarding'));
}
''',
    });
    expect(candidates(index, '/onboarding').single['conditions'], [
      {
        'at': 'lib/app.dart:5',
        'kind': 'if',
        'expression': 'seen',
        'is': false,
        'phase': 'on_event',
      },
    ]);
  });

  test('phases conditions around and inside a listener', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/done')]);

class W extends ConsumerWidget {
  Widget build(BuildContext context, WidgetRef ref) {
    if (ready) {
      ref.listen<bool>(finishedProvider, (previous, next) {
        if (next) context.go('/done');
      });
    }
    return const SizedBox();
  }
}
''',
    });
    expect([
      for (final c in candidates(index, '/done').single['conditions'] as List)
        '${(c as Map)['expression']}:${c['phase']}'
    ], [
      'next:on_event',
      'ready:at_creation'
    ]);
  });

  test('registers shared child lists under every parent; finds duplicates', () {
    final index = project({
      'app.dart': r'''
final childRoutes = [GoRoute(path: 'detail')];
final authRoutes = [GoRoute(path: '/login'), GoRoute(path: '/settings')];
final mainRoutes = [GoRoute(path: '/'), GoRoute(path: '/settings')];

final router = GoRouter(routes: [
  GoRoute(path: '/p1', routes: childRoutes),
  GoRoute(path: '/p2', routes: childRoutes),
  ...authRoutes,
  ...mainRoutes,
]);
''',
    });
    final paths = [
      for (final r in routeList(index)['routes'] as List) (r as Map)['path'],
    ];
    expect(paths, containsAll(['/p1/detail', '/p2/detail']));
    expect([for (final f in findings(index, 'duplicate_route')) f['route']],
        ['/settings']);
  });

  test('counts typed route uses and plain constants as references', () {
    final index = project({
      'app.dart': r'''
const kAbout = '/about';

@TypedGoRoute<LoginRoute>(path: '/login')
class LoginRoute extends GoRouteData {
  const LoginRoute();
}

final router = GoRouter(
  routes: [GoRoute(path: kAbout)],
  redirect: (context, state) => loggedIn ? null : const LoginRoute().location,
);

final about = kAbout;
''',
    });
    expect({
      for (final f in findings(index, 'route_without_navigation'))
        f['route']: f['otherReferences']
    }, {
      '/login': 1,
      '/about': 1,
    });
  });

  test('skips generated files with a split header; builds only when useful',
      () {
    final index = project({
      'gen.dart':
          '// GENERATED FILE\n// DO NOT MODIFY\nfinal r = GoRoute(path: "/gen");',
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/uri')]);

class Home extends StatelessWidget {
  Widget build(BuildContext context) => T(
      onTap: () => context.go(Uri(path: '/uri', queryParameters: {'a': 'b'}).toString()));
}

class Shell extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [Home(), Home()]);
}
''',
    });
    expect(routeList(index)['routes'], hasLength(1));
    expect(candidates(index, '/uri').single, isNot(contains('builtBy')));
  });
}
