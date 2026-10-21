part of 'index.dart';

/// How references, receivers and callback slots link up, by name and scope.
extension _Linking on CodeIndex {
  /// Keeps the candidate calls whose receiver is a go_router object. Those
  /// calls are go_router's methods, so they never link to a project
  /// declaration that happens to share the name.
  void _resolveNavigations() {
    final nodesByName = <String, Set<AstNode>>{};
    for (final (file, node, owner, className, kind, inExtension)
        in _candidates) {
      final receiver = node.realTarget;
      final typed = kind == 'location' && receiver != null
          ? _typedClassOf(receiver)
          : null;
      final navigates = kind == 'branch' ||
          typed != null ||
          (receiver == null || receiver is ThisExpression
              ? inExtension
              : _isRouterReceiver(receiver));
      if (!navigates) continue;
      navigations.add(NavigationSite(
          file, node, owner, className, typed == null ? kind : 'typed',
          typedClass: typed));
      (nodesByName[node.methodName.name] ??= {}).add(node);
    }
    for (final MapEntry(:key, :value) in nodesByName.entries) {
      _refs[key]?.removeWhere((r) => value.contains(r.node));
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
  bool? _declaredRouter(SimpleIdentifier target) =>
      switch (_declaredType(target)) {
        null => null,
        final type => _isRouterType(type),
      };

  /// The declared type of the parameter or local [target] names, or the type
  /// its initializer suggests; null when no such declaration is in scope.
  /// A `*builder` closure's first parameter is a BuildContext.
  String? _declaredType(SimpleIdentifier target) {
    for (AstNode? node = target.parent; node != null; node = node.parent) {
      final parameters = switch (node) {
        FunctionExpression n => n.parameters,
        MethodDeclaration n => n.parameters,
        ConstructorDeclaration n => n.parameters,
        _ => null,
      };
      for (final (i, parameter)
          in (parameters?.parameters ?? const <FormalParameter>[]).indexed) {
        final formal = _formal(parameter);
        if (formal.name?.lexeme != target.name) continue;
        final functionTyped =
            const {'(', '<'}.contains(formal.name?.next?.lexeme);
        final type = formal is FieldFormalParameter ||
                formal is SuperFormalParameter ||
                functionTyped
            ? null
            : formal.childEntities.whereType<TypeAnnotation>().firstOrNull;
        if (type != null) return type.toSource();
        // Flutter builders pass the BuildContext first: `builder: (ctx) =>`.
        final up = node.parent;
        return i == 0 &&
                (_argumentName(up)?.toLowerCase().endsWith('builder') ?? false)
            ? 'BuildContext'
            : '';
      }
      if (node is Block) {
        for (final statement
            in node.statements.whereType<VariableDeclarationStatement>()) {
          for (final variable in statement.variables.variables) {
            if (variable.name.lexeme != target.name) continue;
            final type = statement.variables.type;
            if (type != null) return type.toSource();
            if (_variableType(null, variable.initializer) case final made?) {
              return made;
            }
            final value = variable.initializer
                    ?.toSource()
                    .replaceAll(RegExp('[!?]'), '')
                    .toLowerCase() ??
                '';
            return value.contains('router')
                ? 'GoRouter'
                : value.endsWith('context')
                    ? 'BuildContext'
                    : '';
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
        List<Decl> inClass(String type) {
          _receiverTypes[ref] = type;
          return _membersOf(type, members);
        }

        final target = ref.target;
        final className = ref.owner?.root.className ?? ref.className;
        if (target is SuperExpression) {
          // The nearest declaration above the class in its lineage. Only
          // project classes have members to link; a framework one has none.
          if (className == null) return const <Decl>[];
          Iterable<Decl> nearest(Iterable<String> lineage) => lineage
              .map((t) => members.where((d) => d.className == t))
              .firstWhere((found) => found.isNotEmpty,
                  orElse: () => const <Decl>[]);
          final found = {...nearest(_lineage(className).skip(1))};
          // Above a mixin, it depends on the class applying the mixin.
          for (final MapEntry(:key, :value) in _mixins.entries) {
            if (!value.contains(className)) continue;
            final above = _lineage(key).skipWhile((t) => t != className);
            for (final d in nearest(above.skip(1))) {
              found.add(d);
              ((_superContexts[ref] ??= {})[d] ??= {}).add(key);
            }
          }
          return found.toList();
        }
        if (target != null && target is! ThisExpression) {
          final prefixes =
              _prefixes[ref.file.library] ?? const <String, List<_Namespace>>{};
          // `prefix.f()` names a top-level function of the libraries imported
          // with that prefix.
          if (target is SimpleIdentifier && prefixes.containsKey(target.name)) {
            final libraries = _visible(prefixes[target.name]!, ref.name);
            return all
                .where((d) =>
                    d.parent == null &&
                    d.className == null &&
                    libraries.contains(d.file.library))
                .toList();
          }
          // `C.m()`, `C().m()`, `getIt<C>().m()` and `prefix.C.m()` name the
          // class.
          final type = switch (target) {
            MethodInvocation(target: null, :final methodName)
                when _upper.hasMatch(methodName.name) =>
              methodName.name,
            MethodInvocation(:final typeArguments?)
                when typeArguments.arguments.length == 1 =>
              _typeName(typeArguments.arguments.single.toSource()),
            InstanceCreationExpression(:final constructorName) =>
              _typeName(constructorName.type.toSource()),
            PrefixedIdentifier(:final prefix, :final identifier)
                when prefixes.containsKey(prefix.name) =>
              identifier.name,
            _ => target.toSource(),
          };
          if (_classes.contains(type)) return inClass(type);
          // A receiver declared with a project class type: `final Flow flow;`.
          final declared = _staticType(target, className);
          if (declared != null && _classes.contains(declared)) {
            return inClass(declared);
          }
          // Extension members apply by the receiver's type: a BuildContext, a
          // GoRouter or a class outside the project has no other members here.
          if (_receiverType(target, className) case final receiver?) {
            return members
                .where((d) => _extensionOn[d.className] == receiver)
                .toList();
          }
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
        if (own.isNotEmpty) return _withOverrides(own, className, members);
        // Members inherited from project superclasses and mixins.
        final inherited = [
          if (className != null) ..._lineage(className).skip(1)
        ];
        for (final type in inherited) {
          final found = members.where((d) => d.className == type).toList();
          if (found.isNotEmpty) {
            return _withOverrides(found, className, members);
          }
        }
        final functions = all.where(
            (d) => d.parent == null && d.className == null && visible(d));
        final sameLibrary =
            functions.where((d) => d.file.library == ref.file.library).toList();
        if (sameLibrary.isNotEmpty) return sameLibrary;
        final imports =
            _visible(_imports[ref.file.library] ?? const [], ref.name);
        final imported =
            functions.where((d) => imports.contains(d.file.library)).toList();
        if (imported.isNotEmpty) return imported;
        // Not reachable through the project's imports; the name is a guess.
        if (functions.isNotEmpty) return _guess(ref, functions);
        // An unqualified call can reach a member inherited from outside the
        // project; a bare name read is a field or local far more often.
        return ref.arguments == null ? const <Decl>[] : _guess(ref, members);
      }();

  /// Members a call on an instance of [type] can reach: its own, else those
  /// of the nearest mixin (last applied first) or superclass that declares the
  /// name, with their overrides; else project extensions on the type or a
  /// supertype.
  List<Decl> _membersOf(String type, Iterable<Decl> members) {
    final lineage = _lineage(type);
    for (final t in lineage) {
      final found = members.where((d) => d.className == t).toList();
      if (found.isNotEmpty) return _withOverrides(found, type, members);
    }
    return [
      for (final d in members)
        if (_extensionOn[d.className] case final on? when _isA(type, on)) d,
    ];
  }

  /// [type], its mixins from the last applied, then each superclass the same
  /// way: the order Dart looks a member up in.
  List<String> _lineage(String type) => [
        type,
        ...?_mixins[type]?.reversed,
        for (var c = _superclasses[type], i = 0;
            c != null && i < 16;
            c = _superclasses[c], i++) ...[c, ...?_mixins[c]?.reversed],
      ];

  /// [found] plus the overrides in project subclasses of [type], the class a
  /// call is made on, which the call can dispatch to.
  List<Decl> _withOverrides(
      Iterable<Decl> found, String? type, Iterable<Decl> members) {
    final result = [...found];
    final queue = [type];
    final seen = <String?>{type};
    while (queue.isNotEmpty) {
      for (final sub in _subclasses[queue.removeLast()] ?? const <String>[]) {
        if (!seen.add(sub)) continue;
        queue.add(sub);
        result.addAll(members.where((d) => d.className == sub));
      }
    }
    return result;
  }

  /// The type a receiver is declared with or constructed as: a parameter or
  /// local, a field of the enclosing class (or of the widget a State shows,
  /// for `widget.x`), or a top-level variable.
  String? _staticType(Expression target, String? className) {
    String? field(String? type, String name) {
      for (var c = type, i = 0;
          c != null && i < 16;
          c = _superclasses[c], i++) {
        if (_variableTypes['$c.$name'] case final found?) return found;
      }
      return null;
    }

    return switch (target) {
      SimpleIdentifier t => switch (_declaredType(t)) {
          final declared? when declared.isNotEmpty => _typeName(declared),
          final declared? when declared.isEmpty => null,
          _ => field(className, t.name) ?? _variableTypes[t.name],
        },
      PrefixedIdentifier(:final prefix, :final identifier)
          when prefix.name == 'widget' =>
        field(_stateOf[className], identifier.name),
      PropertyAccess(target: ThisExpression(), :final propertyName) =>
        field(className, propertyName.name),
      _ => null,
    };
  }

  /// The type of a receiver that is not a project class: `BuildContext` for
  /// `context`, `GoRouter` for `GoRouter.of(context)`, or the class outside the
  /// project in `Navigator.of(context)` or `Theme`. Null when untyped.
  String? _receiverType(Expression target, [String? className]) {
    final source = target.toSource().replaceAll(RegExp('[!?]'), '');
    final declared = _staticType(target, className) ?? '';
    if (source.toLowerCase().endsWith('context') ||
        declared.contains('BuildContext')) {
      return 'BuildContext';
    }
    if (source.contains('GoRouter') || declared.contains('GoRouter')) {
      return 'GoRouter';
    }
    final name = switch (target) {
      SimpleIdentifier t => t.name,
      PrefixedIdentifier t => t.prefix.name,
      MethodInvocation(target: SimpleIdentifier t) => t.name,
      MethodInvocation(target: null, :final methodName) => methodName.name,
      _ => null,
    };
    return name != null && _upper.hasMatch(name) && !_classes.contains(name)
        ? name
        : null;
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
      final slot = _argumentName(up) ??
          switch (up) {
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
    final positional = _positional(list).toList();
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
