part of 'index.dart';

/// Route registrations: constructor calls, subclasses, factories and shells.
extension _Routes on CodeIndex {
  /// Registrations are calls of `GoRoute` or of a project subclass of it. A
  /// route built inside a function or getter from its parameters, or with a
  /// relative path and no enclosing route there, is registered at each call
  /// of that function or getter instead, where its arguments and parent are.
  void _registerRoutes() {
    final routeClasses = {'GoRoute'};
    for (var grew = true; grew;) {
      grew = false;
      for (final MapEntry(:key, :value) in _superclasses.entries) {
        if (routeClasses.contains(value) && routeClasses.add(key)) grew = true;
      }
    }
    final creations = [
      for (final name in routeClasses) ...?_creations[name],
    ]..sort((a, b) => a.file.path == b.file.path
        ? a.node.offset.compareTo(b.node.offset)
        : a.file.path.compareTo(b.file.path));
    final creationNodes = {for (final c in creations) c.node};
    bool insideRoute(AstNode at, Decl? owner) {
      for (var up = at.parent;
          up != null && !identical(up, owner?.node);
          up = up.parent) {
        if (creationNodes.contains(up)) return true;
      }
      return false;
    }

    // [calls] reach the creation through functions or getters, innermost first.
    void register(_Creation creation, List<Ref> calls) {
      var env = _Env(calls.isEmpty ? creation.owner : calls.last.owner,
          calls.isEmpty ? creation.file : calls.last.file, const {});
      for (var i = calls.length - 1; i >= 0; i--) {
        env = _call(calls[i].arguments,
            i == 0 ? creation.owner! : calls[i - 1].owner!, env);
      }
      final (path, name) =
          _routeArguments(creation.className, creation.arguments, env, 0);
      final pathValue = path == null ? null : _evaluate(path.$1, path.$2);
      final at = calls.isEmpty ? creation.node : calls.last.node;
      final atOwner = calls.isEmpty ? creation.owner : calls.last.owner;
      final needsContext = pathValue != null &&
          (pathValue.unbound ||
              (!pathValue.text.startsWith('/') && !insideRoute(at, atOwner)));
      if (needsContext && atOwner != null && calls.length < 3) {
        final callers = [
          for (final (ref, _) in callersOf(atOwner))
            if (!calls.contains(ref)) ref,
        ];
        if (callers.isNotEmpty) {
          for (final ref in callers) {
            register(creation, [...calls, ref]);
          }
          return;
        }
      }
      final nameValue = name == null ? null : _evaluate(name.$1, name.$2);
      final named = nameValue != null && !nameValue.isNull;
      routes.add(RouteDecl(
          calls.isEmpty ? creation.file : calls.last.file,
          at,
          creation.node,
          path?.$1,
          named ? name?.$1 : null,
          pathValue,
          named ? nameValue : null));
    }

    for (final creation in creations) {
      register(creation, const []);
    }

    // A route's parent is the nearest enclosing registration, or every
    // registration of an enclosing route built by a function or getter.
    final byAt = <AstNode, List<RouteDecl>>{};
    final byOrigin = <AstNode, List<RouteDecl>>{};
    for (final route in routes) {
      (byAt[route.node] ??= []).add(route);
      if (!identical(route.node, route.origin)) {
        (byOrigin[route.origin] ??= []).add(route);
      }
    }
    List<RouteDecl> parentsOf(RouteDecl route) {
      for (var up = route.node.parent; up != null; up = up.parent) {
        final found = [...?byAt[up], ...?byOrigin[up]]..remove(route);
        if (found.isNotEmpty) return found;
      }
      return const [];
    }

    // Every full path a route can have, or its known start when incomplete.
    final memo = <RouteDecl, List<(String?, bool, RouteDecl?)>>{};
    List<(String?, bool, RouteDecl?)> full(RouteDecl route, int depth) =>
        memo[route] ??= () {
          final value = route._pathValue;
          if (value == null || depth > 32) return [(null, false, null)];
          if (value.text.startsWith('/')) {
            return [(value.text, value.complete, null)];
          }
          final parents = parentsOf(route);
          if (parents.isEmpty) return [(null, false, null)];
          return [
            for (final parent in parents)
              for (final (path, complete, _) in full(parent, depth + 1))
                if (path == null || !complete)
                  (null, false, parent)
                else
                  (
                    path == '/' ? '/${value.text}' : '$path/${value.text}',
                    value.complete,
                    parent,
                  ),
          ];
        }();

    final expanded = <RouteDecl>[];
    for (final route in routes) {
      for (final (i, (path, complete, parent)) in full(route, 0).indexed) {
        final copy = i == 0 ? route : RouteDecl._copy(route);
        copy.parent = parent;
        copy.path = complete ? path : null;
        copy.pathPrefix = complete ? null : path;
        if (route._nameValue case final name? when name.complete) {
          copy.name = name.text;
        }
        expanded.add(copy);
      }
    }
    routes
      ..clear()
      ..addAll(expanded);
    for (final route in routes) {
      var top = route;
      for (var i = 0; top.parent != null && i < 32; i++) {
        top = top.parent!;
      }
      route.tree = _tree(top.node);
    }
    _registerShells(byAt, byOrigin);
  }

  /// The `GoRouter` or `RoutingConfig` call holding a top-level route, or else
  /// its top-level declaration: routes in different trees never conflict.
  AstNode? _tree(AstNode node) {
    AstNode? declaration;
    for (AstNode? up = node.parent; up != null; up = up.parent) {
      final name = switch (up) {
        MethodInvocation m => m.methodName.name,
        InstanceCreationExpression c =>
          _typeName(c.constructorName.type.toSource()),
        _ => null,
      };
      if (name == 'GoRouter' || name == 'RoutingConfig') return up;
      if (up is CompilationUnitMember) declaration = up;
    }
    return declaration;
  }

  /// The first route of each branch of each `StatefulShellRoute`, for
  /// `goBranch(index)`.
  void _registerShells(Map<AstNode, List<RouteDecl>> byAt,
      Map<AstNode, List<RouteDecl>> byOrigin) {
    for (final (file, _, branches) in _shellArguments) {
      shells.add([
        for (final element in branches.elements)
          [
            for (final route in routes)
              if (route.file == file &&
                  route.node.offset >= element.offset &&
                  route.node.end <= element.end &&
                  !(route.parent != null &&
                      route.parent!.file == file &&
                      route.parent!.node.offset >= element.offset &&
                      route.parent!.node.end <= element.end))
                route,
          ].firstOrNull,
      ]);
    }
  }

  /// The `path` and `name` arguments a route constructor call passes on to
  /// `GoRoute`, following project subclass constructors.
  ((Expression, _Env)?, (Expression, _Env)?) _routeArguments(
      String className, ArgumentList arguments, _Env env, int depth) {
    (Expression, _Env)? named(String name) => switch (_named(arguments, name)) {
          final expression? => (expression, env),
          null => null,
        };
    if (className == 'GoRoute') return (named('path'), named('name'));
    final superclass = _superclasses[className];
    final constructor = _constructor(className);
    if (superclass == null || constructor == null || depth > 4) {
      return (null, null);
    }
    final inner = _call(arguments, constructor, env);
    final node = constructor.node as ConstructorDeclaration;
    final superCall =
        node.initializers.whereType<SuperConstructorInvocation>().firstOrNull;
    var (path, name) = superCall == null
        ? (null, null)
        : _routeArguments(superclass, superCall.argumentList, inner, depth + 1);
    if (superclass == 'GoRoute') {
      // `super.path` forwards the argument of the same name.
      for (final parameter in node.parameters.parameters) {
        final formal = parameter is DefaultFormalParameter
            ? parameter.parameter
            : parameter;
        if (formal is! SuperFormalParameter) continue;
        final bound = inner.arguments[formal.name.lexeme];
        if (formal.name.lexeme == 'path') path ??= bound;
        if (formal.name.lexeme == 'name') name ??= bound;
      }
    }
    return (path, name);
  }

  /// The unnamed constructor of [className].
  Decl? _constructor(String? className) => [
        for (final d in _decls[className] ?? const <Decl>[])
          if (d.className == className &&
              d.node is ConstructorDeclaration &&
              (d.node as ConstructorDeclaration).name == null)
            d,
      ].firstOrNull;
}

bool _matches(String? pattern, String location) {
  if (pattern == null || !pattern.contains(':')) return false;
  final regex = pattern
      .split('/')
      .map((s) => s.startsWith(':') ? '[^/]+' : RegExp.escape(s))
      .join('/');
  return RegExp('^$regex\$').hasMatch(location);
}

/// Whether location segments with unknown parts can match a route's path
/// segments. A wholly unknown segment matches only a `:param` segment.
bool _fits(List<String> wanted, List<String> have) {
  if (wanted.length != have.length) return false;
  for (var i = 0; i < wanted.length; i++) {
    final want = wanted[i];
    final segment = have[i];
    if (want == segment) continue;
    if (segment.startsWith(':')) {
      if (want.isEmpty) return false;
      continue;
    }
    if (!want.contains(hole) || want.replaceAll(hole, '').isEmpty) {
      return false;
    }
    final regex = want.split(hole).map(RegExp.escape).join('.*');
    if (!RegExp('^$regex\$').hasMatch(segment)) return false;
  }
  return true;
}
