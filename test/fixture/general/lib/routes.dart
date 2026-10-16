enum AppRoute { home, profile, settings }

enum Section {
  docs('/docs');

  const Section(this.path);
  final String path;
}

class Paths {
  static String home = '/home';
  static String detail(String id) => '$home/detail/$id';
  static String get help => '/help';
}
