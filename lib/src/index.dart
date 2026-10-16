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

part 'chains.dart';
part 'collector.dart';
part 'conditions.dart';
part 'linking.dart';
part 'model.dart';
part 'routes.dart';
part 'values.dart';

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
    RegExp(r'GENERATED[\s\S]{0,80}DO NOT MODIFY', caseSensitive: false);

final _slotName = RegExp(r'^on[A-Z]');

/// A class name, private ones included.
final _upper = RegExp('^_?[A-Z]');

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

  /// Declared or constructed types of fields (`Class.field`) and top-level
  /// variables, for receivers such as `final CartFlow flow;`.
  final _variableTypes = <String, String>{};

  /// Interfaces each class implements, which calls can dispatch through.
  final _interfaces = <String, List<String>>{};

  /// The type each extension applies to, by extension name.
  final _extensionOn = <String, String>{};

  /// Import prefixes (`import 'x.dart' as x;`) by library, each with the
  /// project libraries it imports.
  final _prefixes = <String, Map<String, Set<String>>>{};
  final _typedClasses = <String>{};

  final _imports = <String, Set<String>>{};

  final _creations = <String, List<_Creation>>{};

  final _shellArguments = <(SourceFile, AstNode, ListLiteral)>[];

  final _candidates =
      <(SourceFile, MethodInvocation, Decl?, String?, String, bool)>[];

  final _enumConstants =
      <String, (SourceFile, EnumConstantDeclaration, int index)>{};

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
    final exports = <String, Set<String>>{};
    for (final (relative, content, unit, lineInfo) in parsed) {
      final library = owners[relative] ?? relative;
      final imports = index._imports[library] ??= {};
      for (final import in unit.directives.whereType<ImportDirective>()) {
        final path = resolve(relative, import.uri.stringValue);
        if (path != null) imports.add(path);
        if (import.prefix case final prefix?) {
          final libraries =
              (index._prefixes[library] ??= {})[prefix.name] ??= {};
          if (path != null) libraries.add(path);
        }
      }
      for (final export in unit.directives.whereType<ExportDirective>()) {
        if (resolve(relative, export.uri.stringValue) case final path?) {
          (exports[library] ??= {}).add(path);
        }
      }
      final file = SourceFile(relative, library, content, unit, lineInfo);
      index.files.add(file);
      unit.accept(_Collector(index, file));
    }
    // An import also reaches what the imported library exports, transitively.
    void addExports(Set<String> libraries) {
      final queue = [...libraries];
      while (queue.isNotEmpty) {
        for (final path in exports[queue.removeLast()] ?? const <String>{}) {
          if (libraries.add(path)) queue.add(path);
        }
      }
    }

    index._imports.values.forEach(addExports);
    for (final prefixes in index._prefixes.values) {
      prefixes.values.forEach(addExports);
    }
    for (final MapEntry(:key, :value) in index._superclasses.entries) {
      (index._subclasses[value] ??= []).add(key);
    }
    for (final MapEntry(:key, :value) in index._interfaces.entries) {
      for (final interface in value) {
        (index._subclasses[interface] ??= []).add(key);
      }
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

  /// Where the widget binding a callback root is built: the chains up from
  /// each call of the declaration holding the slot, and whether the limit cut
  /// them short. In a widget's `build`, these are the constructor calls of the
  /// widget, followed only when [widgets].
  (List<Chain>, bool truncated) buildPaths(Chain chain, {bool widgets = true}) {
    if (chain.rootKind != 'callback' && chain.rootKind != 'callback_factory') {
      return (const [], false);
    }
    final owner = chain.hops.first.owner;
    if (owner == null) return (const [], false);
    final callers = !_frameworkMethods.contains(owner.name)
        ? callersOf(owner)
        : widgets
            ? _creationsOf(owner)
            : const <(Ref, int)>[];
    // Every caller's first chain comes before any caller's second, so the
    // limit keeps as many distinct callers as it can.
    final perCaller = <List<Chain>>[];
    var truncated = false;
    for (final (ref, matches) in callers) {
      if (perCaller.length >= maxBuildPaths) {
        truncated = true;
        break;
      }
      final (found, cut) = _walkUp(_hop(ref, matches), {owner}, maxBuildPaths);
      truncated |= cut;
      perCaller.add(found);
    }
    final builds = <Chain>[];
    for (var round = 0; builds.length < maxBuildPaths; round++) {
      final layer = [
        for (final found in perCaller)
          if (round < found.length) found[round],
      ];
      if (layer.isEmpty) break;
      builds.addAll(layer.take(maxBuildPaths - builds.length));
    }
    final total = perCaller.fold<int>(0, (n, found) => n + found.length);
    return (builds, truncated || total > builds.length);
  }

  /// The destination along one chain, substituting forwarded arguments.
  Evaluation destination(NavigationSite site, Chain chain) =>
      _evaluate(site.destination, _envs(chain).last);

  /// The conditional or switch expression a destination picks its value
  /// from: written in the call, or held by a final local the call names.
  Expression? choiceExpression(NavigationSite site, Chain chain) {
    var expression = site.destination;
    final scope = chain.hops.last.owner?._scope;
    for (var i = 0; i < 8; i++) {
      while (expression is ParenthesizedExpression) {
        expression = expression.expression;
      }
      if (expression is ConditionalExpression ||
          expression is SwitchExpression) {
        return expression;
      }
      final local = expression is SimpleIdentifier
          ? scope?.finals[expression.name]
          : null;
      if (local == null || local.length != 1 || local.single == null) {
        return null;
      }
      expression = local.single!;
    }
    return null;
  }

  /// What [expression] evaluates to at the end of [chain].
  Evaluation evaluateAt(Expression expression, Chain chain) =>
      _evaluate(expression, _envs(chain).last);

  /// Where a go_router_builder route's class is constructed, as in
  /// `const HomeRoute().location`.
  List<String> typedUses(RouteDecl route) => [
        for (final c in _creations[route.typedClass] ?? const <_Creation>[])
          c.file.at(c.node),
      ];

  /// The source of the constant a route's path is written with, and where
  /// that constant is declared when it is known.
  (String, String?)? pathConstant(RouteDecl route) {
    final source = switch (route.pathExpression) {
      final PrefixedIdentifier e => e.toSource(),
      final PropertyAccess e => e.toSource(),
      SimpleIdentifier e when _consts.containsKey(e.name) => e.name,
      _ => null,
    };
    if (source == null) return null;
    final declared = _consts[source]?.singleOrNull;
    return (source, declared?.$1.at(declared.$2));
  }

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

String _short(String source, [int limit = 120]) {
  final flat = source.replaceAll(RegExp(r'\s+'), ' ');
  return flat.length <= limit ? flat : '${flat.substring(0, limit - 3)}...';
}
