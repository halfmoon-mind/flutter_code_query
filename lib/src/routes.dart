part of 'index.dart';

/// Route registrations: constructor calls, subclasses, factories and shells.
extension _Routes on CodeIndex {
  /// Registrations are calls of `GoRoute` or of a project subclass of it. A
  /// route built inside a function or getter from its parameters, or with a
  /// relative path and no enclosing route there, is registered at each call
  /// of that function or getter instead, where its arguments and parent are.
  void _registerRoutes() {
    final routeClasses = {'GoRoute', 'TypedGoRoute'};
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

    void add(_Creation creation, SourceFile file, AstNode at, _Env env) {
      final (path, name) =
          _routeArguments(creation.className, creation.arguments, env, 0);
      final pathValue = path == null ? null : _evaluate(path.$1, path.$2);
      final nameValue = name == null ? null : _evaluate(name.$1, name.$2);
      final named = nameValue != null && !nameValue.isNull;
      routes.add(RouteDecl(file, at, creation.node, path?.$1,
          named ? name?.$1 : null, pathValue, named ? nameValue : null)
        ..typedClass = creation.className == 'TypedGoRoute'
            ? creation.typeArgument
            : null);
    }

    // [calls] reach the creation through functions or getters, innermost first.
    void register(_Creation creation, List<Ref> calls) {
      var env = _Env(calls.isEmpty ? creation.owner : calls.last.owner,
          calls.isEmpty ? creation.file : calls.last.file, const {});
      for (var i = calls.length - 1; i >= 0; i--) {
        env = _call(calls[i].arguments,
            i == 0 ? creation.owner! : calls[i - 1].owner!, env);
      }
      // A route built in a collection `for` over a list literal is one route
      // per element, registered at that element.
      if (calls.isEmpty) {
        if (_loopElements(creation.node, creation.owner, env, creationNodes)
            case final elements?) {
          for (final (bound, element) in elements) {
            add(creation, creation.file, element,
                _Env(env.owner, env.file, bound));
          }
          return;
        }
      }
      final (path, _) =
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
      // A route in a list a variable holds belongs where that variable is
      // used, as in `routes: childRoutes` under several parents.
      if (needsContext && calls.isEmpty) {
        final uses = _listUses(creation);
        if (uses.isNotEmpty) {
          for (final use in uses) {
            add(creation, use.file, use.node, env);
          }
          return;
        }
      }
      add(creation, calls.isEmpty ? creation.file : calls.last.file, at, env);
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
        copy.typedClass = route.typedClass;
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
    _registerShells();
  }

  /// One binding of the loop variable per element when [node] sits in a
  /// collection `for` over a list literal: `for (final item in items)` or
  /// `for (final (i, item) in items.indexed)`.
  List<(Map<String, (Expression, _Env)>, AstNode)>? _loopElements(
      AstNode node, Decl? owner, _Env env, Set<AstNode> routeNodes) {
    for (var up = node.parent;
        up != null && !identical(up, owner?.node);
        up = up.parent) {
      // A route nested in a looped route is registered under it instead.
      if (routeNodes.contains(up)) return null;
      if (up is! ForElement) continue;
      final parts = up.forLoopParts;
      final (String? name, Expression? iterable) = switch (parts) {
        ForEachPartsWithDeclaration p => (
            p.loopVariable.name.lexeme,
            p.iterable
          ),
        // Only `items.indexed` yields `(index, item)` records.
        ForEachPartsWithPattern(
          pattern: RecordPattern(fields: [_, final item]),
          iterable: PrefixedIdentifier(:final prefix, :final identifier)
        )
            when identifier.name == 'indexed' =>
          (_variable(item.pattern), prefix),
        ForEachPartsWithPattern(
          pattern: RecordPattern(fields: [_, final item]),
          iterable: PropertyAccess(:final realTarget, :final propertyName)
        )
            when propertyName.name == 'indexed' =>
          (_variable(item.pattern), realTarget),
        _ => (null, null),
      };
      final list =
          iterable == null ? null : _literalOf<ListLiteral>(iterable, env);
      if (name == null || list == null) return null;
      final (elements, _) = _elementsOf<Expression>(list.$1, list.$2);
      return [
        for (final (element, elementEnv, _) in elements)
          ({...env.arguments, name: (element, elementEnv)}, element),
      ];
    }
    return null;
  }

  /// The `GoRouter` or `RoutingConfig` call holding a top-level route, or else
  /// its top-level declaration: routes in different trees never conflict.
  AstNode? _tree(AstNode node) {
    for (AstNode? up = node.parent; up != null; up = up.parent) {
      final name = switch (up) {
        MethodInvocation m => m.methodName.name,
        InstanceCreationExpression c =>
          _typeName(c.constructorName.type.toSource()),
        _ => null,
      };
      if (name == 'GoRouter' || name == 'RoutingConfig') return up;
    }
    return null;
  }

  /// Uses of the variable whose list literal holds a route creation as an
  /// element, outside that variable's own declaration. A local is used only
  /// in its function.
  List<Ref> _listUses(_Creation creation) {
    for (AstNode? up = creation.node.parent; up != null; up = up.parent) {
      if (up is ListLiteral ||
          up is SpreadElement ||
          up is IfElement ||
          up is ForElement ||
          up is ParenthesizedExpression) {
        continue;
      }
      if (up is! VariableDeclaration) return const [];
      final declaration = up;
      final local = declaration.parent?.parent is VariableDeclarationStatement;
      final name = declaration.name.lexeme;
      bool inside(AstNode node) {
        for (AstNode? a = node; a != null; a = a.parent) {
          if (identical(a, declaration)) return true;
        }
        return false;
      }

      return [
        for (final ref in _refs[name] ?? const <Ref>[])
          if (ref.arguments == null &&
              !inside(ref.node) &&
              (local
                  ? ref.owner == creation.owner
                  : !name.startsWith('_') ||
                      ref.file.library == creation.file.library) &&
              switch (ref.target) {
                null => true,
                SimpleIdentifier t => _classes.contains(t.name),
                _ => false,
              })
            ref,
      ];
    }
    return const [];
  }

  /// The first route of each branch of each shell route, for
  /// `goBranch(index)`.
  void _registerShells() {
    for (final (file, _, branches) in _shellArguments) {
      final roots =
          <({RouteDecl? route, int first, int? last, bool conditional})>[];
      (int, int?) collect(List<CollectionElement> elements, _Env env, int first,
          int? last, bool conditional, int depth) {
        for (final element in elements) {
          if (element is IfElement) {
            final yes =
                collect([element.thenElement], env, first, last, true, depth);
            final no = collect([
              if (element.elseElement case final other?) other,
            ], env, first, last, true, depth);
            first = yes.$1 < no.$1 ? yes.$1 : no.$1;
            final a = yes.$2;
            final b = no.$2;
            last = a == null || b == null ? null : (a > b ? a : b);
          } else if (element is SpreadElement) {
            final list = depth < 4
                ? _literalOf<ListLiteral>(element.expression, env)
                : null;
            if (list == null) {
              last = null;
            } else {
              (first, last) = collect(list.$1.elements, list.$2, first, last,
                  conditional, depth + 1);
            }
          } else if (element is ForElement) {
            collect([element.body], env, first, null, true, depth);
            last = null;
          } else {
            roots.add((
              route: _branchRoute(env.file, element),
              first: first,
              last: last,
              conditional: conditional || first != last,
            ));
            first++;
            if (last != null) last++;
          }
        }
        return (first, last);
      }

      collect(branches.elements, _Env(null, file, const {}), 0, 0, false, 0);
      shells.add(roots);
    }
  }

  /// A branch's top route. Its routes may sit in a constant it names, as in
  /// `TypedStatefulShellBranch(routes: HomeRoute.routes)`.
  RouteDecl? _branchRoute(SourceFile file, AstNode element) {
    final ranges = [(file, element.offset, element.end)];
    final listed = switch (element) {
      MethodInvocation m => _named(m.argumentList, 'routes'),
      InstanceCreationExpression c => _named(c.argumentList, 'routes'),
      _ => null,
    };
    if (listed is Identifier) {
      if (_consts[listed.toSource()]?.singleOrNull case (final f, final e, _)) {
        ranges.add((f, e.offset, e.end));
      }
    }
    bool inside(RouteDecl? route) =>
        route != null &&
        ranges.any((r) =>
            route.file == r.$1 &&
            route.node.offset >= r.$2 &&
            route.node.end <= r.$3);
    return routes.where((r) => inside(r) && !inside(r.parent)).firstOrNull;
  }

  /// The `path` and `name` arguments a route constructor call passes on to
  /// `GoRoute`, following project subclass constructors.
  ((Expression, _Env)?, (Expression, _Env)?) _routeArguments(
      String className, ArgumentList arguments, _Env env, int depth) {
    (Expression, _Env)? named(String name) => switch (_named(arguments, name)) {
          final expression? => (expression, env),
          null => null,
        };
    if (className == 'GoRoute' || className == 'TypedGoRoute') {
      return (named('path'), named('name'));
    }
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

String? _variable(DartPattern pattern) => switch (pattern) {
      DeclaredVariablePattern p => p.name.lexeme,
      _ => null,
    };
