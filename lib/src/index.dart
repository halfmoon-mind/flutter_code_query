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
      this.parent);

  final SourceFile file;
  final AstNode node;
  final Expression? pathExpression;
  final Expression? nameExpression;
  final RouteDecl? parent;

  /// Full path with parent paths joined; null when it cannot be evaluated.
  String? path;
  String? name;
}

/// One hop of an incoming chain. Every hop except the last is a [ref] that
/// invokes the next hop's [owner].
class Hop {
  Hop(this.file, this.node, this.owner, {this.ref, this.matches = 1});

  final SourceFile file;
  final AstNode node;
  final Decl? owner;
  final Ref? ref;

  /// Declarations sharing the callee's name; above 1 the link is a guess.
  final int matches;
}

class Chain {
  Chain(this.hops, this.rootKind, this.slot);

  final List<Hop> hops;

  /// callback, framework, no_callers, no_owner, cycle or depth_limit.
  final String rootKind;
  final String? slot;
}

class Evaluation {
  const Evaluation(this.text, this.complete,
      {this.forwarded = false, this.reason});

  final String text;
  final bool complete;
  final bool forwarded;
  final String? reason;

  /// The location path, once a query or fragment makes later content irrelevant.
  String? get path {
    final cut = text.indexOf(RegExp('[?#]'));
    if (cut >= 0) return text.substring(0, cut);
    return complete ? text : null;
  }
}

class CodeIndex {
  CodeIndex(this.root);

  final String root;
  final files = <SourceFile>[];
  final routes = <RouteDecl>[];
  final navigations = <NavigationSite>[];

  /// The first syntax error per file, as `path:line: message`. Such a file is
  /// only partly indexed, for example when the app uses newer Dart syntax than
  /// this package's analyzer parses.
  final parseErrors = <String>[];
  final _decls = <String, List<Decl>>{};
  final _refs = <String, List<Ref>>{};
  final _consts = <String, List<(SourceFile, Expression, String?)>>{};
  final _classes = <String>{};
  final _superclasses = <String, String>{};
  final _callees = <Ref, List<Decl>>{};
  final _callers = <Decl, List<(Ref, int)>>{};

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
    for (final path in paths) {
      final content = File(path).readAsStringSync();
      final head = content.length < 400 ? content : content.substring(0, 400);
      if (_generated.hasMatch(head)) continue;
      final result = parseString(
        content: content,
        path: path,
        featureSet: FeatureSet.latestLanguageVersion(),
        throwIfDiagnostics: false,
      );
      final relative = p.relative(path, from: root);
      if (result.errors.firstOrNull case final error?) {
        final line = result.lineInfo.getLocation(error.offset).lineNumber;
        index.parseErrors.add('$relative:$line: ${error.message}');
      }
      final partOf =
          result.unit.directives.whereType<PartOfDirective>().firstOrNull;
      final library = partOf?.uri == null
          ? relative
          : p.normalize(p.join(p.dirname(relative), partOf!.uri!.stringValue));
      final file =
          SourceFile(relative, library, content, result.unit, result.lineInfo);
      index.files.add(file);
      result.unit.accept(_Collector(index, file));
    }
    for (final route in index.routes) {
      final path = route.pathExpression == null
          ? null
          : index
              ._evaluate(route.pathExpression!, _Env.constant(route.file, null))
              .path;
      final parent = route.parent?.path;
      route.path = path == null || path.startsWith('/')
          ? path
          : parent == null
              ? null
              : parent == '/'
                  ? '/$path'
                  : '$parent/$path';
      final name = route.nameExpression;
      if (name != null) {
        final value = index._evaluate(name, _Env.constant(route.file, null));
        if (value.complete) route.name = value.text;
      }
    }
    return index;
  }

  /// Routes matching a concrete location or a registered path pattern.
  List<RouteDecl> routesFor(String location) => [
        for (final route in routes)
          if (route.path == location || _matches(route.path, location)) route,
      ];

  /// Incoming chains for a navigation site, root first.
  (List<Chain>, bool truncated) chainsTo(NavigationSite site) {
    final chains = <Chain>[];
    var truncated = false;
    void walk(Hop hop, List<Hop> below, Set<Decl> visited) {
      if (chains.length >= maxChainsPerSite) {
        truncated = true;
        return;
      }
      final chain = [hop, ...below];
      final slot = _slot(hop.node, hop.owner?.node);
      final owner = hop.owner;
      if (slot != null) return chains.add(Chain(chain, slot.$3, slot.$2));
      if (owner == null) return chains.add(Chain(chain, 'no_owner', null));
      if (chain.length >= maxChainLength) {
        return chains.add(Chain(chain, 'depth_limit', null));
      }
      final callers = callersOf(owner);
      if (callers.isEmpty) {
        return chains.add(Chain(
            chain,
            _frameworkMethods.contains(owner.name) ? 'framework' : 'no_callers',
            null));
      }
      for (final (ref, matches) in callers) {
        final caller =
            Hop(ref.file, ref.node, ref.owner, ref: ref, matches: matches);
        if (ref.owner != null && visited.contains(ref.owner)) {
          chains.add(Chain([caller, ...chain], 'cycle', null));
          continue;
        }
        walk(caller, chain, {...visited, if (ref.owner != null) ref.owner!});
      }
    }

    walk(Hop(site.file, site.node, site.owner), const [],
        {if (site.owner != null) site.owner!});
    return (chains, truncated);
  }

  /// The destination along one chain, substituting forwarded arguments.
  Evaluation destination(NavigationSite site, Chain chain) {
    var env = _Env(chain.hops.first.owner, chain.hops.first.file, const {});
    for (var i = 0; i + 1 < chain.hops.length; i++) {
      final ref = chain.hops[i].ref;
      final callee = chain.hops[i + 1].owner;
      env = _Env(callee, chain.hops[i + 1].file,
          ref == null || callee == null ? const {} : _bind(ref, callee, env));
    }
    return _evaluate(site.destination, env);
  }

  /// Source conditions that must hold at [hop], innermost first.
  ///
  /// For a callback root, `on_event` conditions sit inside the callback and
  /// `at_creation` conditions decide whether the callback is bound at all.
  List<Map<String, Object?>> conditionsAt(Hop hop, {bool root = false}) {
    final out = <Map<String, Object?>>[];
    final slot = root ? _slot(hop.node, hop.owner?.node)?.$1 : null;
    var phase = slot == null
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
        case SwitchStatement n when child is SwitchMember:
          add(child, 'switch', '${n.expression}', _caseLabel(child));
        case SwitchExpression n when child is SwitchExpressionCase:
          add(child, 'switch', '${n.expression}',
              'case ${child.guardedPattern}');
        case WhileStatement n when identical(child, n.body):
          add(n, 'loop', '${n.condition}', true);
        case ForStatement n when identical(child, n.body):
          add(n, 'loop', '${n.forLoopParts}', true);
        case Block n:
          for (final statement in n.statements) {
            if (identical(statement, child)) break;
            if (statement is IfStatement &&
                statement.elseStatement == null &&
                _exits(statement.thenStatement)) {
              add(
                  statement,
                  'guard',
                  [statement.expression, statement.caseClause]
                      .whereType<AstNode>()
                      .join(' '),
                  false);
            }
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
          // `ClassName.member(...)` names its class; any other receiver is untyped.
          final type = target.toSource();
          return _classes.contains(type)
              ? members.where((d) => d.className == type).toList()
              : members.toList();
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
        final functions = all.where(
            (d) => d.parent == null && d.className == null && visible(d));
        final sameLibrary =
            functions.where((d) => d.file.library == ref.file.library).toList();
        if (sameLibrary.isNotEmpty) return sameLibrary;
        if (functions.isNotEmpty) return functions.toList();
        // An unqualified call can reach an inherited member of any class.
        return members.toList();
      }();

  Map<String, (Expression, _Env)> _bind(Ref ref, Decl callee, _Env env) {
    final arguments = ref.arguments?.arguments ?? const <Expression>[];
    final positional = arguments.where((a) => a is! NamedExpression).toList();
    final out = <String, (Expression, _Env)>{};
    var i = 0;
    for (final parameter
        in callee.parameters?.parameters ?? const <FormalParameter>[]) {
      final name = parameter.name?.lexeme;
      Expression? value;
      if (parameter.isNamed) {
        value = arguments
            .whereType<NamedExpression>()
            .where((a) => a.name.label.name == name)
            .firstOrNull
            ?.expression;
      } else if (i < positional.length) {
        value = positional[i++];
      }
      if (name != null &&
          value != null &&
          !callee._scope.reassigned.contains(name)) {
        out[name] = (value, env);
      }
    }
    return out;
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
              forwarded: true, reason: result.reason);
        }
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
        return _constant(
            className != null && _consts.containsKey('$className.$name')
                ? '$className.$name'
                : name,
            env.file,
            depth);
      case PrefixedIdentifier():
        final field = _providerRecordField(e, env);
        if (field != null) return _evaluate(field.$1, field.$2, depth + 1);
        return _constant(
            '${e.prefix.name}.${e.identifier.name}', env.file, depth);
      case MethodInvocation(target: null)
          when e.methodName.name.startsWith(RegExp('[A-Z]')) &&
              e.argumentList.arguments.length == 1:
        // A wrapper such as `RouteInfo('/home')`.
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
      case InstanceCreationExpression()
          when e.argumentList.arguments.length == 1:
        return _evaluate(e.argumentList.arguments.single, env, depth + 1);
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

  /// Whether [hop] sits in a closure other than its callback slot, so the
  /// link only creates the closure; running it is not established.
  bool inClosure(Hop hop) {
    final slot = _slot(hop.node, hop.owner?.node)?.$1;
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
  const _Env(this.owner, this.file, this.arguments) : _className = null;

  _Env.constant(this.file, this._className)
      : owner = null,
        arguments = const {};

  final Decl? owner;
  final SourceFile file;
  final Map<String, (Expression, _Env)> arguments;
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
  final _routeNodes = <AstNode, RouteDecl>{};
  String? _class;
  Decl? _decl;

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

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final superclass = node.extendsClause?.superclass.toSource();
    if (superclass != null) {
      index._superclasses[node.name.lexeme] =
          superclass.split('<').first.split('.').last;
    }
    _inClass(node.name.lexeme, () => super.visitClassDeclaration(node));
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) =>
      _inClass(node.name.lexeme, () => super.visitMixinDeclaration(node));

  @override
  void visitEnumDeclaration(EnumDeclaration node) =>
      _inClass(node.name.lexeme, () => super.visitEnumDeclaration(node));

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) => _inClass(
      node.name?.lexeme ?? '<extension>',
      () => super.visitExtensionDeclaration(node));

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) => _inClass(
      node.name.lexeme, () => super.visitExtensionTypeDeclaration(node));

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
    if (node.isStatic && (node.fields.isConst || node.fields.isFinal)) {
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
    if (node.variables.isConst || node.variables.isFinal) {
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
    if (node.target == null && name == 'GoRoute') {
      _route(node, node.argumentList);
    }
    final positional =
        node.argumentList.arguments.any((a) => a is! NamedExpression);
    if (positional &&
        (_locationMethods.contains(name) || _nameMethods.contains(name)) &&
        _isRouter(node.realTarget)) {
      index.navigations
          .add(NavigationSite(file, node, _decl, _nameMethods.contains(name)));
    }
    (index._refs[name] ??= [])
        .add(Ref(file, node, name, _decl, node.realTarget, node.argumentList));
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.toSource().split('.').last == 'GoRoute') {
      _route(node, node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    // A tear-off used as a value: `onTap: _open`, `onTap: controller.open`,
    // `onTap: enabled ? _open : null` or a switch-expression branch.
    final (Expression expression, Expression? target) = switch (node.parent) {
      PrefixedIdentifier p when identical(p.identifier, node) => (p, p.prefix),
      PropertyAccess p when identical(p.propertyName, node) => (
          p,
          p.realTarget
        ),
      _ => (node, null),
    };
    final (value, receiver) = _receiver(expression);
    final tearOff = switch (receiver) {
      NamedExpression() ||
      ArgumentList() ||
      ListLiteral() ||
      ReturnStatement() ||
      ExpressionFunctionBody() =>
        true,
      VariableDeclaration v => identical(v.initializer, value),
      _ => false,
    };
    if (tearOff) {
      (index._refs[node.name] ??= [])
          .add(Ref(file, node, node.name, _decl, target, null));
    }
    super.visitSimpleIdentifier(node);
  }

  void _route(AstNode node, ArgumentList arguments) {
    Expression? named(String name) => arguments.arguments
        .whereType<NamedExpression>()
        .where((a) => a.name.label.name == name)
        .firstOrNull
        ?.expression;
    RouteDecl? parent;
    for (var up = node.parent; up != null && parent == null; up = up.parent) {
      parent = _routeNodes[up];
    }
    final route = RouteDecl(file, node, named('path'), named('name'), parent);
    _routeNodes[node] = route;
    index.routes.add(route);
  }
}

bool _isRouter(Expression? target) {
  if (target == null) return false;
  final source = target.toSource().replaceAll('!', '');
  return source.toLowerCase().endsWith('context') ||
      source.toLowerCase().contains('router');
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
/// parenthesized and switch-expression branches, with the branch it holds.
(AstNode, AstNode?) _receiver(AstNode expression) {
  var child = expression;
  var up = expression.parent;
  while ((up is ConditionalExpression && !identical(up.condition, child)) ||
      up is ParenthesizedExpression ||
      (up is SwitchExpressionCase && identical(up.expression, child)) ||
      (up is SwitchExpression && !identical(up.expression, child))) {
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
