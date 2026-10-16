import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

extension Nav on BuildContext {
  void openHelp() => go(Paths.help);
}

mixin Opener {
  void openProfile(BuildContext context) => context.push('/profile');
}

enum Kind { a, b, c }

class Screens extends StatelessWidget with Opener {
  const Screens(
      {super.key, required this.ready, required this.items, this.onDone});

  final bool ready;
  final List<String> items;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) => Column(children: [
        TextButton(
            onPressed: () => context.goNamed(AppRoute.home.name),
            child: const Text('home')),
        TextButton(
            onPressed: () => openProfile(context),
            child: const Text('profile')),
        if (ready) _tile(context, '/users/new'),
        for (final id in items) _tile(context, Paths.detail(id)),
        TextButton(
            onPressed: onDone ?? () => context.go('/docs'),
            child: const Text('docs')),
        TextButton(onPressed: context.openHelp, child: const Text('help')),
        TextButton(
            onPressed: () => context.go('/users/42'),
            child: const Text('user')),
      ]);

  Widget _tile(BuildContext context, String location) =>
      ListTile(onTap: () => context.go(location));
}

class Menu extends StatelessWidget {
  const Menu({super.key, required this.kind, required this.ok});

  final Kind kind;
  final bool ok;

  @override
  Widget build(BuildContext context) => ListTile(
        onTap: switch (kind) {
          Kind.a when !ok => null,
          Kind.a => () => context.go('/profile'),
          _ => null,
        },
      );
}

void handle(BuildContext context, Kind kind, bool ok) {
  switch (kind) {
    case Kind.a:
    case Kind.b:
      if (!ok) return;
      context.go('/settings');
    case Kind.c:
      break;
  }
}

void guarded(BuildContext context, bool a) {
  if (a) {
    return;
  } else {
    debugPrint('not a');
  }
  context.go('/settings');
}
