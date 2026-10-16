import 'package:go_router/go_router.dart' as go;

import 'routes.dart';

class FadeRoute extends go.GoRoute {
  FadeRoute(String path, {super.name, List<go.RouteBase> routes = const []})
      : super(path: path, routes: routes);
}

class ShortRoute extends go.GoRoute {
  ShortRoute({required super.path});
}

go.GoRoute _page({String? name, String? path}) =>
    go.GoRoute(path: path ?? (name != null ? '/$name' : '/'), name: name);

go.GoRoute get _detailRoute => go.GoRoute(path: 'detail/:id');

final router = go.GoRouter(routes: [
  FadeRoute(Paths.home, name: AppRoute.home.name, routes: [_detailRoute]),
  ShortRoute(path: '/profile'),
  _page(name: 'settings'),
  _page(path: '/docs/:page'),
  go.GoRoute(path: Section.docs.path),
  go.GoRoute(path: Paths.help),
  go.GoRoute(path: '/users/new'),
  go.GoRoute(path: '/users/:id'),
]);
