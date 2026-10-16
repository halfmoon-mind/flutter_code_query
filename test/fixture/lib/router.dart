import 'package:go_router/go_router.dart';

import 'home_screen.dart';
import 'routes.dart';

final router = GoRouter(
  redirect: (context, state) => state.uri.path == '/' ? RouteName.login : null,
  routes: [
    GoRoute(
      path: RouteName.home,
      builder: (context, state) => const HomeScreen(canEdit: true),
      routes: [
        GoRoute(path: 'items/:id', builder: (context, state) => const Item()),
      ],
    ),
    GoRoute(
        path: RouteName.detail, builder: (context, state) => const Detail()),
    GoRoute(
        path: RouteName.orphan, builder: (context, state) => const Orphan()),
    GoRoute(
        path: RouteName.settings,
        builder: (context, state) => const Settings()),
    GoRoute(path: RouteName.login, builder: (context, state) => const Login()),
    GoRoute(
        path: RouteName.profile, builder: (context, state) => const Profile()),
    GoRoute(path: RouteName.help, builder: (context, state) => const Help()),
    GoRoute(
        path: RouteName.detail, builder: (context, state) => const Detail()),
  ],
);
