import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

final detailRoutesProvider = Provider<({String detail, String settings})>(
  (ref) => (detail: RouteName.detail, settings: RouteName.settings),
);

enum Kind { a, b }

class Base extends StatelessWidget {
  const Base({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class Patterns extends Base {
  const Patterns({super.key, required this.kind});

  final Kind kind;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Future.microtask(() => context.go(RouteName.login));
    return Consumer(builder: (context, ref, _) {
      final routes = ref.watch(detailRoutesProvider);
      return Column(children: [
        ListTile(
          onTap: switch (kind) {
            Kind.a => () => context.push(routes.settings),
            Kind.b => null,
          },
        ),
        ListTile(onTap: _openFor(context)),
      ]);
    });
  }

  VoidCallback _openFor(BuildContext context) =>
      () => context.push(RouteName.orphan);
}
