part of 'index.dart';

/// How references, receivers and callback slots link up, by name and scope.
extension _Linking on CodeIndex {
  /// Keeps the candidate calls whose receiver is a go_router object. Those
  /// calls are go_router's methods, so they never link to a project
  /// declaration that happens to share the name.
  void _resolveNavigations() {
    for (final (file, node, owner, className, kind, inExtension)
        in _candidates) {
      final receiver = node.realTarget;
      final typed = kind == 'location' && receiver != null
          ? _typedClassOf(receiver)
          : null;
      final navigates = kind == 'branch' ||
          typed != null ||
          (receiver == null ? inExtension : _isRouterReceiver(receiver));
      if (!navigates) continue;
      navigations.add(NavigationSite(
          file, node, owner, className, typed == null ? kind : 'typed',
          typedClass: typed));
      _refs[node.methodName.name]?.removeWhere((r) => identical(r.node, node));
    }
  }

  /// The go_router_builder route class a receiver constructs, as in
  /// `const HomeRoute().go(context)`.
  String? _typedClassOf(Expression target) {
    final type = switch (target) {
      InstanceCreationExpression c =>
        _typeName(c.constructorName.type.toSource()),
      MethodInvocation(target: null, :final methodName) => methodName.name,
      _ => null,
    };
    return _typedClasses.contains(type) ? type : null;
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
