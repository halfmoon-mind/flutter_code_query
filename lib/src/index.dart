import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
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
  'dispose',
  'createState',
};

const maxChainsPerSite = 200;

/// Calls of a widget-building declaration followed to find where a callback
/// root is bound.
const maxBuildPaths = 20;

/// An untyped call `x.m()` links to the declarations named `m` only up to this
/// many; past it the name says nothing about the target.
const maxNameMatches = 3;
const maxChainLength = 12;

final _generated =
    RegExp(r'GENERATED.{0,20}DO NOT MODIFY', caseSensitive: false);
final _slotName = RegExp(r'^on[A-Z]');

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
  Ref(this.file, this.node, this.name, this.owner, this.target, this.arguments);

  final SourceFile file;

  /// A [MethodInvocation], or a [SimpleIdentifier] for a tear-off.
  final AstNode node;
  final String name;
  final Decl? owner;
  final Expression? target;

  /// Null for a tear-off.
  final ArgumentList? arguments;
}

class NavigationSite {
  NavigationSite(this.file, this.node, this.owner, this.named);

  final SourceFile file;
  final MethodInvocation node;
  final Decl? owner;

  /// `goNamed` and friends: the destination is a route name.
  final bool named;

  Expression get destination =>
      node.argumentList.arguments.firstWhere((a) => a is! NamedExpression);
}

class RouteDecl {
  RouteDecl(this.file, this.node, this.pathExpression, this.nameExpression,
      this._pathValue, this._nameValue);

  final SourceFile file;

  /// The registration: a route constructor call, or the call of a function or
  /// getter that builds the route from its arguments.
  final AstNode node;
  final Expression? pathExpression;
  final Expression? nameExpression;
  final Evaluation? _pathValue;
  final Evaluation? _nameValue;
  RouteDecl? parent;

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
      {this.ref, this.matches = 1, this.guessed = false});

  final SourceFile file;
  final AstNode node;
  final Decl? owner;
  final Ref? ref;

  /// Whether the link was matched by name alone (an untyped receiver or an
  /// inherited member), and how many declarations share that name.
  final bool guessed;
  final int matches;
}

class Chain {
  Chain(this.hops, this.rootKind, this.slot);

  final List<Hop> hops;

  /// callback, callback_factory, framework, ambiguous_callers, no_callers,
  /// no_owner, cycle or depth_limit.
  final String rootKind;
  final String? slot;
}

class Evaluation {
  const Evaluation(this.text, this.complete,
      {this.forwarded = false, this.reason, this.isNull = false});

  /// An omitted argument without a default, or a `null` literal.
  static const nullValue =
      Evaluation('', false, reason: 'null_value', isNull: true);

  final String text;
  final bool complete;
  final bool forwarded;
  final String? reason;
  final bool isNull;

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
}

class CodeIndex {
  CodeIndex(this.root);

  final String root;
  final files = <SourceFile>[];
  final routes = <RouteDecl>[];
  final navigations = <NavigationSite>[];

  /// The first syntax error per file. Such a file is only partly indexed, for
  /// example when the app uses newer Dart syntax than this package's analyzer
  /// parses.
  final parseErrors = <({String at, String message})>[];
  final _decls = <String, List<Decl>>{};
  final _refs = <String, List<Ref>>{};
  final _consts = <String, List<(SourceFile, Expression, String?)>>{};
  final _classes = <String>{};
  final _superclasses = <String, String>{};
  final _mixins = <String, List<String>>{};
  final _creations = <String, List<_Creation>>{};
  final _enumConstants = <String, (SourceFile, EnumConstantDeclaration)>{};
  final _callees = <Ref, List<Decl>>{};
  final _callers = <Decl, List<(Ref, int)>>{};
  final _ambiguous = <Ref>{};
  final _guessed = <Ref>{};

  /// Parses every non-generated Dart file under `lib`; nothing is resolved.
  static CodeIndex build(String root) {
    final index = CodeIndex(root);
    final lib = Directory(p.join(root, 'lib'));
    final paths = lib
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((f) => f.path)
        .where((f) =>
            f.endsWith('.dart') &&
            !f.endsWith('.g.dart') &&
            !f.endsWith('.freezed.dart'))
        .toList()
      ..sort();
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
      final result = parseString(
        content: content,
        path: path,
        featureSet: featureSet,
        throwIfDiagnostics: false,
      );
      if (result.errors.firstOrNull case final error?) {
        final line = result.lineInfo.getLocation(error.offset).lineNumber;
        index.parseErrors.add((at: '$relative:$line', message: error.message));
      }
      parsed.add((relative, content, result.unit, result.lineInfo));
    }
    // `part 'x.dart'` names the library a part belongs to, whichever form its
    // `part of` directive takes.
    final owners = <String, String>{};
    for (final (relative, _, unit, _) in parsed) {
      for (final part in unit.directives.whereType<PartDirective>()) {
        final uri = part.uri.stringValue;
        if (uri != null && !uri.contains(':')) {
          owners[p.normalize(p.join(p.dirname(relative), uri))] = relative;
        }
      }
    }
    for (final (relative, content, unit, lineInfo) in parsed) {
      final file = SourceFile(
          relative, owners[relative] ?? relative, content, unit, lineInfo);
      index.files.add(file);
      unit.accept(_Collector(index, file));
    }
    index._registerRoutes();
    return index;
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
          (pathValue.reason == 'unbound_parameter' ||
              (pathValue.complete &&
                  !pathValue.text.startsWith('/') &&
                  !insideRoute(at, atOwner)));
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
          path?.$1,
          named ? name?.$1 : null,
          pathValue,
          named ? nameValue : null));
    }

    for (final creation in creations) {
      register(creation, const []);
    }
    final byNode = {for (final route in routes) route.node: route};
    for (final route in routes) {
      for (var up = route.node.parent; up != null; up = up.parent) {
        if (byNode[up] case final parent?) {
          route.parent = parent;
          break;
        }
      }
    }
    // The full path when complete, otherwise its known start.
    (String?, bool) fullPath(RouteDecl route, int depth) {
      final value = route._pathValue;
      if (value == null || depth > 32) return (null, false);
      if (value.text.startsWith('/')) return (value.text, value.complete);
      final (parent, complete) = route.parent == null
          ? (null, false)
          : fullPath(route.parent!, depth + 1);
      if (parent == null || !complete) return (null, false);
      final joined = parent == '/' ? '/${value.text}' : '$parent/${value.text}';
      return (joined, value.complete);
    }

    for (final route in routes) {
      final (path, complete) = fullPath(route, 0);
      route.path = complete ? path : null;
      route.pathPrefix = complete ? null : path;
      if (route._nameValue case final name? when name.complete) {
        route.name = name.text;
      }
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
    final constructor = (_decls[className] ?? const <Decl>[])
        .where((d) =>
            d.className == className &&
            d.node is ConstructorDeclaration &&
            (d.node as ConstructorDeclaration).name == null)
        .firstOrNull;
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

  /// One shortest incoming chain per distinct root, root first. A
  /// declaration is expanded once, so paths that rejoin an already expanded
  /// declaration are not enumerated again.
  (List<Chain>, bool truncated) chainsTo(NavigationSite site) => _walkUp(
      Hop(site.file, site.node, site.owner), const {}, maxChainsPerSite);

  /// Where the widget binding a callback root is built: one shortest chain per
  /// call of the declaration holding the slot. Empty for other roots, and for
  /// a slot bound in a framework method or an uncalled declaration.
  List<Chain> buildPaths(Chain chain) {
    if (chain.rootKind != 'callback' && chain.rootKind != 'callback_factory') {
      return const [];
    }
    final owner = chain.hops.first.owner;
    if (owner == null || _frameworkMethods.contains(owner.name)) {
      return const [];
    }
    return [
      for (final (ref, matches) in callersOf(owner).take(maxBuildPaths))
        ..._walkUp(_hop(ref, matches), {owner}, 1).$1,
    ];
  }

  Hop _hop(Ref ref, int matches) => Hop(ref.file, ref.node, ref.owner,
      ref: ref, matches: matches, guessed: _guessed.contains(ref));

  (List<Chain>, bool truncated) _walkUp(Hop start, Set<Decl> skip, int limit) {
    final chains = <Chain>[];
    final expanded = {...skip};
    var level = [
      [start],
    ];
    while (level.isNotEmpty) {
      final next = <List<Hop>>[];
      for (final chain in level) {
        final hop = chain.first;
        final slot = _slot(hop.node, hop.owner?.node);
        final owner = hop.owner;
        Chain? root;
        if (slot != null) {
          root = Chain(chain, slot.$3, slot.$2);
        } else if (owner == null) {
          root = Chain(chain, 'no_owner', null);
        } else if (!expanded.add(owner)) {
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
            root = Chain(
                chain,
                _frameworkMethods.contains(owner.name)
                    ? 'framework'
                    : ambiguousCallersOf(owner) > 0
                        ? 'ambiguous_callers'
                        : 'no_callers',
                null);
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
    return (chains, false);
  }

  /// The destination along one chain, substituting forwarded arguments.
  Evaluation destination(NavigationSite site, Chain chain) {
    var env = _Env(chain.hops.first.owner, chain.hops.first.file, const {});
    for (var i = 0; i + 1 < chain.hops.length; i++) {
      final ref = chain.hops[i].ref;
      final callee = chain.hops[i + 1].owner;
      env = ref == null || callee == null
          ? _Env(callee, chain.hops[i + 1].file, const {})
          : _call(ref.arguments, callee, env);
    }
    return _evaluate(site.destination, env);
  }

  /// Source conditions that must hold at [hop], innermost first.
  ///
  /// For a callback root, `on_event` conditions sit inside the callback and
  /// `at_creation` conditions decide whether the callback is bound at all.
  /// A [build] hop sits on the path that builds the widget, so all of its
  /// conditions are `at_creation`.
  List<Map<String, Object?>> conditionsAt(Hop hop,
      {bool root = false, bool build = false}) {
    final out = <Map<String, Object?>>[];
    final slot = root ? _slot(hop.node, hop.owner?.node)?.$1 : null;
    var phase = build
        ? 'at_creation'
        : slot == null
            ? null
            : identical(slot, hop.node)
                ? 'at_creation'
                : 'on_event';
    void add(AstNode at, String kind, String expression, Object value) =>
        out.add({
          'at': hop.file.at(at),
          'kind': kind,
          'expression': _short(expression),
          'is': value,
          if (phase != null) 'phase': phase,
        });
    AstNode child = hop.node;
    for (var node = child.parent;
        node != null;
        child = node, node = node.parent) {
      if (identical(child, hop.owner?.node)) break;
      if (identical(child, slot)) phase = 'at_creation';
      switch (node) {
        case IfStatement n:
          final condition =
              [n.expression, n.caseClause].whereType<AstNode>().join(' ');
          if (identical(child, n.thenStatement)) add(n, 'if', condition, true);
          if (identical(child, n.elseStatement)) add(n, 'if', condition, false);
        case IfElement n:
          final condition =
              [n.expression, n.caseClause].whereType<AstNode>().join(' ');
          if (identical(child, n.thenElement)) add(n, 'if', condition, true);
          if (identical(child, n.elseElement)) add(n, 'if', condition, false);
        case ConditionalExpression n:
          if (identical(child, n.thenExpression)) {
            add(n, 'if', '${n.condition}', true);
          }
          if (identical(child, n.elseExpression)) {
            add(n, 'if', '${n.condition}', false);
          }
        case BinaryExpression n when identical(child, n.rightOperand):
          final op = n.operator.lexeme;
          if (op == '&&' || op == '||') {
            add(n, 'if', '${n.leftOperand}', op == '&&');
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
          // An earlier `if` with exactly one exiting branch requires the other.
          for (final statement in statements) {
            if (identical(statement, child)) break;
            if (statement is! IfStatement) continue;
            final thenExits = _exits(statement.thenStatement);
            final otherwise = statement.elseStatement;
            final elseExits = otherwise != null && _exits(otherwise);
            if (thenExits == elseExits) continue;
            add(
                statement,
                'guard',
                [statement.expression, statement.caseClause]
                    .whereType<AstNode>()
                    .join(' '),
                elseExits);
          }
      }
    }
    return out;
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
        final target = ref.target;
        if (target is SuperExpression) {
          // Only a project superclass has members to link; a framework one has none.
          final superclass = _superclasses[ref.owner?.root.className];
          return members.where((d) => d.className == superclass).toList();
        }
        if (target != null && target is! ThisExpression) {
          // `ClassName.member(...)` and `ClassName(...).member(...)` name the
          // class; any other receiver is untyped.
          final type = switch (target) {
            MethodInvocation(target: null, :final methodName) =>
              methodName.name,
            InstanceCreationExpression(:final constructorName) =>
              _typeName(constructorName.type.toSource()),
            _ => target.toSource(),
          };
          return _classes.contains(type)
              ? members.where((d) => d.className == type).toList()
              : _guess(ref, members);
        }
        for (var o = ref.owner; o != null; o = o.parent) {
          final local = all.where((d) => d.parent == o).toList();
          if (local.isNotEmpty) return local;
        }
        if (ref.owner?._scope.locals.contains(ref.name) ?? false) {
          return const <Decl>[];
        }
        final className = ref.owner?.root.className;
        final own = members
            .where((d) =>
                d.className == className && d.file.library == ref.file.library)
            .toList();
        if (own.isNotEmpty) return own;
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
          if (found.isNotEmpty) return found;
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

  /// The expression a function returns, when its body is that one expression.
  Expression? _returned(Decl decl) {
    final body = switch (decl.node) {
      MethodDeclaration n => n.body,
      FunctionDeclaration n => n.functionExpression.body,
      _ => null,
    };
    return switch (body) {
      ExpressionFunctionBody(:final expression) => expression,
      BlockFunctionBody(:final block)
          when block.statements.length == 1 &&
              block.statements.single is ReturnStatement =>
        (block.statements.single as ReturnStatement).expression,
      _ => null,
    };
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

  Evaluation _evaluate(Expression e, _Env env, [int depth = 0]) {
    const unknown = Evaluation('', false, reason: 'dynamic_expression');
    if (depth > 8) return unknown;
    Evaluation join(Iterable<Object> parts) {
      final text = StringBuffer();
      var forwarded = false;
      for (final part in parts) {
        if (part is String) {
          text.write(part);
          continue;
        }
        final value = _evaluate(part as Expression, env, depth + 1);
        text.write(value.text);
        forwarded |= value.forwarded;
        if (!value.complete) {
          return Evaluation('$text', false,
              forwarded: forwarded, reason: value.reason);
        }
      }
      return Evaluation('$text', true, forwarded: forwarded);
    }

    switch (e) {
      case SimpleStringLiteral():
        return Evaluation(e.value, true);
      case AdjacentStrings():
        return join(e.strings);
      case StringInterpolation():
        return join([
          for (final element in e.elements)
            element is InterpolationString
                ? element.value
                : (element as InterpolationExpression).expression,
        ]);
      case ParenthesizedExpression():
        return _evaluate(e.expression, env, depth + 1);
      case SimpleIdentifier():
        final name = e.name;
        if (env.arguments[name] case (final value, final caller)) {
          final result = _evaluate(value, caller, depth + 1);
          return Evaluation(result.text, result.complete,
              forwarded: true, reason: result.reason, isNull: result.isNull);
        }
        if (env.absent.contains(name)) return Evaluation.nullValue;
        final scope = env.owner?._scope;
        if (scope != null && scope.parameters.contains(name)) {
          return Evaluation('', false,
              reason: scope.reassigned.contains(name)
                  ? 'reassigned_parameter'
                  : 'unbound_parameter');
        }
        final local = scope?.finals[name];
        if (local != null && local.length == 1 && local.single != null) {
          return _evaluate(local.single!, env, depth + 1);
        }
        if (scope != null && scope.locals.contains(name)) return unknown;
        final className = env.className;
        if (_getter(className, name) case final getter?
            when !_consts.containsKey('$className.$name')) {
          if (_returned(getter) case final body?) {
            return _evaluate(
                body, _Env(getter, getter.file, const {}), depth + 1);
          }
        }
        return _constant(
            className != null && _consts.containsKey('$className.$name')
                ? '$className.$name'
                : name,
            env.file,
            depth);
      case PrefixedIdentifier():
        final field = _providerRecordField(e, env);
        if (field != null) return _evaluate(field.$1, field.$2, depth + 1);
        final key = '${e.prefix.name}.${e.identifier.name}';
        if (!_consts.containsKey(key)) {
          final getter = _getter(e.prefix.name, e.identifier.name);
          if (getter != null && _returned(getter) != null) {
            return _evaluate(_returned(getter)!,
                _Env(getter, getter.file, const {}), depth + 1);
          }
        }
        return _constant(key, env.file, depth);
      case PropertyAccess(target: PrefixedIdentifier target):
        return _enumField(target.prefix.name, target.identifier.name,
                e.propertyName.name, depth) ??
            unknown;
      case NullLiteral():
        return Evaluation.nullValue;
      case BinaryExpression() when e.operator.lexeme == '??':
        final left = _evaluate(e.leftOperand, env, depth + 1);
        return left.isNull ? _evaluate(e.rightOperand, env, depth + 1) : left;
      case ConditionalExpression():
        final test = _nullTest(e.condition, env, depth);
        if (test != null) {
          return _evaluate(
              test ? e.thenExpression : e.elseExpression, env, depth + 1);
        }
        final a = _evaluate(e.thenExpression, env, depth + 1);
        final b = _evaluate(e.elseExpression, env, depth + 1);
        return a.complete && b.complete && a.text == b.text ? a : unknown;
      case MethodInvocation(target: null)
          when e.methodName.name.startsWith(RegExp('[A-Z]')) &&
              e.argumentList.arguments.length == 1:
        // A wrapper such as `RouteInfo('/home')`.
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
      case InstanceCreationExpression()
          when e.argumentList.arguments.length == 1:
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
      case MethodInvocation():
        // A static or top-level function returning one expression, such as
        // `Paths.detail(id)`.
        final callee = _function(e, env);
        final body = callee == null ? null : _returned(callee);
        if (body != null) {
          return _evaluate(
              body, _call(e.argumentList, callee!, env), depth + 1);
        }
    }
    return unknown;
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
  /// it is not established.
  bool deferred(Hop hop) {
    final slot = _slot(hop.node, hop.owner?.node)?.$1;
    if (hop.ref != null && hop.ref!.arguments == null && slot == null) {
      return true;
    }
    for (var node = hop.node.parent;
        node != null && !identical(node, hop.owner?.node);
        node = node.parent) {
      if (node is FunctionExpression &&
          node.parent is! FunctionDeclaration &&
          !identical(node, slot)) {
        return true;
      }
    }
    return false;
  }

  Evaluation _constant(String key, SourceFile from, int depth) {
    final matches = _consts[key] ?? const [];
    final sameLibrary =
        matches.where((m) => m.$1.library == from.library).toList();
    final candidates = sameLibrary.isNotEmpty ? sameLibrary : matches;
    if (candidates.length != 1) {
      return Evaluation('', false,
          reason:
              candidates.isEmpty ? 'dynamic_expression' : 'ambiguous_constant');
    }
    final (file, initializer, className) = candidates.single;
    return _evaluate(initializer, _Env.constant(file, className), depth + 1);
  }
}

class _Env {
  const _Env(this.owner, this.file, this.arguments, {this.absent = const {}})
      : _className = null;

  _Env.constant(this.file, this._className)
      : owner = null,
        arguments = const {},
        absent = const {};

  final Decl? owner;
  final SourceFile file;
  final Map<String, (Expression, _Env)> arguments;

  /// Parameters the call omitted and that have no default.
  final Set<String> absent;
  final String? _className;

  String? get className => _className ?? owner?.root.className;
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

  // Names come from the token after the keyword: the name getters differ
  // between analyzer majors, the token stream does not.
  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.classKeyword.next!.lexeme;
    final superclass = node.extendsClause?.superclass.toSource();
    if (superclass != null) index._superclasses[name] = _typeName(superclass);
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
    // Mutable statics count too: route paths are often declared as plain
    // `static String home = '/home';`. The initializer is what is read.
    if (node.isStatic) {
      for (final variable in node.fields.variables) {
        if (variable.initializer case final initializer?) {
          (index._consts['$_class.${variable.name.lexeme}'] ??= [])
              .add((file, initializer, _class));
        }
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    {
      for (final variable in node.variables.variables) {
        if (variable.initializer case final initializer?) {
          (index._consts[variable.name.lexeme] ??= [])
              .add((file, initializer, null));
        }
      }
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final target = node.target;
    // `GoRoute(...)` or `go.GoRoute(...)` without `new`/`const` parses as a call.
    if (name.startsWith(RegExp('[A-Z]')) &&
        (target == null ||
            (target is SimpleIdentifier &&
                !target.name.startsWith(RegExp('[A-Z]'))))) {
      _creation(node, name, node.argumentList);
    }
    final positional =
        node.argumentList.arguments.any((a) => a is! NamedExpression);
    final receiver = node.realTarget;
    if (positional &&
        (_locationMethods.contains(name) || _nameMethods.contains(name)) &&
        (receiver == null ? _extendsRouter : _isRouter(receiver))) {
      index.navigations
          .add(NavigationSite(file, node, _decl, _nameMethods.contains(name)));
    }
    (index._refs[name] ??= [])
        .add(Ref(file, node, name, _decl, node.realTarget, node.argumentList));
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.name == null) {
      final type = node.constructorName.type.toSource();
      _creation(node, type.split('<').first.split('.').last, node.argumentList);
    }
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
      (index._refs[node.name] ??= [])
          .add(Ref(file, node, node.name, _decl, target, null));
    }
    super.visitSimpleIdentifier(node);
  }

  void _creation(AstNode node, String className, ArgumentList arguments) =>
      (index._creations[className] ??= [])
          .add(_Creation(file, node, className, arguments, _decl));
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

String _typeName(String source) => source.split('<').first.split('.').last;

bool _isRouterType(String? type) =>
    type != null &&
    (type.contains('BuildContext') || type.contains('GoRouter'));

bool _isRouter(Expression target) {
  final source = target.toSource().replaceAll('!', '').toLowerCase();
  if (source.endsWith('context') || source.contains('router')) return true;
  // `c.go(...)` where `c` is declared as a BuildContext or GoRouter.
  if (target is! SimpleIdentifier) return false;
  for (AstNode? node = target.parent; node != null; node = node.parent) {
    final parameters = switch (node) {
      FunctionExpression n => n.parameters,
      MethodDeclaration n => n.parameters,
      ConstructorDeclaration n => n.parameters,
      _ => null,
    };
    for (final parameter
        in parameters?.parameters ?? const <FormalParameter>[]) {
      final formal =
          parameter is DefaultFormalParameter ? parameter.parameter : parameter;
      if (formal.name?.lexeme == target.name) {
        return formal is SimpleFormalParameter &&
            _isRouterType(formal.type?.toSource());
      }
    }
    if (node is Block) {
      for (final statement
          in node.statements.whereType<VariableDeclarationStatement>()) {
        if (statement.variables.variables
            .any((v) => v.name.lexeme == target.name)) {
          return _isRouterType(statement.variables.type?.toSource());
        }
      }
    }
  }
  return false;
}

/// The `on*` slot that binds [site] or its enclosing closure as a callback,
/// with the root kind: `callback`, or `callback_factory` when [site] is a call
/// whose result is bound (the call runs at creation, its result on the event).
(AstNode, String, String)? _slot(AstNode site, AstNode? stop) {
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
    final up = _receiver(bound).$2;
    if (up is NamedExpression && _slotName.hasMatch(up.name.label.name)) {
      final kind = node is MethodInvocation ? 'callback_factory' : 'callback';
      return (node, up.name.label.name, kind);
    }
  }
  return null;
}

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

bool _exits(Statement statement) => switch (statement) {
      ReturnStatement() => true,
      ExpressionStatement(
        expression: ThrowExpression() || RethrowExpression()
      ) =>
        true,
      Block(:final statements) =>
        statements.isNotEmpty && _exits(statements.last),
      _ => false,
    };

String _caseLabel(SwitchMember member) => switch (member) {
      SwitchPatternCase m => 'case ${m.guardedPattern}',
      SwitchCase m => 'case ${m.expression}',
      _ => 'default',
    };

String _short(String source) {
  final flat = source.replaceAll(RegExp(r'\s+'), ' ');
  return flat.length <= 120 ? flat : '${flat.substring(0, 117)}...';
}

bool _matches(String? pattern, String location) {
  if (pattern == null || !pattern.contains(':')) return false;
  final regex = pattern
      .split('/')
      .map((s) => s.startsWith(':') ? '[^/]+' : RegExp.escape(s))
      .join('/');
  return RegExp('^$regex\$').hasMatch(location);
}
