extension type const RouteInfo(String path) implements String {}

abstract final class RouteName {
  static const RouteInfo home = RouteInfo('/home');
  static const RouteInfo detail = RouteInfo('/detail');
  static const RouteInfo orphan = RouteInfo('/orphan');
  static const String settings = '/settings';
  static const String login = '/login';
  static const String profile = '/profile';
  static const String help = '/help';
}
