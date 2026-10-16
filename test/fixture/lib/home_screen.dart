import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'navigation.dart';
import 'router.dart';
import 'routes.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (canEdit)
        IconButton(
            onPressed: () => _openDetail(context, 'a'),
            icon: const Icon(Icons.add)),
      ListTile(onTap: canEdit ? _openSettings : null),
      TextButton(
        onPressed: () {
          if (!canEdit) return;
          context.push('/home/items/${DateTime.now()}');
        },
        child: const Text('item'),
      ),
      TextButton(
          onPressed: () => context.go('/missing'), child: const Text('x')),
      TextButton(
          onPressed: () => context.go(dynamicPath()), child: const Text('y')),
      TextButton(
          onPressed: () => Uri().replace(query: ''), child: const Text('z')),
      TextButton(onPressed: () => _goHome(context), child: const Text('h')),
    ]);
  }

  void _openDetail(BuildContext context, String id) {
    navigateTo(context, RouteName.detail, id);
  }

  void _openSettings() => router.go(RouteName.settings);
}

void _goHome(BuildContext context) => context.go(RouteName.home);

String dynamicPath() => DateTime.now().toString();
