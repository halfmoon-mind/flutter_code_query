import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

void navigateTo(BuildContext context, String location, String id) {
  if (id.isEmpty) throw ArgumentError('id');
  context.push('$location?id=$id');
}

void reassigned(BuildContext context, String location) {
  location = '/somewhere';
  context.push(location);
}

/// Same private name as in home_screen.dart; library privacy keeps them apart.
void _goHome(BuildContext context) => context.go(RouteName.orphan);
