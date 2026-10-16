import 'dart:io';

import 'package:flutter_code_query/flutter_code_query.dart';
import 'package:test/test.dart';

/// Cases where output looked complete but was not, from a README audit.
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

  Map<String, Object?> q(CodeIndex index, String route) => query(index, route);
  List<Map> candidates(CodeIndex index, String route) =>
      (q(index, route)['candidates'] as List).cast<Map>();
  List<Object?> symbols(Map candidate) =>
      [for (final h in candidate['hops'] as List) (h as Map)['symbol']];

  test('follows every caller of a helper that forwards the destination', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/p'), GoRoute(path: '/q')]);

class Page extends StatelessWidget {
  Widget build(BuildContext context) =>
      Column(children: [_section(context, '/p'), _section(context, '/q')]);
  Widget _section(BuildContext context, String location) =>
      _tile(context, location);
  Widget _tile(BuildContext context, String location) =>
      ListTile(onTap: () => context.go(location));
}
''',
    });
    expect(candidates(index, '/q'), hasLength(1));
  });

  test('signals builtBy paths past the limit as truncated', () {
    final index = project({
      'app.dart': '''
final router = GoRouter(routes: [${[
        for (var i = 1; i <= 22; i++) "GoRoute(path: '/r$i')"
      ].join(', ')}]);

class NavTile extends StatelessWidget {
  const NavTile({required this.to});
  final String to;
  Widget build(BuildContext context) => ListTile(onTap: () => context.go(to));
}

class Menu extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
${[for (var i = 1; i <= 22; i++) "        NavTile(to: '/r$i'),"].join('\n')}
      ]);
}
''',
    });
    expect(q(index, '/r22')['truncatedSites'], ['lib/app.dart:6']);
  });

  test('keeps a call site found only through another grafted chain', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c')]);

class Page extends StatelessWidget {
  Widget build(BuildContext context) => T(onPressed: () => y(context));
  void y(BuildContext context) {
    x(context);
    d(context, '/c');
  }
  void x(BuildContext context) {
    if (flag) {
      d(context, '/a');
    } else {
      d(context, '/b');
    }
  }
  void d(BuildContext context, String to) => context.go(to);
}
''',
    });
    for (final route in ['/a', '/b', '/c']) {
      expect(candidates(index, route), hasLength(1), reason: route);
    }
  });

  test('keeps dynamic widget instances next to literal ones', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);

class NavTile extends StatelessWidget {
  const NavTile({required this.to});
  final String to;
  Widget build(BuildContext context) => ListTile(onTap: () => context.go(to));
}

class Menu extends StatelessWidget {
  Menu(this.items);
  final List<String> items;
  Widget build(BuildContext context) => Column(children: [
        const NavTile(to: '/a'),
        for (final item in items) NavTile(to: item),
      ]);
}
''',
    });
    expect(candidates(index, '/a'), hasLength(1));
    expect(q(index, '/b')['dynamicSites'], isNotEmpty);
  });

  test('dispatches through implements, imports and declared types', () {
    final index = project({
      'nav_service.dart': r'''
abstract class NavService { void openCheckout(BuildContext context); }
class GoNavService implements NavService {
  void openCheckout(BuildContext context) => context.go('/checkout');
}
''',
      'orders/nav.dart':
          "void openDetail(BuildContext c) => c.go('/orders/detail');",
      'users/nav.dart':
          "void openDetail(BuildContext c) => c.go('/users/detail');",
      'flows.dart': r'''
class CartFlow { void open(BuildContext c) => c.go('/cart'); }
class WishFlow { void open(BuildContext c) => c.go('/wish'); }
''',
      'app.dart': r'''
import 'orders/nav.dart';

final router = GoRouter(routes: [
  GoRoute(path: '/checkout'), GoRoute(path: '/orders/detail'),
  GoRoute(path: '/users/detail'), GoRoute(path: '/cart'), GoRoute(path: '/wish'),
]);

class Page extends StatelessWidget {
  Page(this.flow);
  final CartFlow flow;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => getIt<NavService>().openCheckout(context)),
        T(onTap: () => openDetail(context)),
        T(onTap: () => flow.open(context)),
      ]);
}
''',
    });
    expect(symbols(candidates(index, '/checkout').single),
        ['Page.build', 'GoNavService.openCheckout']);
    expect(candidates(index, '/users/detail').single['root'],
        containsPair('kind', 'no_callers'));
    expect(symbols(candidates(index, '/cart').single),
        ['Page.build', 'CartFlow.open']);
    expect(candidates(index, '/wish').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('follows mixins of superclasses', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/z')]);

mixin Nav { void toZ(BuildContext c) => c.go('/z'); }
class Base {}
class Impl extends Base with Nav {}
class P extends Impl {
  Widget view(BuildContext context) => T(onTap: () => toZ(context));
}
class A { void toZ() {} }
class B { void toZ() {} }
class C { void toZ() {} }
''',
    });
    expect(symbols(candidates(index, '/z').single), ['P.view', 'Nav.toZ']);
  });

  test('names the condition of a choice held in a final local', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/admin'), GoRoute(path: '/home')]);

class Page extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () {
        final target = isAdmin ? '/admin' : '/home';
        context.go(target);
      });
}
''',
    });
    expect((candidates(index, '/admin').single['conditions'] as List).single,
        containsPair('expression', 'isAdmin'));
  });

  test('reports a destination a partly known route path might match', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/items/${Config.section}')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => context.go('/items/typo/extra'));
}
''',
    });
    final finding = (check(index)['findings'] as List)
        .cast<Map>()
        .singleWhere((f) => f['check'] == 'unknown_destination');
    expect(finding['severity'], 'info');
  });

  test('recognizes a GoRouter field and leaves its pop to go_router', () {
    final index = project({
      'app.dart': r'''
final appRouter = GoRouter(routes: [GoRoute(path: '/field'), GoRoute(path: '/p')]);

class Sheet { void pop(BuildContext c) => c.go('/p'); }

class Holder {
  final nav = appRouter;
  void fromField() => nav.go('/field');
  void close() => appRouter.pop();
}
''',
    });
    expect(candidates(index, '/field'), hasLength(1));
    expect(candidates(index, '/p').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('offers a templated destination to a static sibling route', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/items/new'), GoRoute(path: '/items/:id')]);

class W extends StatelessWidget {
  W(this.id);
  final String id;
  Widget build(BuildContext context) => T(onTap: () => context.go('/items/$id'));
}
''',
    });
    expect([
      for (final m in q(index, '/items/new')['prefixMatches'] as List)
        (m as Map)['knownPrefix']
    ], [
      '/items/'
    ]);
  });
}
