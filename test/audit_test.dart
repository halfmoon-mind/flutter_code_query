import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Idioms an audit of open-source go_router apps found, one project each.
void main() {
  CodeIndex project(Map<String, String> files, {String? pubspec}) {
    final root = Directory.systemTemp.createTempSync('fcq_');
    addTearDown(() => root.deleteSync(recursive: true));
    if (pubspec != null) {
      File('${root.path}/pubspec.yaml').writeAsStringSync(pubspec);
    }
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

  test('conditional, switch and fallback destinations reach every branch', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [
  GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c'), GoRoute(path: '/home'),
]);

enum Tab { a, b }

extension on Tab {
  String get location => switch (this) { Tab.a => '/a', Tab.b => '/b' };
}

class W extends StatelessWidget {
  W(this.admin, this.tab, this.from);
  final bool admin;
  final int tab;
  final String? from;

  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(admin ? '/c' : '/a')),
        T(onTap: () => context.go(switch (tab) { 0 => '/a', _ => '/b' })),
        T(onTap: () => context.go(from ?? '/home')),
      ]);
}
''',
    });
    expect([
      for (final c in candidates(index, '/c')) c['destination']
    ], [
      {'expression': "admin ? '/c' : '/a'", 'value': '/c', 'alternative': true},
    ]);
    expect(candidates(index, '/a'), hasLength(2));
    expect(candidates(index, '/b'), hasLength(1));
    expect(candidates(index, '/home').single['destination'],
        containsPair('alternative', true));
  });

  test('evaluates Uri(...).toString(), namedLocation and enum parameters', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [
  GoRoute(path: '/search'),
  GoRoute(path: '/item/:id', name: 'item'),
  GoRoute(path: '/donate/settings'),
  GoRoute(path: '/flag/true'),
]);

enum Source { settings, tagline }

class Paths {
  static String donate(Source source) => '/donate/${source.name}';
  static String flag(bool on) => '/flag/$on';
}

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(Uri(path: '/search', queryParameters: {'q': 'x'}).toString())),
        T(onTap: () => context.go(context.namedLocation('item', pathParameters: {'id': '1'}))),
        T(onTap: () => context.go(Paths.donate(Source.settings))),
        T(onTap: () => context.go(Paths.flag(true))),
      ]);
}
''',
    });
    for (final route in [
      '/search',
      '/item/:id',
      '/donate/settings',
      '/flag/true'
    ]) {
      expect(candidates(index, route), hasLength(1), reason: route);
    }
  });

  test('recognizes GoRouter locals, fields and builder context parameters', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c')]);

class Rail extends StatelessWidget {
  Rail(this.route);
  final GoRouter route;

  Widget build(BuildContext context) {
    final nav = GoRouter.of(context);
    return Column(children: [
      T(onTap: () => nav.go('/a')),
      T(onTap: () => route.go('/b')),
      T(onTap: () => showDialog(context: context, builder: (ctx) => T(onTap: () => ctx.go('/c')))),
    ]);
  }
}
''',
    });
    for (final route in ['/a', '/b', '/c']) {
      expect(candidates(index, route), hasLength(1), reason: route);
    }
    expect((candidates(index, '/c').single['root'] as Map)['within'],
        containsPair('slot', 'onTap'));
  });

  test('keeps go_router calls and framework receivers off project methods', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/errors'), GoRoute(path: '/x')]);

class AppNavigator {
  static void push(String location) => router.push(location);
}

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.push('/x')),
        T(onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Page()))),
        T(onTap: () => AppNavigator.push('/errors')),
      ]);
}
''',
    });
    final errors = candidates(index, '/errors');
    expect(errors, hasLength(1));
    expect(symbols(errors.single), ['W.build', 'AppNavigator.push']);
    expect(candidates(index, '/x').single['hops'], hasLength(1));
  });

  test('roots listeners in initializers, main and actions; ignores removal',
      () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/done'), GoRoute(path: '/start'), GoRoute(path: '/new'), GoRoute(path: '/r')]);

void main() {
  bootstrap();
}

void bootstrap() => router.go('/start');

class NewAction extends Action<NewIntent> {
  NewAction(this.context);
  final BuildContext context;
  Object? invoke(NewIntent intent) => context.go('/new');
}

class _PlayerState extends State<Player> {
  late final _sub = widget.done.listen(_onDone);
  void _onDone(Object _) => context.go('/done');
  void _onChange() => context.go('/r');
  void dispose() {
    controller.removeListener(_onChange);
    super.dispose();
  }
  Widget build(BuildContext context) => const SizedBox();
}
''',
    });
    expect(candidates(index, '/done').single['root'],
        containsPair('kind', 'initializer'));
    expect(candidates(index, '/start').single['root'],
        containsPair('kind', 'entry_point'));
    expect(candidates(index, '/new').single['root'],
        containsPair('kind', 'framework'));
    expect(candidates(index, '/r').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('uses imports, type arguments and overrides to pick declarations', () {
    final index = project({
      'a/screen.dart': "class Screen { static const routeName = '/a'; }",
      'b/screen.dart': "class Screen { static const routeName = '/b'; }",
      'routers.dart': r'''
class AuthRouter { void goHome(BuildContext context, User u) => context.go('/auth-home'); }
class SplashRouter { void goHome(BuildContext context) => context.go('/splash-home'); }
''',
      'app.dart': r'''
import 'package:demo/b/screen.dart';

final router = GoRouter(routes: [
  GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/auth-home'),
  GoRoute(path: '/splash-home'), GoRoute(path: '/submit'),
]);

abstract class Form extends StatelessWidget {
  void submit(BuildContext context) {}
  Widget build(BuildContext context) => T(onTap: () => submit(context));
}

class SignupForm extends Form {
  void submit(BuildContext context) => context.go('/submit');
}

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(Screen.routeName)),
        T(onTap: () => getIt<AuthRouter>().goHome(context, user)),
      ]);
}
''',
    }, pubspec: 'name: demo\n');
    expect(candidates(index, '/b'), hasLength(1));
    expect(candidates(index, '/a'), isEmpty);
    expect(candidates(index, '/auth-home'), hasLength(1));
    // SplashRouter.goHome is not what `getIt<AuthRouter>()` calls.
    expect(candidates(index, '/splash-home').single['root'],
        containsPair('kind', 'no_callers'));
    expect(symbols(candidates(index, '/submit').single),
        ['Form.build', 'SignupForm.submit']);
  });

  test('binds a positional callback to the parameter that takes it', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/home')]);

class Tile extends StatelessWidget {
  Widget build(BuildContext context) {
    void handleTap() => context.go('/home');
    return _body(handleTap);
  }

  Widget _body(VoidCallback onTap) => InkWell(onTap: onTap);
}
''',
    });
    expect(candidates(index, '/home').single['root'],
        containsPair('slot', 'onTap'));
  });

  test('builder closures around a slot do not defer it; root.at is the slot',
      () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/detail')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => ListView.builder(
        itemBuilder: (context, i) => ListTile(
          onTap: () async {
            await save();
            context.go('/detail');
          },
        ),
      );
}
''',
    });
    final candidate = candidates(index, '/detail').single;
    expect(candidate['root'], containsPair('at', 'lib/app.dart:6'));
    expect((candidate['hops'] as List).single, isNot(contains('deferred')));
  });

  test('drops chains whose literal arguments contradict a condition', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/new')]);

void open(BuildContext context, bool replace) {
  if (replace) {
    context.go('/new');
  } else {
    context.push('/new');
  }
}

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => open(context, false));
}
''',
    });
    expect([
      for (final c in candidates(index, '/new')) symbols(c)
    ], [
      ['W.build', 'open'],
    ]);
    expect((candidates(index, '/new').single['hops'] as List).last['code'],
        'push(...)');
  });

  test('finds guards in else-if chains, nested exits and loops', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c')]);

Widget card(BuildContext context, Item item) {
  if (item.isTable) {
    return Table();
  } else if (item.isImage) {
    return Image();
  }
  return T(onTap: () => context.go('/a'));
}

void openRemote(BuildContext context, Location location) {
  if (location.isRemote) {
    if (connected) {
      return;
    } else {
      return;
    }
  }
  context.go('/b');
}

void each(BuildContext context, List<Item?> items) {
  for (final item in items) {
    if (item == null) continue;
    context.go('/c');
  }
}
''',
    });
    List<Object?> guards(String route) => [
          for (final c in candidates(index, route).first['conditions'] as List)
            if ((c as Map)['kind'] == 'guard') '${c['expression']}=${c['is']}',
        ];
    expect(guards('/a'), ['item.isTable=false', 'item.isImage=false']);
    expect(guards('/b'), ['location.isRemote=false']);
    expect(guards('/c'), ['item == null=false']);
  });

  test('phases conditions below the root and in a callback factory', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/done'), GoRoute(path: '/edit')]);

class W extends StatelessWidget {
  W(this.last, this.canEdit);
  final bool last;
  final bool canEdit;

  Widget build(BuildContext context) => Column(children: [
        T(onPressed: () => _finish(context)),
        T(onTap: _onTapFor(context)),
      ]);

  void _finish(BuildContext context) {
    if (last) context.go('/done');
  }

  VoidCallback? _onTapFor(BuildContext context) {
    if (!canEdit) return null;
    return () {
      if (context.mounted) context.go('/edit');
    };
  }
}
''',
    });
    List<Object?> phases(String route) => [
          for (final c in candidates(index, route).single['conditions'] as List)
            '${(c as Map)['expression']}:${c['phase']}',
        ];
    expect(phases('/done'), ['last:on_event']);
    expect(
        phases('/edit'), ['context.mounted:on_event', '!canEdit:at_creation']);
  });

  test('switches shell branches with goBranch', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [
  StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => Scaffold(
      bottomNavigationBar: NavigationBar(
        onDestinationSelected: (i) => shell.goBranch(i),
      ),
    ),
    branches: [
      StatefulShellBranch(routes: [GoRoute(path: '/feed', routes: [GoRoute(path: 'post')])]),
      StatefulShellBranch(routes: [GoRoute(path: '/profile')]),
    ],
  ),
]);

void goHome(StatefulNavigationShell shell) => shell.goBranch(0);
''',
    });
    expect(candidates(index, '/feed'), hasLength(2));
    expect(candidates(index, '/profile'), hasLength(1));
    expect(candidates(index, '/feed/post'), isEmpty);
    expect(
        candidates(index, '/feed')
            .map((c) => (c['destination'] as Map)['branch'])
            .toSet(),
        {'any', 0});
  });

  test('binds a widget field set by its constructor call', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/general'), GoRoute(path: '/about')]);

class Section extends StatelessWidget {
  const Section({required this.location});
  final String location;
  Widget build(BuildContext context) => ListTile(onTap: () => context.go(location));
}

class SettingsPage extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        Section(location: '/general'),
        if (isAdmin) Section(location: '/about'),
      ]);
}
''',
    });
    final about = candidates(index, '/about').single;
    expect((about['builtBy'] as Map)['kind'], 'framework');
    expect(about['conditions'], [
      {
        'at': 'lib/app.dart:12',
        'kind': 'if',
        'expression': 'isAdmin',
        'is': true,
        'phase': 'at_creation',
      },
    ]);
    expect(candidates(index, '/general'), hasLength(1));
  });

  test('registers routes nested through getters and partly dynamic helpers',
      () {
    final index = project({
      'app.dart': r'''
GoRoute get _artifact => GoRoute(path: 'artifact/:id');
GoRoute get _collection => GoRoute(path: 'collection', routes: [_artifact]);

List<GoRoute> _settings(List<String> ids) => [
      for (final id in ids) GoRoute(path: 'settings/$id'),
    ];

final router = GoRouter(routes: [
  GoRoute(path: '/home', routes: [_collection]),
  GoRoute(path: '/wonder', routes: [_collection]),
  GoRoute(path: '/', routes: [..._settings(ids)]),
]);
''',
    });
    final routes = routeList(index)['routes'] as List;
    expect(
        [for (final r in routes) (r as Map)['path']].whereType<String>(),
        containsAll([
          '/home/collection',
          '/wonder/collection',
          '/home/collection/artifact/:id',
          '/wonder/collection/artifact/:id',
        ]));
    expect([for (final r in routes) (r as Map)['pathPrefix']],
        contains('/settings/'));
  });

  test('flags duplicates only within one router configuration', () {
    final index = project({
      'app.dart': r'''
final loading = RoutingConfig(routes: [GoRoute(path: '/home')]);
final ready = RoutingConfig(routes: [GoRoute(path: '/home'), GoRoute(path: '/x'), GoRoute(path: '/x')]);
''',
    });
    expect([for (final f in findings(index, 'duplicate_route')) f['route']],
        ['/x']);
  });

  test('counts route references by full path, name and constant', () {
    final index = project({
      'app.dart': r'''
class Routes { static const logs = '/settings/logs'; }

final router = GoRouter(routes: [
  GoRoute(path: '/settings', routes: [
    GoRoute(path: 'logs', name: 'logs'),
    GoRoute(path: 'about'),
  ]),
]);

final headers = {'settings': 1, 'about': 2};
final link = context.namedLocation('logs');
''',
    });
    expect({
      for (final f in findings(index, 'route_without_navigation'))
        f['route']: f['otherReferences']
    }, {
      '/settings': 0,
      // The constant and the namedLocation call.
      '/settings/logs': 2,
      '/settings/about': 0,
    });
  });

  test('queries a route by name and lists dynamic sites with locations', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: pathFromServer(), name: 'remote')]);

class W extends StatelessWidget {
  W(this.target);
  final String target;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.goNamed('remote')),
        T(onTap: () => context.go(target)),
      ]);
}
''',
    });
    final result = query(index, 'remote');
    expect(result['registrations'], [
      {'at': 'lib/app.dart:1', 'name': 'remote'},
    ]);
    expect(result['candidates'], hasLength(1));
    expect(result['dynamicSites'], [
      {'at': 'lib/app.dart:8', 'expression': 'target'},
    ]);
  });

  test('reports an unreadable directory instead of stopping', () {
    final root = Directory.systemTemp.createTempSync('fcq_');
    addTearDown(() {
      Process.runSync('chmod', ['-R', '755', root.path]);
      root.deleteSync(recursive: true);
    });
    File('${root.path}/lib/app.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
          "final router = GoRouter(routes: [GoRoute(path: '/')]);");
    Directory('${root.path}/lib/locked').createSync();
    Process.runSync('chmod', ['000', '${root.path}/lib/locked']);
    final index = CodeIndex.build(root.path);
    expect(index.routes, hasLength(1));
    expect(index.parseErrors.single.at, 'lib/locked/');
  });
}
