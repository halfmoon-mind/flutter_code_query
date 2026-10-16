import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'patterns.dart';
import 'router.dart';
import 'routes.dart';

class DetailController {
  DetailController(this.context);

  final BuildContext context;

  void open() => context.push(RouteName.profile);
}

class TearOffs extends StatelessWidget {
  const TearOffs({super.key, required this.controller, required this.kind});

  final DetailController controller;
  final Kind kind;

  @override
  Widget build(BuildContext context) => Column(children: [
        ListTile(onTap: controller.open),
        ListTile(
          onTap: switch (kind) {
            Kind.a => _help,
            Kind.b => null,
          },
        ),
      ]);

  void _help() => router.go(RouteName.help);
}
