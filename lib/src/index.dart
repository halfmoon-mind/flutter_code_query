import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// go_router methods whose first positional argument is a location.
const _locationMethods = {'go', 'push', 'pushReplacement', 'replace'};

/// go_router methods whose first positional argument is a route name.
const _nameMethods = {
  'goNamed',
  'pushNamed',
  'pushReplacementNamed',
  'replaceNamed',
};

/// Called by the framework, so having no callers in the project is expected.
const _frameworkMethods = {
  'build',
  'initState',
  'didChangeDependencies',
  'didUpdateWidget',
  'activate',
  'deactivate',
  'dispose',
  'createState',
  // Action<Intent>.invoke and WidgetsBindingObserver callbacks.
  'invoke',
  'didChangeAppLifecycleState',
  'didPopRoute',
  'didPushRoute',
  'didPushRouteInformation',
};

const maxChainsPerSite = 200;

/// Calls of a widget-building declaration followed to find where a callback
/// root is bound.
const maxBuildPaths = 20;

/// An untyped call `x.m()` links to the declarations named `m` only up to this
/// many; past it the name says nothing about the target.
const maxNameMatches = 3;
const maxChainLength = 12;

/// Values a conditional, a switch or a function with several returns can
/// produce before the destination counts as unknown.
const maxAlternatives = 16;

/// Stands for an unknown part of an evaluated string.
const hole = '\u0000';

final _generated =
    RegExp(r'GENERATED.{0,20}DO NOT MODIFY', caseSensitive: false);
final _slotName = RegExp(r'^on[A-Z]');
final _upper = RegExp('^[A-Z]');

class SourceFile {
  SourceFile(this.path, this.library, this.content, this.unit, this.lineInfo);

  /// Relative to the project root.
  final String path;

  /// Path of the library this file belongs to (differs for `part` files).
  final String library;
  final String content;
  final CompilationUnit unit;
  final LineInfo lineInfo;

  String at(AstNode node) =>
      '$path:${lineInfo.getLocation(node.offset).lineNumber}';
}

/// A named function body: method, function, constructor or local function.
class Decl {
  Decl(this.file, this.node, this.name, this.className, this.parent);

  final SourceFile file;
  final AstNode node;
  final String name;
  final String? className;

  /// The enclosing declaration of a local function.
  final Decl? parent;

  Decl get root => parent?.root ?? this;
  String get symbol =>
      [parent?.symbol ?? className, name].whereType<String>().join('.');

  FormalParameterList? get parameters => switch (node) {
        MethodDeclaration n => n.parameters,
        FunctionDeclaration n => n.functionExpression.parameters,
        ConstructorDeclaration n => n.parameters,
        _ => null,
      };

  late final _Scope _scope = _Scope()..collect(node);
}

/// A call or tear-off of a project declaration, matched by name.
class Ref {
  Ref(this.file, this.node, this.name, this.owner, this.className, this.target,
      this.arguments,
      {this.creation = false});

  final SourceFile file;

  /// A [MethodInvocation], a constructor call, or a [SimpleIdentifier] for a
  /// tear-off.
  final AstNode node;
  final String name;
  final Decl? owner;

  /// The enclosing class, also for a field initializer without [owner].
  final String? className;
  final Expression? target;

  /// Null for a tear-off.
  final ArgumentList? arguments;

  /// A widget constructor call, standing for a call of that widget's `build`.
  final bool creation;
}

class NavigationSite {
  NavigationSite(this.file, this.node, this.owner, this.className, this.kind);

  final SourceFile file;
  final MethodInvocation node;
  final Decl? owner;
  final String? className;

  /// `location` (`go`, `push`...), `name` (`goNamed`...) or `branch`
  /// (`goBranch`).
  final String kind;

  bool get named => kind == 'name';

  Expression get destination =>
      node.argumentList.arguments.firstWhere((a) => a is! NamedExpression);
}

class RouteDecl {
  RouteDecl(this.file, this.node, this.origin, this.pathExpression,
      this.nameExpression, this._pathValue, this._nameValue);

  RouteDecl._copy(RouteDecl r)
      : this(r.file, r.node, r.origin, r.pathExpression, r.nameExpression,
            r._pathValue, r._nameValue);

  final SourceFile file;

  /// The registration: a route constructor call, or the call of a function or
  /// getter that builds the route from its arguments.
  final AstNode node;

  /// The route constructor call itself.
  final AstNode origin;
  final Expression? pathExpression;
  final Expression? nameExpression;
  final Evaluation? _pathValue;
  final Evaluation? _nameValue;
  RouteDecl? parent;

  /// The router configuration the route belongs to.
  AstNode? tree;

  /// Full path with parent paths joined; null when it cannot be evaluated.
  String? path;

  /// The known start of a [path] that could not be evaluated in full.
  String? pathPrefix;
  String? name;
}

/// One hop of an incoming chain. Every hop except the last is a [ref] that
/// invokes the next hop's [owner].
class Hop {
  Hop(this.file, this.node, this.owner,
      {this.className, this.ref, this.matches = 1, this.guessed = false});

  final SourceFile file;
  final AstNode node;
  final Decl? owner;
  final String? className;
  final Ref? ref;

  /// Whether the link was matched by name alone (an untyped receiver), and how
  /// many declarations share that name.
  final bool guessed;
  final int matches;
}

class Chain {
  Chain(this.hops, this.rootKind, this.slot, [this.slotNode]);

  final List<Hop> hops;

  /// callback, callback_factory, framework, entry_point, initializer,
  /// ambiguous_callers, no_callers, no_owner, cycle or depth_limit.
  final String rootKind;
  final String? slot;

  /// The closure, tear-off or factory call bound to [slot].
  final AstNode? slotNode;
}

class Evaluation {
  const Evaluation(this.text, this.complete,
      {this.forwarded = false,
      this.reason,
      this.isNull = false,
      this.unbound = false,
      String? pattern,
      this.holes = const [],
      this.alternatives})
      : _pattern = pattern;

  Evaluation.unknown(String source, String this.reason)
      : text = '',
        complete = false,
        forwarded = false,
        isNull = false,
        unbound = reason == 'unbound_parameter',
        _pattern = hole,
        holes = [_short(source, 40)],
        alternatives = null;

  /// Several possible values, flattened and deduplicated.
  factory Evaluation.of(Iterable<Evaluation> options) {
    final unique = <String, Evaluation>{};
    for (final option in options) {
      for (final value in option.expand()) {
        unique.putIfAbsent(
            '${value.complete}${value.isNull}${value.pattern}', () => value);
      }
    }
    final values = unique.values.toList();
    if (values.length == 1) return values.single;
    if (values.length > maxAlternatives) {
      return Evaluation.unknown('…', 'alternatives');
    }
    return Evaluation('', false,
        reason: 'alternatives',
        unbound: values.any((v) => v.unbound),
        pattern: hole,
        holes: const ['…'],
        alternatives: values);
  }

  /// An omitted argument without a default, or a `null` literal.
  static const nullValue =
      Evaluation('', false, reason: 'null_value', isNull: true);

  /// The known start of the value: everything before the first unknown part.
  final String text;
  final bool complete;
  final bool forwarded;
  final String? reason;
  final bool isNull;

  /// Whether some unknown part is a parameter no call has bound.
  final bool unbound;
  final String? _pattern;

  /// Sources of the unknown parts, in order.
  final List<String> holes;
  final List<Evaluation>? alternatives;

  /// The value with [hole] for each unknown part.
  String get pattern => _pattern ?? (complete ? text : '$text$hole');

  List<Evaluation> expand() => alternatives ?? [this];

  Evaluation get asForwarded => alternatives == null
      ? Evaluation(text, complete,
          forwarded: true,
          reason: reason,
          isNull: isNull,
          unbound: unbound,
          pattern: _pattern,
          holes: holes)
      : Evaluation.of([for (final a in alternatives!) a.asForwarded]);

  /// The value with each unknown part shown as `{source}`.
  String get display {
    var i = 0;
    return pattern.replaceAllMapped(
        hole, (_) => '{${i < holes.length ? holes[i++] : '…'}}');
  }

  /// The absolute location path, once a query or fragment makes later
  /// content irrelevant. Null for a relative or unknown location.
  String? get path {
    final cut = text.indexOf(RegExp('[?#]'));
    final path = cut >= 0
        ? text.substring(0, cut)
        : complete
            ? text
            : null;
    return path != null && path.startsWith('/') ? path : null;
  }

  /// The absolute path with [hole] for unknown parts, when it has any.
  String? get pathPattern {
    if (alternatives != null || complete) return null;
    var value = pattern;
    final cut = value.indexOf(RegExp('[?#]'));
    if (cut >= 0) value = value.substring(0, cut);
    return value.startsWith('/') && value.contains(hole) ? value : null;
  }
}

class CodeIndex {
  CodeIndex(this.root);

  final String root;
  final files = <SourceFile>[];
  final routes = <RouteDecl>[];
  final navigations = <NavigationSite>[];

  /// Each `StatefulShellRoute`'s branches, as the first route of each.
  final shells = <List<RouteDecl?>>[];

  /// The first syntax error per file. Such a file is only partly indexed, for
  /// example when the app uses newer Dart syntax than this package's analyzer
  /// parses. Unreadable files and directories appear here too.
  final parseErrors = <({String at, String message})>[];

  /// Symbolic links under `lib`, which are not followed.
  var skippedLinks = 0;

  final _decls = <String, List<Decl>>{};
  final _refs = <String, List<Ref>>{};
  final _refByNode = <AstNode, Ref>{};
  final _consts = <String, List<(SourceFile, Expression, String?)>>{};
  final _classes = <String>{};
  final _superclasses = <String, String>{};
  final _subclasses = <String, List<String>>{};
  final _mixins = <String, List<String>>{};
  final _stateOf = <String, String>{};
  final _routerFields = <String>{};
  final _imports = <String, Set<String>>{};
  final _creations = <String, List<_Creation>>{};
  final _shellArguments = <(SourceFile, AstNode, ListLiteral)>[];
  final _candidates =
      <(SourceFile, MethodInvocation, Decl?, String?, String, bool)>[];
  final _enumConstants = <String, (SourceFile, EnumConstantDeclaration)>{};
  final _callees = <Ref, List<Decl>>{};
  final _callers = <Decl, List<(Ref, int)>>{};
  final _ambiguous = <Ref>{};
  final _guessed = <Ref>{};

  /// Parses every non-generated Dart file under `lib`; nothing is resolved.
  static CodeIndex build(String root) {
    final index = CodeIndex(root);
    final paths = <String>[];
    void walk(Directory directory) {
      final List<FileSystemEntity> entries;
      try {
        entries = directory.listSync(followLinks: false);
      } on FileSystemException catch (error) {
        index.parseErrors.add((
          at: '${p.relative(directory.path, from: root)}/',
          message: error.message,
        ));
        return;
      }
      for (final entry in entries) {
        if (entry is Link) {
          index.skippedLinks++;
        } else if (entry is Directory) {
          walk(entry);
        } else if (entry is File &&
            entry.path.endsWith('.dart') &&
            !entry.path.endsWith('.g.dart') &&
            !entry.path.endsWith('.freezed.dart')) {
          paths.add(entry.path);
        }
      }
    }

    walk(Directory(p.join(root, 'lib')));
    paths.sort();
    final package = _packageName(root);
    final featureSet = FeatureSet.latestLanguageVersion();
    final parsed = <(String, String, CompilationUnit, LineInfo)>[];
    for (final path in paths) {
      final relative = p.relative(path, from: root);
      final String content;
      try {
        content =
            utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
      } on FileSystemException catch (error) {
        index.parseErrors.add((at: '$relative:1', message: error.message));
        continue;
      }
      final head = content.length < 400 ? content : content.substring(0, 400);
      if (_generated.hasMatch(head)) continue;
      final ParseStringResult result;
      try {
        result = parseString(
          content: content,
          path: path,
          featureSet: featureSet,
          throwIfDiagnostics: false,
        );
      } catch (error) {
        // Some analyzer versions throw on odd input instead of reporting it.
        index.parseErrors.add((at: '$relative:1', message: '$error'));
        continue;
      }
      if (result.errors.firstOrNull case final error?) {
        final line = result.lineInfo.getLocation(error.offset).lineNumber;
        index.parseErrors.add((at: '$relative:$line', message: error.message));
      }
      parsed.add((relative, content, result.unit, result.lineInfo));
    }
    String? resolve(String from, String? uri) {
      if (uri == null) return null;
      if (package != null && uri.startsWith('package:$package/')) {
        return p.join('lib', uri.substring('package:$package/'.length));
      }
      return uri.contains(':')
          ? null
          : p.normalize(p.join(p.dirname(from), uri));
    }

    // `part 'x.dart'` names the library a part belongs to, whichever form its
    // `part of` directive takes.
    final owners = <String, String>{};
    for (final (relative, _, unit, _) in parsed) {
      for (final part in unit.directives.whereType<PartDirective>()) {
        if (resolve(relative, part.uri.stringValue) case final path?) {
          owners[path] = relative;
        }
      }
    }
    for (final (relative, content, unit, lineInfo) in parsed) {
      final library = owners[relative] ?? relative;
      final imports = index._imports[library] ??= {};
      for (final import in unit.directives.whereType<ImportDirective>()) {
        if (resolve(relative, import.uri.stringValue) case final path?) {
          imports.add(path);
        }
      }
      final file = SourceFile(relative, library, content, unit, lineInfo);
      index.files.add(file);
      unit.accept(_Collector(index, file));
    }
    for (final MapEntry(:key, :value) in index._superclasses.entries) {
      (index._subclasses[value] ??= []).add(key);
    }
    index._resolveNavigations();
    index._registerRoutes();
    return index;
  }

  static String? _packageName(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    return RegExp(r'^name:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec.readAsStringSync())
        ?.group(1);
  }

  /// Keeps the candidate calls whose receiver is a go_router object. Those
  /// calls are go_router's methods, so they never link to a project
  /// declaration that happens to share the name.
  void _resolveNavigations() {
    for (final (file, node, owner, className, kind, inExtension)
        in _candidates) {
      final receiver = node.realTarget;
      final navigates = kind == 'branch' ||
          (receiver == null ? inExtension : _isRouterReceiver(receiver));
      if (!navigates) continue;
      navigations.add(NavigationSite(file, node, owner, className, kind));
      _refs[node.methodName.name]?.removeWhere((r) => identical(r.node, node));
    }
  }

  bool _isRouterReceiver(Expression target) {
    final source =
        target.toSource().replaceAll(RegExp('[!?]'), '').toLowerCase();
    if (source.endsWith('context') || source.contains('router')) return true;
    if (target is SimpleIdentifier) {
      if (_declaredRouter(target) case final declared?) return declared;
    }
    final name = switch (target) {
      SimpleIdentifier t => t.name,
      PrefixedIdentifier t => t.identifier.name,
      PropertyAccess t => t.propertyName.name,
      _ => null,
    };
    return name != null && _routerFields.contains(name);
  }

  /// Whether the parameter or local [target] names is a BuildContext or a
  /// GoRouter; null when no such declaration is in scope.
  bool? _declaredRouter(SimpleIdentifier target) {
    for (AstNode? node = target.parent; node != null; node = node.parent) {
      final parameters = switch (node) {
        FunctionExpression n => n.parameters,
        MethodDeclaration n => n.parameters,
        ConstructorDeclaration n => n.parameters,
        _ => null,
      };
      for (final (i, parameter)
          in (parameters?.parameters ?? const <FormalParameter>[]).indexed) {
        final formal = parameter is DefaultFormalParameter
            ? parameter.parameter
            : parameter;
        if (formal.name?.lexeme != target.name) continue;
        final type = formal is SimpleFormalParameter ? formal.type : null;
        if (type != null) return _isRouterType(type.toSource());
        // Flutter builders pass the BuildContext first: `builder: (ctx) =>`.
        final up = node.parent;
        return i == 0 &&
            up is NamedExpression &&
            up.name.label.name.toLowerCase().endsWith('builder');
      }
      if (node is Block) {
        for (final statement
            in node.statements.whereType<VariableDeclarationStatement>()) {
          for (final variable in statement.variables.variables) {
            if (variable.name.lexeme != target.name) continue;
            final type = statement.variables.type;
            if (type != null) return _isRouterType(type.toSource());
            final value = variable.initializer
                    ?.toSource()
                    .replaceAll(RegExp('[!?]'), '')
                    .toLowerCase() ??
                '';
            return value.contains('router') || value.endsWith('context');
          }
        }
      }
    }
    return null;
  }

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

  /// Routes matching a concrete location: the static registrations of that
  /// path, or else the path patterns it fits.
  List<RouteDecl> routesFor(String location) {
    final exact = [
      for (final route in routes)
        if (route.path == location) route,
    ];
    return exact.isNotEmpty
        ? exact
        : [
            for (final route in routes)
              if (_matches(route.path, location)) route,
          ];
  }

  /// Routes a location with unknown parts can match, segment by segment. A
  /// segment that is entirely unknown matches only a `:param` segment.
  List<RouteDecl> routesForPattern(String pattern) {
    final wanted = pattern.split('/');
    return [
      for (final route in routes)
        if (route.path != null && _fits(wanted, route.path!.split('/'))) route,
    ];
  }

  /// One shortest incoming chain per distinct root, root first, plus one
  /// chain for every other call site in a declaration already walked. A
  /// declaration's callers are expanded once.
  (List<Chain>, bool truncated) chainsTo(NavigationSite site) => _walkUp(
      Hop(site.file, site.node, site.owner, className: site.className),
      const {},
      maxChainsPerSite);

  /// Where the widget binding a callback root is built: one shortest chain per
  /// call of the declaration holding the slot. In a widget's `build`, these
  /// are the constructor calls of the widget, followed only when [widgets].
  List<Chain> buildPaths(Chain chain, {bool widgets = true}) {
    if (chain.rootKind != 'callback' && chain.rootKind != 'callback_factory') {
      return const [];
    }
    final owner = chain.hops.first.owner;
    if (owner == null) return const [];
    final callers = !_frameworkMethods.contains(owner.name)
        ? callersOf(owner)
        : widgets
            ? _creationsOf(owner)
            : const <(Ref, int)>[];
    return [
      for (final (ref, matches) in callers.take(maxBuildPaths))
        ..._walkUp(_hop(ref, matches), {owner}, 1).$1,
    ];
  }

  /// Constructor calls of the widget whose `build` is [decl]; a State's build
  /// belongs to the widget named in `State<W>`.
  List<(Ref, int)> _creationsOf(Decl decl) {
    if (decl.name != 'build') return const [];
    final className = decl.root.className;
    final widget = _stateOf[className] ?? className;
    if (widget == null) return const [];
    return [
      for (final c in _creations[widget] ?? const <_Creation>[])
        (
          Ref(c.file, c.node, widget, c.owner, c.owner?.root.className, null,
              c.arguments,
              creation: true),
          1
        ),
    ];
  }

  Hop _hop(Ref ref, int matches) => Hop(ref.file, ref.node, ref.owner,
      className: ref.className,
      ref: ref,
      matches: matches,
      guessed: _guessed.contains(ref));

  (List<Chain>, bool truncated) _walkUp(Hop start, Set<Decl> skip, int limit) {
    final chains = <Chain>[];
    final skipped = <List<Hop>>[];
    final expanded = {...skip};
    var level = [
      [start],
    ];
    while (level.isNotEmpty) {
      final next = <List<Hop>>[];
      for (final chain in level) {
        final hop = chain.first;
        final slot = _slotOf(hop.node, hop.owner?.node);
        final owner = hop.owner;
        Chain? root;
        if (slot != null) {
          root = Chain(chain, slot.$3, slot.$2, slot.$1);
        } else if (owner == null) {
          root = Chain(
              chain, hop.className != null ? 'initializer' : 'no_owner', null);
        } else if (!expanded.add(owner)) {
          skipped.add(chain);
          continue;
        } else if (chain.length >= maxChainLength) {
          root = Chain(chain, 'depth_limit', null);
        } else {
          final callers = callersOf(owner);
          final onPath = {for (final h in chain) h.owner};
          final fresh = [
            for (final (ref, matches) in callers)
              if (!onPath.contains(ref.owner) || ref.owner == null)
                _hop(ref, matches),
          ];
          if (callers.isEmpty) {
            root = Chain(chain, _rootKind(owner), null);
          } else if (fresh.isEmpty) {
            // Only callers already on this chain: recursion with no way in.
            root = Chain(chain, 'cycle', null);
          } else {
            next.addAll([
              for (final caller in fresh) [caller, ...chain]
            ]);
          }
        }
        if (root == null) continue;
        if (chains.length >= limit) return (chains, true);
        chains.add(root);
      }
      level = next;
    }
    // Another call site in a declaration already walked gets the walk found
    // above that declaration, so each branch keeps its own conditions.
    final found = [...chains];
    for (final chain in skipped) {
      final first = chain.first;
      for (final c in found) {
        final i = c.hops.indexWhere((h) => h.owner == first.owner);
        if (i < 0 || identical(c.hops[i].node, first.node)) continue;
        if (chains.length >= limit) return (chains, true);
        chains.add(Chain([...c.hops.sublist(0, i), ...chain], c.rootKind,
            c.slot, c.slotNode));
        break;
      }
    }
    return (chains, false);
  }

  String _rootKind(Decl owner) {
    if (owner.name == 'main' &&
        owner.className == null &&
        owner.parent == null) {
      return 'entry_point';
    }
    if (_frameworkMethods.contains(owner.name)) return 'framework';
    return ambiguousCallersOf(owner) > 0 ? 'ambiguous_callers' : 'no_callers';
  }

  /// The environment at each hop of [chain], binding arguments as it goes.
  List<_Env> _envs(Chain chain) {
    var env = _Env(chain.hops.first.owner, chain.hops.first.file, const {});
    final envs = [env];
    for (var i = 0; i + 1 < chain.hops.length; i++) {
      final ref = chain.hops[i].ref;
      final callee = chain.hops[i + 1].owner;
      env = ref == null || callee == null
          ? _Env(callee, chain.hops[i + 1].file, const {})
          : ref.creation
              ? _widgetEnv(ref, callee, env)
              : _call(ref.arguments, callee, env);
      envs.add(env);
    }
    return envs;
  }

  /// The destination along one chain, substituting forwarded arguments.
  Evaluation destination(NavigationSite site, Chain chain) =>
      _evaluate(site.destination, _envs(chain).last);

  /// The branch index a `goBranch` call passes, when it is a literal.
  int? branchIndex(NavigationSite site, Chain chain) {
    final value = _evaluate(site.destination, _envs(chain).last);
    return value.complete ? int.tryParse(value.text) : null;
  }

  /// Whether no condition along [chain] contradicts a value its arguments fix,
  /// such as `if (replace)` below a call passing `false`.
  bool feasible(Chain chain) {
    final envs = _envs(chain);
    for (final (i, hop) in chain.hops.indexed) {
      for (final condition in _conditions(hop)) {
        final test = condition.test;
        if (test == null || condition.expected is! bool) continue;
        final value = _bool(test, envs[i]);
        if (value != null && value != condition.expected) return false;
      }
    }
    return true;
  }

  /// Source conditions that must hold at [hop], innermost first, as JSON.
  ///
  /// For a callback [root], `on_event` conditions sit inside the callback and
  /// `at_creation` ones decide whether it is bound. A fixed [phase] applies
  /// to every condition. In a callback [factory] body, conditions outside the
  /// returned closure are `at_creation` and those inside it `on_event`.
  List<Map<String, Object?>> conditionsAt(Hop hop,
          {bool root = false, String? phase, bool factory = false}) =>
      [
        for (final c
            in _conditions(hop, root: root, phase: phase, factory: factory))
          {
            'at': hop.file.at(c.at),
            'kind': c.kind,
            'expression': _short(c.label),
            'is': c.expected,
            if (c.phase != null) 'phase': c.phase,
          },
      ];

  List<_Condition> _conditions(Hop hop,
      {bool root = false, String? phase, bool factory = false}) {
    final out = <_Condition>[];
    AstNode? boundary = root ? _slotOf(hop.node, hop.owner?.node)?.$1 : null;
    String? current = phase;
    if (boundary != null) {
      current = identical(boundary, hop.node) ? 'at_creation' : 'on_event';
    } else if (factory) {
      for (var up = hop.node.parent;
          up != null && !identical(up, hop.owner?.node);
          up = up.parent) {
        if (up is FunctionExpression && up.parent is! FunctionDeclaration) {
          boundary = up;
          break;
        }
      }
      current = boundary == null ? 'at_creation' : 'on_event';
    }
    void add(AstNode at, String kind, String label, Object expected,
            [Expression? test]) =>
        out.add(_Condition(at, kind, label, expected, test, current));
    void guards(List<Statement> statements, AstNode child) {
      for (final statement in statements) {
        if (identical(statement, child)) break;
        if (statement is IfStatement) {
          _ifGuards(statement, (s, expected) {
            final label =
                [s.expression, s.caseClause].whereType<AstNode>().join(' ');
            add(s, 'guard', label, expected,
                s.caseClause == null ? s.expression : null);
          });
        }
      }
    }

    AstNode child = hop.node;
    for (var node = child.parent;
        node != null;
        child = node, node = node.parent) {
      if (identical(child, hop.owner?.node)) break;
      if (identical(child, boundary)) current = 'at_creation';
      switch (node) {
        case IfStatement n:
          final label =
              [n.expression, n.caseClause].whereType<AstNode>().join(' ');
          final test = n.caseClause == null ? n.expression : null;
          if (identical(child, n.thenStatement)) {
            add(n, 'if', label, true, test);
          }
          if (identical(child, n.elseStatement)) {
            add(n, 'if', label, false, test);
          }
        case IfElement n:
          final label =
              [n.expression, n.caseClause].whereType<AstNode>().join(' ');
          final test = n.caseClause == null ? n.expression : null;
          if (identical(child, n.thenElement)) add(n, 'if', label, true, test);
          if (identical(child, n.elseElement)) add(n, 'if', label, false, test);
        case ConditionalExpression n:
          if (identical(child, n.thenExpression)) {
            add(n, 'if', '${n.condition}', true, n.condition);
          }
          if (identical(child, n.elseExpression)) {
            add(n, 'if', '${n.condition}', false, n.condition);
          }
        case BinaryExpression n when identical(child, n.rightOperand):
          final op = n.operator.lexeme;
          if (op == '&&' || op == '||') {
            add(n, 'if', '${n.leftOperand}', op == '&&', n.leftOperand);
          }
          if (op == '??') add(n, 'if', '${n.leftOperand} == null', true);
        case SwitchStatement n when child is SwitchMember:
          // Empty members before this one fall through into its body; earlier
          // members with a body must not have matched.
          final members = n.members;
          final position = members.indexOf(child);
          var first = position;
          while (first > 0 && members[first - 1].statements.isEmpty) {
            first--;
          }
          add(
              child,
              'switch',
              '${n.expression}',
              members
                  .sublist(first, position + 1)
                  .map(_caseLabel)
                  .join(' or '));
          for (final earlier in members.sublist(0, first)) {
            add(earlier, 'switch', '${n.expression}',
                'not ${_caseLabel(earlier)}');
          }
        case SwitchExpression n when child is SwitchExpressionCase:
          add(child, 'switch', '${n.expression}',
              'case ${child.guardedPattern}');
          for (final earlier
              in n.cases.takeWhile((c) => !identical(c, child))) {
            add(earlier, 'switch', '${n.expression}',
                'not case ${earlier.guardedPattern}');
          }
        case WhileStatement n when identical(child, n.body):
          add(n, 'loop', '${n.condition}', true);
        case ForStatement n when identical(child, n.body):
          add(n, 'loop', '${n.forLoopParts}', true);
        case ForElement n when identical(child, n.body):
          add(n, 'loop', '${n.forLoopParts}', true);
        case Block(:final statements) || SwitchMember(:final statements):
          guards(statements, child);
      }
    }
    return out;
  }

  /// Branches of an if/else-if chain that exit leave the code after it only
  /// when their conditions do not hold.
  void _ifGuards(IfStatement s, void Function(IfStatement, bool) add) {
    final thenExits = _exits(s.thenStatement);
    final otherwise = s.elseStatement;
    final elseExits = otherwise != null && _exits(otherwise);
    if (thenExits && elseExits) return;
    if (thenExits) {
      add(s, false);
      if (otherwise is IfStatement) _ifGuards(otherwise, add);
    } else if (elseExits) {
      add(s, true);
    }
  }

  /// A condition's value when the arguments bound in [env] decide it.
  bool? _bool(Expression e, _Env env, [int depth = 0]) {
    if (depth > 8) return null;
    switch (e) {
      case BooleanLiteral():
        return e.value;
      case ParenthesizedExpression():
        return _bool(e.expression, env, depth + 1);
      case PrefixExpression() when e.operator.lexeme == '!':
        final value = _bool(e.operand, env, depth + 1);
        return value == null ? null : !value;
      case BinaryExpression() when e.operator.lexeme == '&&':
        final a = _bool(e.leftOperand, env, depth + 1);
        final b = _bool(e.rightOperand, env, depth + 1);
        if (a == false || b == false) return false;
        return a == true && b == true ? true : null;
      case BinaryExpression() when e.operator.lexeme == '||':
        final a = _bool(e.leftOperand, env, depth + 1);
        final b = _bool(e.rightOperand, env, depth + 1);
        if (a == true || b == true) return true;
        return a == false && b == false ? false : null;
      case BinaryExpression()
          when e.operator.lexeme == '==' || e.operator.lexeme == '!=':
        final equal = e.operator.lexeme == '==';
        if (_nullTest(e, env, depth) case final test?) return test;
        final a = _enumValue(e.leftOperand, env, depth);
        final b = _enumValue(e.rightOperand, env, depth);
        if (a != null && b != null) return (a == b) == equal;
        final left = _evaluate(e.leftOperand, env, depth + 1);
        final right = _evaluate(e.rightOperand, env, depth + 1);
        return left.complete && right.complete
            ? (left.text == right.text) == equal
            : null;
      case SimpleIdentifier():
        final bound = env.arguments[e.name] ?? env.fields[e.name];
        return bound == null ? null : _bool(bound.$1, bound.$2, depth + 1);
      case PrefixedIdentifier() when e.prefix.name == 'widget':
        final bound = env.fields[e.identifier.name];
        return bound == null ? null : _bool(bound.$1, bound.$2, depth + 1);
    }
    return null;
  }

  List<(Ref, int)> callersOf(Decl decl) => _callers[decl] ??= [
        for (final ref in _refs[decl.name] ?? const <Ref>[])
          if (_calleesOf(ref) case final callees when callees.contains(decl))
            (ref, callees.length),
      ];

  /// Untyped calls left unlinked because too many declarations share the
  /// name; any of them may call [decl].
  int ambiguousCallersOf(Decl decl) => [
        for (final ref in _refs[decl.name] ?? const <Ref>[])
          if (_calleesOf(ref).isEmpty && _ambiguous.contains(ref)) ref,
      ].length;

  /// Declarations a reference can invoke, from the most specific scope out.
  List<Decl> _calleesOf(Ref ref) => _callees[ref] ??= () {
        final all = _decls[ref.name] ?? const <Decl>[];
        if (all.isEmpty) return const <Decl>[];
        bool visible(Decl d) =>
            !ref.name.startsWith('_') || d.file.library == ref.file.library;
        final members = all.where(
            (d) => d.parent == null && d.className != null && visible(d));
        List<Decl> inClass(String type) =>
            _withOverrides(members.where((d) => d.className == type), members);
        final target = ref.target;
        final className = ref.owner?.root.className ?? ref.className;
        if (target is SuperExpression) {
          // Only a project superclass has members to link; a framework one has none.
          final superclass = _superclasses[className];
          return members.where((d) => d.className == superclass).toList();
        }
        if (target != null && target is! ThisExpression) {
          // `C.m()`, `C().m()` and `getIt<C>().m()` name the class; any other
          // receiver is untyped.
          final type = switch (target) {
            MethodInvocation(target: null, :final methodName)
                when _upper.hasMatch(methodName.name) =>
              methodName.name,
            MethodInvocation(:final typeArguments?)
                when typeArguments.arguments.length == 1 =>
              _typeName(typeArguments.arguments.single.toSource()),
            InstanceCreationExpression(:final constructorName) =>
              _typeName(constructorName.type.toSource()),
            _ => target.toSource(),
          };
          if (_classes.contains(type)) return inClass(type);
          if (_external(target)) return const <Decl>[];
          return _guess(ref, members);
        }
        for (var o = ref.owner; o != null; o = o.parent) {
          final local = all.where((d) => d.parent == o).toList();
          if (local.isNotEmpty) return local;
        }
        if (ref.owner?._scope.locals.contains(ref.name) ?? false) {
          return const <Decl>[];
        }
        final own = members
            .where((d) =>
                d.className == className && d.file.library == ref.file.library)
            .toList();
        if (own.isNotEmpty) return _withOverrides(own, members);
        // Members inherited from project superclasses and mixins.
        final inherited = <String>[
          for (var c = _superclasses[className], i = 0;
              c != null && i < 16;
              c = _superclasses[c], i++)
            c,
          ...?_mixins[className],
        ];
        for (final type in inherited) {
          final found = members.where((d) => d.className == type).toList();
          if (found.isNotEmpty) return _withOverrides(found, members);
        }
        final functions = all.where(
            (d) => d.parent == null && d.className == null && visible(d));
        final sameLibrary =
            functions.where((d) => d.file.library == ref.file.library).toList();
        if (sameLibrary.isNotEmpty) return sameLibrary;
        if (functions.isNotEmpty) return functions.toList();
        // An unqualified call can reach a member inherited from outside the
        // project; a bare name read is a field or local far more often.
        return ref.arguments == null ? const <Decl>[] : _guess(ref, members);
      }();

  /// [found] plus the overrides of its members in project subclasses, which a
  /// call can dispatch to.
  List<Decl> _withOverrides(Iterable<Decl> found, Iterable<Decl> members) {
    final result = [...found];
    final queue = [for (final d in found) d.className];
    final seen = <String?>{...queue};
    while (queue.isNotEmpty) {
      for (final sub in _subclasses[queue.removeLast()] ?? const <String>[]) {
        if (!seen.add(sub)) continue;
        queue.add(sub);
        result.addAll(members.where((d) => d.className == sub));
      }
    }
    return result;
  }

  /// A receiver that is a class outside the project, such as `Navigator`,
  /// `Navigator.of(context)` or `Theme.of(context)`.
  bool _external(Expression target) {
    final name = switch (target) {
      SimpleIdentifier t => t.name,
      PrefixedIdentifier t => t.prefix.name,
      MethodInvocation(target: SimpleIdentifier t) => t.name,
      MethodInvocation(target: null, :final methodName) => methodName.name,
      _ => null,
    };
    return name != null && _upper.hasMatch(name) && !_classes.contains(name);
  }

  /// Name-only links: lifecycle methods are the framework's to call, and a
  /// name shared by too many classes is no evidence of the target.
  List<Decl> _guess(Ref ref, Iterable<Decl> members) {
    if (_frameworkMethods.contains(ref.name)) return const [];
    final list = members.toList();
    if (list.length > maxNameMatches) {
      _ambiguous.add(ref);
      return const [];
    }
    if (list.isNotEmpty) _guessed.add(ref);
    return list;
  }

  /// The callee's environment for one call: arguments bound to parameters,
  /// defaults for omitted ones, and the remaining omitted ones known to be
  /// null. A tear-off ([argumentList] null) binds nothing.
  _Env _call(ArgumentList? argumentList, Decl callee, _Env env) {
    final arguments = argumentList?.arguments ?? const <Expression>[];
    final positional = arguments.where((a) => a is! NamedExpression).toList();
    final bound = <String, (Expression, _Env)>{};
    final absent = <String>{};
    var i = 0;
    for (final parameter
        in callee.parameters?.parameters ?? const <FormalParameter>[]) {
      final name = parameter.name?.lexeme;
      if (name == null) continue;
      final value = parameter.isNamed
          ? _named(argumentList, name)
          : i < positional.length
              ? positional[i++]
              : null;
      if (callee._scope.reassigned.contains(name) || argumentList == null) {
        continue;
      }
      final fallback =
          parameter is DefaultFormalParameter ? parameter.defaultValue : null;
      if (value != null) {
        bound[name] = (value, env);
      } else if (fallback != null) {
        bound[name] = (fallback, _Env(callee, callee.file, const {}));
      } else {
        absent.add(name);
      }
    }
    return _Env(callee, callee.file, bound, absent: absent);
  }

  /// The environment of a widget's `build` reached from a constructor call:
  /// fields set through `this.x` parameters or initializers.
  _Env _widgetEnv(Ref creation, Decl build, _Env env) {
    final constructor = _constructor(creation.name);
    if (constructor == null) return _Env(build, build.file, const {});
    final inner = _call(creation.arguments, constructor, env);
    final node = constructor.node as ConstructorDeclaration;
    final fields = <String, (Expression, _Env)>{};
    for (final parameter in node.parameters.parameters) {
      final formal =
          parameter is DefaultFormalParameter ? parameter.parameter : parameter;
      if (formal is FieldFormalParameter) {
        if (inner.arguments[formal.name.lexeme] case final bound?) {
          fields[formal.name.lexeme] = bound;
        }
      }
    }
    for (final initializer
        in node.initializers.whereType<ConstructorFieldInitializer>()) {
      fields[initializer.fieldName.name] = (initializer.expression, inner);
    }
    return _Env(build, build.file, const {}, fields: fields);
  }

  /// A unique static, top-level or same-class function a call can name.
  Decl? _function(MethodInvocation e, _Env env) {
    final target = e.target;
    final all = _decls[e.methodName.name] ?? const <Decl>[];
    final List<Decl> matches;
    if (target == null) {
      final own = all
          .where((d) => d.parent == null && d.className == env.className)
          .toList();
      matches = own.isNotEmpty
          ? own
          : all.where((d) => d.parent == null && d.className == null).toList();
    } else if (target is SimpleIdentifier && _classes.contains(target.name)) {
      matches = all.where((d) => d.className == target.name).toList();
    } else {
      return null;
    }
    return matches.length == 1 ? matches.single : null;
  }

  /// A getter named [name] in [className], when it is unique.
  Decl? _getter(String? className, String name) {
    final matches = [
      for (final d in _decls[name] ?? const <Decl>[])
        if (d.className == className &&
            d.node is MethodDeclaration &&
            (d.node as MethodDeclaration).isGetter)
          d,
    ];
    return matches.length == 1 ? matches.single : null;
  }

  /// The expressions a function can return, outside nested closures.
  List<Expression> _returns(Decl decl) {
    final body = switch (decl.node) {
      MethodDeclaration n => n.body,
      FunctionDeclaration n => n.functionExpression.body,
      _ => null,
    };
    if (body is ExpressionFunctionBody) return [body.expression];
    if (body is! BlockFunctionBody) return const [];
    final returns = _Returns();
    body.block.accept(returns);
    return returns.values;
  }

  /// What a call of a function with known returns evaluates to.
  Evaluation? _callValue(Decl callee, ArgumentList? arguments, _Env env,
      String source, int depth) {
    final returns = _returns(callee);
    if (returns.isEmpty) return null;
    final inner = arguments == null
        ? _Env(callee, callee.file, const {})
        : _call(arguments, callee, env);
    if (returns.length > maxAlternatives) {
      return Evaluation.unknown(source, 'alternatives');
    }
    return Evaluation.of(
        [for (final value in returns) _evaluate(value, inner, depth + 1)]);
  }

  /// `Enum.value.name`, or a field the enum constructor sets from `this.x`.
  Evaluation? _enumField(
      String enumName, String value, String field, int depth) {
    final entry = _enumConstants['$enumName.$value'];
    if (entry == null) return null;
    if (field == 'name') return Evaluation(value, true);
    final (file, constant) = entry;
    final constructor = (_decls[enumName] ?? const <Decl>[])
        .where((d) =>
            d.className == enumName &&
            d.node is ConstructorDeclaration &&
            (d.node as ConstructorDeclaration).name?.lexeme ==
                constant.arguments?.constructorSelector?.name.name)
        .firstOrNull;
    final arguments = constant.arguments?.argumentList;
    if (constructor == null || arguments == null) return null;
    final env = _call(arguments, constructor, _Env.constant(file, enumName));
    final bound = env.arguments[field];
    return bound == null ? null : _evaluate(bound.$1, bound.$2, depth + 1);
  }

  /// The enum constant an expression holds, following bound parameters,
  /// widget fields and final locals: `('Kind', 'a')` for `Kind.a`.
  (String, String)? _enumValue(Expression e, _Env env, int depth) {
    if (depth > 8) return null;
    switch (e) {
      case PrefixedIdentifier()
          when _enumConstants
              .containsKey('${e.prefix.name}.${e.identifier.name}'):
        return (e.prefix.name, e.identifier.name);
      case PrefixedIdentifier() when e.prefix.name == 'widget':
        final bound = env.fields[e.identifier.name];
        return bound == null ? null : _enumValue(bound.$1, bound.$2, depth + 1);
      case SimpleIdentifier():
        final bound = env.arguments[e.name] ?? env.fields[e.name];
        if (bound != null) return _enumValue(bound.$1, bound.$2, depth + 1);
        final local = env.owner?._scope.finals[e.name];
        if (local != null && local.length == 1 && local.single != null) {
          return _enumValue(local.single!, env, depth + 1);
        }
      case ParenthesizedExpression():
        return _enumValue(e.expression, env, depth + 1);
    }
    return null;
  }

  /// Decides `x == null` and `x != null` when `x` evaluates.
  bool? _nullTest(Expression condition, _Env env, int depth) {
    if (condition is! BinaryExpression) return null;
    final op = condition.operator.lexeme;
    if (op != '==' && op != '!=') return null;
    final Expression subject;
    if (condition.rightOperand is NullLiteral) {
      subject = condition.leftOperand;
    } else if (condition.leftOperand is NullLiteral) {
      subject = condition.rightOperand;
    } else {
      return null;
    }
    final value = _evaluate(subject, env, depth + 1);
    if (!value.isNull && !value.complete) return null;
    return value.isNull == (op == '==');
  }

  Evaluation _join(Iterable<Object> parts, _Env env, int depth) {
    final options = [
      for (final part in parts)
        part is String
            ? [Evaluation(part, true)]
            : [
                for (final v
                    in _evaluate(part as Expression, env, depth + 1).expand())
                  v.isNull ? Evaluation('null', true) : v,
              ],
    ];
    var combinations = 1;
    for (final option in options) {
      combinations *= option.length;
    }
    if (combinations > maxAlternatives) {
      return _concat([
        for (final option in options)
          option.length == 1
              ? option.single
              : Evaluation.unknown('…', 'alternatives'),
      ]);
    }
    var results = [<Evaluation>[]];
    for (final option in options) {
      results = [
        for (final prefix in results)
          for (final value in option) [...prefix, value],
      ];
    }
    return Evaluation.of([for (final parts in results) _concat(parts)]);
  }

  static Evaluation _concat(List<Evaluation> parts) {
    final text = StringBuffer();
    final pattern = StringBuffer();
    final holes = <String>[];
    var complete = true;
    var forwarded = false;
    var unbound = false;
    String? reason;
    for (final part in parts) {
      if (complete) text.write(part.text);
      pattern.write(part.pattern);
      holes.addAll(part.holes);
      forwarded |= part.forwarded;
      unbound |= part.unbound;
      if (!part.complete && complete) {
        complete = false;
        reason = part.reason;
      }
    }
    return Evaluation('$text', complete,
        forwarded: forwarded,
        reason: reason,
        unbound: unbound,
        pattern: '$pattern',
        holes: holes);
  }

  Evaluation _evaluate(Expression e, _Env env, [int depth = 0]) {
    Evaluation unknown([String reason = 'dynamic_expression']) =>
        Evaluation.unknown(e.toSource(), reason);
    if (depth > 12) return unknown();
    switch (e) {
      case SimpleStringLiteral():
        return Evaluation(e.value, true);
      case BooleanLiteral():
        return Evaluation('${e.value}', true);
      case IntegerLiteral():
        return Evaluation(e.literal.lexeme, true);
      case AdjacentStrings():
        return _join(e.strings, env, depth);
      case StringInterpolation():
        return _join([
          for (final element in e.elements)
            element is InterpolationString
                ? element.value
                : (element as InterpolationExpression).expression,
        ], env, depth);
      case ParenthesizedExpression():
        return _evaluate(e.expression, env, depth + 1);
      case NullLiteral():
        return Evaluation.nullValue;
      case SimpleIdentifier():
        return _identifier(e, env, depth);
      case PrefixedIdentifier():
        final field = _providerRecordField(e, env);
        if (field != null) return _evaluate(field.$1, field.$2, depth + 1);
        if (e.prefix.name == 'widget') {
          if (env.fields[e.identifier.name] case (final value, final caller)) {
            return _evaluate(value, caller, depth + 1).asForwarded;
          }
        }
        if (_enumValue(e.prefix, env, depth) case (final type, final value)) {
          return _enumField(type, value, e.identifier.name, depth) ?? unknown();
        }
        final key = '${e.prefix.name}.${e.identifier.name}';
        if (!_consts.containsKey(key)) {
          final getter = _getter(e.prefix.name, e.identifier.name);
          if (getter != null) {
            final value = _callValue(getter, null, env, key, depth);
            if (value != null) return value;
          }
        }
        return _constant(key, env.file, depth);
      case PropertyAccess():
        final target = e.realTarget;
        if (_enumValue(target, env, depth) case (final type, final value)) {
          return _enumField(type, value, e.propertyName.name, depth) ??
              unknown();
        }
        return unknown();
      case BinaryExpression() when e.operator.lexeme == '??':
        final left = _evaluate(e.leftOperand, env, depth + 1);
        if (left.isNull) return _evaluate(e.rightOperand, env, depth + 1);
        if (left.complete) return left;
        // Unknown at runtime: either side can be the value.
        return Evaluation.of([left, _evaluate(e.rightOperand, env, depth + 1)]);
      case ConditionalExpression():
        final test = _nullTest(e.condition, env, depth) ??
            _bool(e.condition, env, depth);
        if (test != null) {
          return _evaluate(
              test ? e.thenExpression : e.elseExpression, env, depth + 1);
        }
        return Evaluation.of([
          _evaluate(e.thenExpression, env, depth + 1),
          _evaluate(e.elseExpression, env, depth + 1),
        ]);
      case SwitchExpression():
        return Evaluation.of([
          for (final c in e.cases) _evaluate(c.expression, env, depth + 1),
        ]);
      case MethodInvocation(target: null)
          when _upper.hasMatch(e.methodName.name) &&
              e.methodName.name != 'Uri' &&
              e.argumentList.arguments.length == 1 &&
              e.argumentList.arguments.single is! NamedExpression:
        // A wrapper such as `RouteInfo('/home')`.
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
      case InstanceCreationExpression()
          when e.argumentList.arguments.length == 1 &&
              e.argumentList.arguments.single is! NamedExpression:
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
      case MethodInvocation(:final target?)
          when e.methodName.name == 'toString':
        // `Uri(path: '/search', queryParameters: {...}).toString()`.
        final uri = _uri(target);
        if (uri == null) return unknown();
        final (path, query) = uri;
        final value = _evaluate(path, env, depth + 1);
        return query
            ? _concat([
                value,
                Evaluation('?', true),
                Evaluation.unknown('query', 'dynamic_expression'),
              ])
            : value;
      case MethodInvocation() when e.methodName.name == 'namedLocation':
        return _namedLocation(e, env, depth) ?? unknown();
      case MethodInvocation():
        // A static or top-level function with known returns, such as
        // `Paths.detail(id)`.
        final callee = _function(e, env);
        if (callee != null) {
          final value =
              _callValue(callee, e.argumentList, env, e.toSource(), depth);
          if (value != null) return value;
        }
    }
    return unknown();
  }

  Evaluation _identifier(SimpleIdentifier e, _Env env, int depth) {
    final name = e.name;
    if (env.arguments[name] case (final value, final caller)) {
      return _evaluate(value, caller, depth + 1).asForwarded;
    }
    if (env.absent.contains(name)) return Evaluation.nullValue;
    final scope = env.owner?._scope;
    if (scope != null && scope.parameters.contains(name)) {
      return Evaluation.unknown(
          name,
          scope.reassigned.contains(name)
              ? 'reassigned_parameter'
              : 'unbound_parameter');
    }
    final local = scope?.finals[name];
    if (local != null && local.length == 1 && local.single != null) {
      return _evaluate(local.single!, env, depth + 1);
    }
    if (scope != null && scope.locals.contains(name)) {
      return Evaluation.unknown(name, 'dynamic_expression');
    }
    if (env.fields[name] case (final value, final caller)) {
      return _evaluate(value, caller, depth + 1).asForwarded;
    }
    final className = env.className;
    if (_getter(className, name) case final getter?
        when !_consts.containsKey('$className.$name')) {
      final value = _callValue(getter, null, env, name, depth);
      if (value != null) return value;
    }
    return _constant(
        className != null && _consts.containsKey('$className.$name')
            ? '$className.$name'
            : name,
        env.file,
        depth);
  }

  /// The `path:` of a `Uri(...)` call, and whether it also sets a query.
  (Expression, bool)? _uri(Expression target) {
    final (name, arguments) = switch (target) {
      MethodInvocation(target: null, :final methodName, :final argumentList) =>
        (methodName.name, argumentList),
      InstanceCreationExpression(:final constructorName, :final argumentList)
          when constructorName.name == null =>
        (_typeName(constructorName.type.toSource()), argumentList),
      _ => (null, null),
    };
    if (name != 'Uri' || arguments == null) return null;
    final path = _named(arguments, 'path');
    if (path == null) return null;
    final query = _named(arguments, 'queryParameters') != null ||
        _named(arguments, 'query') != null;
    return (path, query);
  }

  /// `namedLocation('name', pathParameters: ...)`: the path registered for
  /// that name, with its parameters unknown.
  Evaluation? _namedLocation(MethodInvocation e, _Env env, int depth) {
    final first = e.argumentList.arguments
        .where((a) => a is! NamedExpression)
        .firstOrNull;
    if (first == null) return null;
    final name = _evaluate(first, env, depth + 1);
    if (!name.complete) return null;
    final paths = {
      for (final route in routes)
        if (route.name == name.text && route.path != null) route.path!,
    };
    if (paths.length != 1) return null;
    final segments = paths.single.split('/');
    return _concat([
      for (final (i, segment) in segments.indexed) ...[
        if (i > 0) Evaluation('/', true),
        segment.startsWith(':')
            ? Evaluation.unknown(segment, 'dynamic_expression')
            : Evaluation(segment, true),
      ],
    ]);
  }

  /// `routes.notice` after `final routes = ref.watch(p)`, where `p` is
  /// `Provider((ref) => (notice: ...))`: the field of the provider's default
  /// value. An override can replace it.
  (Expression, _Env)? _providerRecordField(PrefixedIdentifier e, _Env env) {
    final local = env.owner?._scope.finals[e.prefix.name];
    final read = local?.length == 1 ? local!.single : null;
    if (read is! MethodInvocation ||
        !const {'watch', 'read'}.contains(read.methodName.name) ||
        read.argumentList.arguments.length != 1) {
      return null;
    }
    final provider = _consts[read.argumentList.arguments.single.toSource()];
    final creation = provider?.length == 1 ? provider!.single : null;
    final arguments = switch (creation?.$2) {
      MethodInvocation m
          when m.methodName.name == 'Provider' || '${m.target}' == 'Provider' =>
        m.argumentList.arguments,
      _ => null,
    };
    final body = switch (arguments?.firstOrNull) {
      FunctionExpression(body: ExpressionFunctionBody(:final expression)) =>
        expression,
      _ => null,
    };
    if (body is! RecordLiteral) return null;
    for (final field in body.fields.whereType<NamedExpression>()) {
      if (field.name.label.name == e.identifier.name) {
        return (field.expression, _Env.constant(creation!.$1, null));
      }
    }
    return null;
  }

  /// Whether [hop] only creates a closure or passes a tear-off (a builder, a
  /// listener, a returned callback) other than its callback slot, so running
  /// it is not established. Closures around the slot itself only build it.
  bool deferred(Hop hop) {
    final slot = _slotOf(hop.node, hop.owner?.node)?.$1;
    if (slot != null && identical(slot, hop.node)) return false;
    if (hop.ref != null && hop.ref!.arguments == null && slot == null) {
      return true;
    }
    for (var node = hop.node.parent;
        node != null && !identical(node, hop.owner?.node);
        node = node.parent) {
      if (identical(node, slot)) return false;
      if (node is FunctionExpression && node.parent is! FunctionDeclaration) {
        return true;
      }
    }
    return false;
  }

  /// The slot binding a callback root's chain, and an enclosing `on*` slot of
  /// the same declaration, as in a button inside a dialog another button opens.
  (AstNode, String)? within(Chain chain) {
    final node = chain.slotNode;
    final owner = chain.hops.first.owner?.node;
    if (node == null || node.parent == null) return null;
    final outer = _slotOf(node.parent!, owner);
    return outer == null ? null : (outer.$1, outer.$2);
  }

  /// The `on*` slot that binds [site] or its enclosing closure as a callback:
  /// (bound node, slot name, root kind). A closure passed positionally binds
  /// through the name of the callee's parameter, as in `_body(onTap)`.
  (AstNode, String, String)? _slotOf(AstNode site, AstNode? stop) {
    for (AstNode? node = site;
        node != null && !identical(node, stop);
        node = node.parent) {
      if (node is FunctionExpression && node.parent is FunctionDeclaration) {
        return null;
      }
      final bindable = node is FunctionExpression ||
          (identical(node, site) &&
              (site is SimpleIdentifier || site is MethodInvocation));
      if (!bindable) continue;
      final parent = node.parent;
      // `controller.open` binds as a whole.
      final bound = (parent is PrefixedIdentifier &&
                  identical(parent.identifier, node)) ||
              (parent is PropertyAccess && identical(parent.propertyName, node))
          ? parent!
          : node;
      final (value, up) = _receiver(bound);
      final slot = switch (up) {
        NamedExpression n => n.name.label.name,
        ArgumentList list => _parameterName(list, value),
        _ => null,
      };
      if (slot != null && _slotName.hasMatch(slot)) {
        final kind = node is MethodInvocation ? 'callback_factory' : 'callback';
        return (node, slot, kind);
      }
    }
    return null;
  }

  /// The callee parameter a positional argument binds to.
  String? _parameterName(ArgumentList list, AstNode value) {
    final positional =
        list.arguments.where((a) => a is! NamedExpression).toList();
    final position = positional.indexWhere((a) => identical(a, value));
    if (position < 0) return null;
    final invocation = list.parent;
    final Decl? callee = switch (invocation) {
      InstanceCreationExpression c =>
        _constructor(_typeName(c.constructorName.type.toSource())),
      MethodInvocation m when _refByNode[m] != null =>
        _calleesOf(_refByNode[m]!).singleOrNull,
      _ => null,
    };
    final parameters = [
      for (final parameter
          in callee?.parameters?.parameters ?? const <FormalParameter>[])
        if (!parameter.isNamed) parameter,
    ];
    return position < parameters.length
        ? parameters[position].name?.lexeme
        : null;
  }

  Evaluation _constant(String key, SourceFile from, int depth) {
    final matches = _consts[key] ?? const [];
    final sameLibrary =
        matches.where((m) => m.$1.library == from.library).toList();
    final imports = _imports[from.library] ?? const <String>{};
    final imported =
        matches.where((m) => imports.contains(m.$1.library)).toList();
    final candidates = sameLibrary.isNotEmpty
        ? sameLibrary
        : imported.isNotEmpty
            ? imported
            : matches;
    if (candidates.length != 1) {
      return Evaluation.unknown(key,
          candidates.isEmpty ? 'dynamic_expression' : 'ambiguous_constant');
    }
    final (file, initializer, className) = candidates.single;
    return _evaluate(initializer, _Env.constant(file, className), depth + 1);
  }
}

class _Condition {
  _Condition(
      this.at, this.kind, this.label, this.expected, this.test, this.phase);

  final AstNode at;
  final String kind;
  final String label;
  final Object expected;

  /// The boolean expression to test, when the condition is one.
  final Expression? test;
  final String? phase;
}

class _Env {
  const _Env(this.owner, this.file, this.arguments,
      {this.absent = const {}, this.fields = const {}})
      : _className = null;

  _Env.constant(this.file, this._className)
      : owner = null,
        arguments = const {},
        absent = const {},
        fields = const {};

  final Decl? owner;
  final SourceFile file;
  final Map<String, (Expression, _Env)> arguments;

  /// Parameters the call omitted and that have no default.
  final Set<String> absent;

  /// Widget fields a constructor call set, read in that widget's `build`.
  final Map<String, (Expression, _Env)> fields;
  final String? _className;

  String? get className => _className ?? owner?.root.className;
}

/// Return values of a function body, outside nested functions.
class _Returns extends RecursiveAstVisitor<void> {
  final values = <Expression>[];

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression case final value?) values.add(value);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {}
}

/// Names declared inside a declaration, including nested closures.
class _Scope extends RecursiveAstVisitor<void> {
  final parameters = <String>{};
  final locals = <String>{};
  final reassigned = <String>{};
  final finals = <String, List<Expression?>>{};

  void collect(AstNode node) {
    switch (node) {
      case MethodDeclaration n:
        n.parameters?.accept(this);
      case FunctionDeclaration n:
        n.functionExpression.parameters?.accept(this);
      case ConstructorDeclaration n:
        n.parameters.accept(this);
    }
    parameters.addAll(locals);
    switch (node) {
      case MethodDeclaration n:
        n.body.accept(this);
      case FunctionDeclaration n:
        n.functionExpression.body.accept(this);
      case ConstructorDeclaration n:
        n.body.accept(this);
    }
  }

  void _parameter(Token? name) {
    if (name != null) locals.add(name.lexeme);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) =>
      _parameter(node.name);

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) =>
      _parameter(node.name);

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) =>
      _parameter(node.name);

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) =>
      _parameter(node.name);

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final name = node.name.lexeme;
    locals.add(name);
    final list = node.parent;
    if (list is VariableDeclarationList && (list.isFinal || list.isConst)) {
      (finals[name] ??= []).add(node.initializer);
    } else {
      (finals[name] ??= []).add(null);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitDeclaredIdentifier(DeclaredIdentifier node) {
    locals.add(node.name.lexeme);
    super.visitDeclaredIdentifier(node);
  }

  @override
  void visitDeclaredVariablePattern(DeclaredVariablePattern node) {
    locals.add(node.name.lexeme);
    super.visitDeclaredVariablePattern(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final left = node.leftHandSide;
    if (left is SimpleIdentifier) reassigned.add(left.name);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitAssignedVariablePattern(AssignedVariablePattern node) {
    reassigned.add(node.name.lexeme);
    super.visitAssignedVariablePattern(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    reassigned.add(node.identifier.name);
    super.visitForEachPartsWithIdentifier(node);
  }
}

class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.index, this.file);

  final CodeIndex index;
  final SourceFile file;
  String? _class;
  Decl? _decl;
  bool _extendsRouter = false;

  void _inClass(String name, void Function() visit) {
    index._classes.add(name);
    final saved = _class;
    _class = name;
    visit();
    _class = saved;
  }

  void _inDecl(AstNode node, String name, void Function() visit) {
    final decl = Decl(file, node, name, _decl == null ? _class : null, _decl);
    (index._decls[name] ??= []).add(decl);
    final saved = _decl;
    _decl = decl;
    visit();
    _decl = saved;
  }

  void _ref(
      AstNode node, String name, Expression? target, ArgumentList? arguments) {
    final ref = Ref(file, node, name, _decl, _class, target, arguments);
    (index._refs[name] ??= []).add(ref);
    index._refByNode[node] = ref;
  }

  // Names come from the token after the keyword: the name getters differ
  // between analyzer majors, the token stream does not.
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.classKeyword.next!.lexeme;
    final superclass = node.extendsClause?.superclass.toSource();
    if (superclass != null) {
      index._superclasses[name] = _typeName(superclass);
      // `State<HomePage>`: this State's build belongs to HomePage.
      final generic = RegExp(r'^[\w.]*State<\s*(\w+)').firstMatch(superclass);
      if (generic != null) index._stateOf[name] = generic.group(1)!;
    }
    final mixins = node.withClause?.mixinTypes;
    if (mixins != null) {
      index._mixins[name] = [for (final m in mixins) _typeName(m.toSource())];
    }
    _inClass(name, () => super.visitClassDeclaration(node));
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) => _inClass(
      node.mixinKeyword.next!.lexeme, () => super.visitMixinDeclaration(node));

  @override
  void visitEnumDeclaration(EnumDeclaration node) => _inClass(
      node.enumKeyword.next!.lexeme, () => super.visitEnumDeclaration(node));

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final saved = _extendsRouter;
    // In `extension on BuildContext`, a bare `go(...)` navigates `this`.
    _extendsRouter = _isRouterType(node.onClause?.extendedType.toSource());
    _inClass(node.name?.lexeme ?? '<extension>',
        () => super.visitExtensionDeclaration(node));
    _extendsRouter = saved;
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) => _inClass(
      _afterConst(node.typeKeyword.next!).lexeme,
      () => super.visitExtensionTypeDeclaration(node));

  @override
  void visitMethodDeclaration(MethodDeclaration node) =>
      _inDecl(node, node.name.lexeme, () => super.visitMethodDeclaration(node));

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) => _inDecl(
      node, node.name.lexeme, () => super.visitFunctionDeclaration(node));

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) => _inDecl(
      node,
      node.name?.lexeme ?? _class ?? 'new',
      () => super.visitConstructorDeclaration(node));

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (node.isStatic) {
      // Mutable statics count too: route paths are often declared as plain
      // `static String home = '/home';`. The initializer is what is read.
      for (final variable in node.fields.variables) {
        if (variable.initializer case final initializer?) {
          (index._consts['$_class.${variable.name.lexeme}'] ??= [])
              .add((file, initializer, _class));
        }
      }
    } else if (_isRouterType(node.fields.type?.toSource())) {
      for (final variable in node.fields.variables) {
        index._routerFields.add(variable.name.lexeme);
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      if (variable.initializer case final initializer?) {
        (index._consts[variable.name.lexeme] ??= [])
            .add((file, initializer, null));
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target;
    // `GoRoute(...)` or `go.GoRoute(...)` without `new`/`const` parses as a call.
    if (_upper.hasMatch(name) &&
        (target == null ||
            (target is SimpleIdentifier && !_upper.hasMatch(target.name)))) {
      _creation(node, name, node.argumentList);
    }
    if ((name == 'StatefulShellRoute' && target == null) ||
        (target is SimpleIdentifier && target.name == 'StatefulShellRoute')) {
      _shell(node, node.argumentList);
    }
    final positional =
        node.argumentList.arguments.any((a) => a is! NamedExpression);
    final kind = _locationMethods.contains(name)
        ? 'location'
        : _nameMethods.contains(name)
            ? 'name'
            : name == 'goBranch'
                ? 'branch'
                : null;
    if (kind != null && positional) {
      index._candidates.add((file, node, _decl, _class, kind, _extendsRouter));
    }
    _ref(node, name, node.realTarget, node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final type = _typeName(node.constructorName.type.toSource());
    if (node.constructorName.name == null) {
      _creation(node, type, node.argumentList);
    }
    if (type == 'StatefulShellRoute') _shell(node, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    index._enumConstants['$_class.${node.name.lexeme}'] = (file, node);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // Every other mention of a name is a reference: a tear-off such as
    // `onTap: _open` or `onTap: controller.open`, a getter read, a function
    // stored in a map. Calls are recorded as invocations instead.
    final parent = node.parent;
    final skip = switch (parent) {
      MethodInvocation p =>
        identical(p.methodName, node) || identical(p.target, node),
      PropertyAccess p => identical(p.target, node),
      PrefixedIdentifier p => identical(p.prefix, node),
      AssignmentExpression p => identical(p.leftHandSide, node),
      // `removeListener(_cb)` unregisters the callback; it never runs it.
      ArgumentList(parent: MethodInvocation(:final methodName))
          when methodName.name.startsWith('remove') =>
        true,
      Label() ||
      Combinator() ||
      ConstructorName() ||
      Annotation() ||
      CommentReference() ||
      SuperConstructorInvocation() ||
      RedirectingConstructorInvocation() ||
      ConstructorFieldInitializer() =>
        true,
      _ => false,
    };
    if (!skip) {
      final target = switch (parent) {
        PrefixedIdentifier p => p.prefix,
        PropertyAccess p => p.realTarget,
        _ => null,
      };
      _ref(node, node.name, target, null);
    }
    super.visitSimpleIdentifier(node);
  }

  void _creation(AstNode node, String className, ArgumentList arguments) =>
      (index._creations[className] ??= [])
          .add(_Creation(file, node, className, arguments, _decl));

  void _shell(AstNode node, ArgumentList arguments) {
    if (_named(arguments, 'branches') case final ListLiteral branches) {
      index._shellArguments.add((file, node, branches));
    }
  }
}

/// A constructor call; the ones of route classes become registrations.
class _Creation {
  _Creation(this.file, this.node, this.className, this.arguments, this.owner);

  final SourceFile file;
  final AstNode node;
  final String className;
  final ArgumentList arguments;
  final Decl? owner;
}

Expression? _named(ArgumentList? arguments, String name) => arguments?.arguments
    .whereType<NamedExpression>()
    .where((a) => a.name.label.name == name)
    .firstOrNull
    ?.expression;

Token _afterConst(Token token) => token.lexeme == 'const' ? token.next! : token;

String _typeName(String source) =>
    source.split('<').first.split('.').last.replaceAll('?', '');

bool _isRouterType(String? type) =>
    type != null &&
    (type.contains('BuildContext') || type.contains('GoRouter'));

/// The node receiving [expression] as a value, looking through conditional,
/// parenthesized and switch-expression branches and `??` fallbacks, with the
/// branch it holds.
(AstNode, AstNode?) _receiver(AstNode expression) {
  var child = expression;
  var up = expression.parent;
  while ((up is ConditionalExpression && !identical(up.condition, child)) ||
      up is ParenthesizedExpression ||
      (up is SwitchExpressionCase && identical(up.expression, child)) ||
      (up is SwitchExpression && !identical(up.expression, child)) ||
      (up is BinaryExpression &&
          up.operator.lexeme == '??' &&
          identical(up.rightOperand, child))) {
    child = up!;
    up = up.parent;
  }
  return (child, up);
}

/// Whether control never continues after [statement].
bool _exits(Statement statement) => switch (statement) {
      ReturnStatement() || ContinueStatement() || BreakStatement() => true,
      ExpressionStatement(
        expression: ThrowExpression() || RethrowExpression()
      ) =>
        true,
      Block(:final statements) =>
        statements.isNotEmpty && _exits(statements.last),
      IfStatement(:final thenStatement, :final elseStatement?) =>
        _exits(thenStatement) && _exits(elseStatement),
      _ => false,
    };

String _caseLabel(SwitchMember member) => switch (member) {
      SwitchPatternCase m => 'case ${m.guardedPattern}',
      SwitchCase m => 'case ${m.expression}',
      _ => 'default',
    };

String _short(String source, [int limit = 120]) {
  final flat = source.replaceAll(RegExp(r'\s+'), ' ');
  return flat.length <= limit ? flat : '${flat.substring(0, limit - 3)}...';
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
