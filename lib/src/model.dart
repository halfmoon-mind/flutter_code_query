part of 'index.dart';

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

/// A library as an import or export directive shows its names: `show` keeps
/// only those listed, `hide` drops them.
class _Namespace {
  _Namespace(this.path, NamespaceDirective directive) {
    for (final combinator in directive.combinators) {
      final [keyword, ...names] =
          combinator.toSource().split(RegExp(r'[\s,]+'));
      if (keyword == 'show') {
        show = show?.intersection(names.toSet()) ?? names.toSet();
      } else {
        hide.addAll(names);
      }
    }
  }

  final String path;
  Set<String>? show;
  final hide = <String>{};

  bool allows(String name) =>
      (show?.contains(name) ?? true) && !hide.contains(name);
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
  NavigationSite(this.file, this.node, this.owner, this.className, this.kind,
      {this.typedClass});

  final SourceFile file;
  final MethodInvocation node;
  final Decl? owner;
  final String? className;

  /// `location` (`go`, `push`...), `name` (`goNamed`...), `branch`
  /// (`goBranch`) or `typed` (`const HomeRoute().go(context)`).
  final String kind;

  /// The go_router_builder route class a `typed` call navigates to.
  final String? typedClass;

  bool get named => kind == 'name';

  /// The location or name argument; the route object for a `typed` call.
  Expression get destination =>
      kind == 'typed' ? node.realTarget! : _positional(node.argumentList).first;
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

  /// The go_router_builder class of a `TypedGoRoute<T>` registration.
  String? typedClass;

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

/// A constructor call; the ones of route classes become registrations.
class _Creation {
  _Creation(this.file, this.node, this.className, this.arguments, this.owner,
      [this.typeArgument]);

  final SourceFile file;
  final AstNode node;
  final String className;
  final ArgumentList arguments;
  final Decl? owner;

  /// `T` in `TypedGoRoute<T>(...)`.
  final String? typeArgument;
}
