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

  test('keeps same-name project callers separate from router calls', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);
class First {
  void go(BuildContext context) => context.push('/a');
}
class Second {
  void go(BuildContext context) => context.push('/b');
}
class Menu {
  Widget build(BuildContext context) => Column(children: [
    T(onTap: () => First().go(context)),
    T(onTap: () => Second().go(context)),
    T(onTap: () => First().go(context)),
    T(onTap: () => context.go('/a')),
  ]);
}
''',
    });
    final first = candidates(index, '/a');
    expect([
      for (final c in first) symbols(c)
    ], [
      ['Menu.build', 'First.go'],
      ['Menu.build', 'First.go'],
      ['Menu.build'],
    ]);
    expect([for (final c in first) (c['root'] as Map)['at']],
        ['lib/app.dart:10', 'lib/app.dart:12', 'lib/app.dart:13']);
    expect([
      for (final c in candidates(index, '/b')) symbols(c)
    ], [
      ['Menu.build', 'Second.go'],
    ]);
    expect(candidates(index, '/a'), first);
  });

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

  test('indexes a list through spreads and doubts it past an if element', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b'), GoRoute(path: '/c')]);

class Tab { const Tab(this.route); final String route; }

class W extends StatelessWidget {
  static const tabs = [Tab('/a'), ...[Tab('/b')], Tab('/c')];
  static const optional = [Tab('/a'), if (beta) Tab('/b'), Tab('/c')];
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => context.go(tabs[1].route)),
        T(onTap: () => context.go(optional[1].route)),
      ]);
}
''',
    });
    expect([
      for (final c in candidates(index, '/b')) c['destination']
    ], [
      {'expression': 'tabs[1].route', 'value': '/b'},
      {'expression': 'optional[1].route', 'value': '/b', 'alternative': true},
    ]);
    expect(q(index, '/c')['dynamicSites'], isNotEmpty);
  });

  test('links an import-prefixed call only into that library', () {
    final index = project({
      'b.dart': "void open(BuildContext c) => c.go('/b');",
      'other.dart': "void open(BuildContext c) => c.go('/other');",
      'app.dart': r'''
import 'b.dart' as b;

final router = GoRouter(routes: [GoRoute(path: '/b'), GoRoute(path: '/other')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => b.open(context));
}
''',
    });
    expect(symbols(candidates(index, '/b').single), ['W.build', 'open']);
    expect(candidates(index, '/other').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('links an unprefixed call only through unprefixed imports', () {
    final index = project({
      'b.dart': "void open(BuildContext c) => c.go('/b');",
      'other.dart': "void open(BuildContext c) => c.go('/other');",
      'app.dart': r'''
import 'b.dart' as b;
import 'other.dart';

final router = GoRouter(routes: [GoRoute(path: '/b'), GoRoute(path: '/other')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => open(context));
}
''',
    });
    expect(symbols(candidates(index, '/other').single), ['W.build', 'open']);
    expect(candidates(index, '/b').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('follows exports of a library imported with a prefix', () {
    final index = project({
      'nav/open.dart': "void open(BuildContext c) => c.go('/a');",
      'nav/barrel.dart': "export 'open.dart';",
      'other.dart': "void open(BuildContext c) => c.go('/b');",
      'app.dart': r'''
import 'nav/barrel.dart' as nav;

final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => T(onTap: () => nav.open(context));
}
''',
    });
    expect(symbols(candidates(index, '/a').single), ['W.build', 'open']);
    expect(candidates(index, '/b').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('applies show and hide of imports and exports', () {
    final index = project({
      'a.dart': r'''
void open(BuildContext c) => c.go('/a');
const kHome = '/a';
''',
      'b.dart': r'''
void open(BuildContext c) => c.go('/b');
const kHome = '/b';
''',
      'barrel.dart': "export 'a.dart' hide open;\nexport 'b.dart' show open;",
      'app.dart': r'''
import 'barrel.dart' as nav;

final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);

class W extends StatelessWidget {
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => nav.open(context)),
        T(onTap: () => context.go(nav.kHome)),
      ]);
}
''',
    });
    expect(symbols(candidates(index, '/b').single), ['W.build', 'open']);
    expect(
        [for (final c in candidates(index, '/a')) (c['root'] as Map)['kind']],
        unorderedEquals(['callback', 'no_callers']));
    expect(
        candidates(index, '/a').where(
            (c) => (c['destination'] as Map)['expression'] == 'nav.kHome'),
        hasLength(1));
  });

  test('follows super calls along the mixin order', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a')]);

abstract class Base { void open(BuildContext c); }
mixin A on Base { void open(BuildContext c) => c.go('/a'); }
mixin B on Base { void open(BuildContext c) => super.open(c); }
class Flow extends Base with A, B {}
class Fast extends Flow { void open(BuildContext c) => super.open(c); }

class W extends StatelessWidget {
  W(this.flow);
  final Flow flow;
  Widget build(BuildContext context) => T(onTap: () => flow.open(context));
}
''',
    });
    expect(
        [for (final c in candidates(index, '/a')) symbols(c)],
        unorderedEquals([
          ['W.build', 'B.open', 'A.open'],
          ['W.build', 'Fast.open', 'B.open', 'A.open'],
        ]));
  });

  test('keeps the class applying a mixin with its super call', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/c')]);

abstract class Base { void open(BuildContext c); }
mixin A on Base { void open(BuildContext c) => c.go('/a'); }
mixin C on Base { void open(BuildContext c) => c.go('/c'); }
mixin B on Base { void open(BuildContext c) => super.open(c); void again(BuildContext c) => open(c); }
class F1 extends Base with A, B {}
class F2 extends Base with C, B {}

class W extends StatelessWidget {
  W(this.f1, this.f2);
  final F1 f1;
  final F2 f2;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => f1.open(context)),
        T(onTap: () => f2.open(context)),
        T(onTap: () => f1.again(context)),
        T(onTap: () => f2.again(context)),
      ]);
}
''',
    });
    List<Object?> roots(String route) =>
        [for (final c in candidates(index, route)) (c['root'] as Map)['at']];
    expect(
        roots('/a'), unorderedEquals(['lib/app.dart:15', 'lib/app.dart:17']));
    expect(
        roots('/c'), unorderedEquals(['lib/app.dart:16', 'lib/app.dart:18']));
  });

  test('keeps the applying class across chained mixin super calls', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/c')]);

abstract class Base { void open(BuildContext c); }
mixin A on Base { void open(BuildContext c) => c.go('/a'); }
mixin C on Base { void open(BuildContext c) => c.go('/c'); }
mixin X on Base { void open(BuildContext c) => super.open(c); }
mixin B on Base { void open(BuildContext c) => super.open(c); }
class F1 extends Base with A, X, B {}
class F2 extends Base with C, X, B {}

class W extends StatelessWidget {
  W(this.f1, this.f2);
  final F1 f1;
  final F2 f2;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => f1.open(context)),
        T(onTap: () => f2.open(context)),
      ]);
}
''',
    });
    List<Object?> roots(String route) =>
        [for (final c in candidates(index, route)) (c['root'] as Map)['at']];
    expect(roots('/a'), ['lib/app.dart:16']);
    expect(roots('/c'), ['lib/app.dart:17']);
  });

  test('runs a mixin super call only in classes that inherit its code', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/c')]);

abstract class Base { void open(BuildContext c); }
mixin A on Base { void open(BuildContext c) => c.go('/a'); }
mixin C on Base { void open(BuildContext c) => c.go('/c'); }
mixin B on Base { void open(BuildContext c) => super.open(c); }
class F1 extends Base with A, B {}
class F2 extends Base with C, B implements F1 {}

class W extends StatelessWidget {
  W(this.f1, this.f2);
  final F1 f1;
  final F2 f2;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => f1.open(context)),
        T(onTap: () => f2.open(context)),
      ]);
}
''',
    });
    List<Object?> roots(String route) =>
        [for (final c in candidates(index, route)) (c['root'] as Map)['at']];
    // An F2 never runs A's open; an F1 field can hold an F2, which runs C's.
    expect(roots('/a'), ['lib/app.dart:15']);
    expect(
        roots('/c'), unorderedEquals(['lib/app.dart:15', 'lib/app.dart:16']));
  });

  test('keeps a mixin super call reached through an interface', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a')]);

abstract class Flow { void open(BuildContext c); }
abstract class Base { void open(BuildContext c); }
mixin A on Base { void open(BuildContext c) => c.go('/a'); }
mixin B on Base { void open(BuildContext c) => super.open(c); }
class F1 extends Base with A, B implements Flow {
  void open(BuildContext c) => super.open(c);
}

class W extends StatelessWidget {
  W(this.flow);
  final Flow flow;
  Widget build(BuildContext context) => T(onTap: () => flow.open(context));
}
''',
    });
    expect(symbols(candidates(index, '/a').single),
        ['W.build', 'F1.open', 'B.open', 'A.open']);
  });

  test('finds extension members on an interface of the declared type', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/x')]);

abstract class Flow {}
class CartFlow implements Flow {}
extension FlowNav on Flow { void openX(BuildContext c) => c.go('/x'); }

class W extends StatelessWidget {
  W(this.flow);
  final CartFlow flow;
  Widget build(BuildContext context) => T(onTap: () => flow.openX(context));
}
''',
    });
    expect(
        symbols(candidates(index, '/x').single), ['W.build', 'FlowNav.openX']);
  });

  test('dispatches an inherited member only to overrides below the caller', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/base'), GoRoute(path: '/fast'), GoRoute(path: '/other')]);

class Base { void open(BuildContext c) => c.go('/base'); }
class Flow extends Base {
  Widget view(BuildContext context) => T(onTap: () => open(context));
}
class FastFlow extends Flow { void open(BuildContext c) => c.go('/fast'); }
class Other extends Base { void open(BuildContext c) => c.go('/other'); }

class W extends StatelessWidget {
  W(this.flow);
  final Flow flow;
  Widget build(BuildContext context) => T(onTap: () => flow.open(context));
}
''',
    });
    expect(candidates(index, '/base'), hasLength(2));
    expect(candidates(index, '/fast'), hasLength(2));
    expect(candidates(index, '/other').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('looks a member up in the last applied mixin first', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/a'), GoRoute(path: '/b')]);

mixin A { void open(BuildContext c) => c.go('/a'); }
mixin B { void open(BuildContext c) => c.go('/b'); }
class Flow with A, B {
  Widget view(BuildContext context) => T(onTap: () => open(context));
}

class W extends StatelessWidget {
  W(this.flow);
  final Flow flow;
  Widget build(BuildContext context) => T(onTap: () => flow.open(context));
}
''',
    });
    expect(candidates(index, '/b'), hasLength(2));
    expect(candidates(index, '/a').single['root'],
        containsPair('kind', 'no_callers'));
  });

  test('finds inherited and extension members of a declared type', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [GoRoute(path: '/x'), GoRoute(path: '/y')]);

class Base { void open(BuildContext c) => c.go('/x'); }
class Flow extends Base {}
extension FlowNav on Flow { void openY(BuildContext c) => c.go('/y'); }

class W extends StatelessWidget {
  W(this.flow);
  final Flow flow;
  Widget build(BuildContext context) => Column(children: [
        T(onTap: () => flow.open(context)),
        T(onTap: () => flow.openY(context)),
      ]);
}
''',
    });
    expect(symbols(candidates(index, '/x').single), ['W.build', 'Base.open']);
    expect(
        symbols(candidates(index, '/y').single), ['W.build', 'FlowNav.openY']);
  });

  test('keeps routes nested in a looped route under each of its copies', () {
    final index = project({
      'app.dart': r'''
final router = GoRouter(routes: [
  for (final p in ['/a', '/b'])
    GoRoute(path: p, routes: [GoRoute(path: 'detail')]),
]);
''',
    });
    expect([
      for (final r in routeList(index)['routes'] as List) (r as Map)['path']
    ], unorderedEquals(['/a', '/b', '/a/detail', '/b/detail']));
  });
}
