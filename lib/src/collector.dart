part of 'index.dart';

/// Shell routes whose `branches` `goBranch` switches between.
const _shells = {'StatefulShellRoute', 'TypedStatefulShellRoute'};

class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.index, this.file);

  final CodeIndex index;
  final SourceFile file;
  String? _class;
  Decl? _decl;
  bool _extendsRouter = false;
  final _enumPositions = <String, int>{};

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
    final interfaces = node.implementsClause?.interfaces;
    if (interfaces != null) {
      index._interfaces[name] = [
        for (final i in interfaces) _typeName(i.toSource()),
      ];
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
    final on = node.onClause?.extendedType.toSource();
    // In `extension on BuildContext`, a bare `go(...)` navigates `this`.
    _extendsRouter = _isRouterType(on);
    final name = node.name?.lexeme ?? '<extension on $on>';
    if (on != null) index._extensionOn[name] = _typeName(on);
    _inClass(name, () => super.visitExtensionDeclaration(node));
    _extendsRouter = saved;
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    final name = _afterConst(node.typeKeyword.next!);
    // `RouteInfo(String path)`: the representation field is the last name in
    // the first parentheses after the type parameters, whose bounds can hold
    // parentheses of their own.
    var open = name.next!;
    if (open.lexeme == '<') open = open.endGroup?.next ?? open;
    while (open.lexeme != '(' && !open.isEof) {
      open = open.next!;
    }
    var field = open.endGroup?.previous;
    if (field?.lexeme == ',') field = field!.previous;
    if (field != null) index._representations[name.lexeme] = field.lexeme;
    _inClass(name.lexeme, () => super.visitExtensionTypeDeclaration(node));
  }

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
    for (final variable in node.fields.variables) {
      if (_variableType(node.fields.type, variable.initializer)
          case final type?) {
        index._variableTypes['$_class.${variable.name.lexeme}'] = type;
      }
    }
    if (node.isStatic) {
      // Mutable statics count too: route paths are often declared as plain
      // `static String home = '/home';`. The initializer is what is read.
      for (final variable in node.fields.variables) {
        if (variable.initializer case final initializer?) {
          (index._consts['$_class.${variable.name.lexeme}'] ??= [])
              .add((file, initializer, _class));
        }
      }
    } else {
      for (final variable in node.fields.variables) {
        index._instanceFields['$_class.${variable.name.lexeme}'] =
            node.fields.isFinal;
      }
      // A field typed as, or initialized from, a BuildContext or GoRouter.
      for (final variable in node.fields.variables) {
        final value = (variable.initializer?.toSource() ?? '')
            .replaceAll(RegExp('[!?]'), '')
            .toLowerCase();
        if (_isRouterType(node.fields.type?.toSource()) ||
            value.contains('router') ||
            value.endsWith('context')) {
          index._routerFields.add(variable.name.lexeme);
        }
      }
    }
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      if (_variableType(node.variables.type, variable.initializer)
          case final type?) {
        index._variableTypes[variable.name.lexeme] = type;
      }
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
      _creation(node, name, node.argumentList,
          node.typeArguments?.arguments.singleOrNull?.toSource());
    }
    if ((_shells.contains(name) && target == null) ||
        (target is SimpleIdentifier && _shells.contains(target.name))) {
      _shell(node, node.argumentList);
    }
    final positional = _positional(node.argumentList).isNotEmpty;
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
    final source = node.constructorName.type.toSource();
    final type = _typeName(source);
    if (node.constructorName.name == null) {
      _creation(node, type, node.argumentList,
          RegExp(r'<\s*([\w.]+)').firstMatch(source)?.group(1));
    }
    if (_shells.contains(type)) _shell(node, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  /// go_router_builder registrations: `@TypedGoRoute<HomeRoute>(path: '/')`.
  @override
  void visitAnnotation(Annotation node) {
    final type = _typeName(node.name.toSource());
    final arguments = node.arguments;
    if (arguments != null && type.startsWith('Typed')) {
      _creation(node, type, arguments,
          node.typeArguments?.arguments.singleOrNull?.toSource());
      if (_shells.contains(type)) _shell(node, arguments);
    }
    super.visitAnnotation(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    final position =
        _enumPositions.update(_class!, (i) => i + 1, ifAbsent: () => 0);
    index._enumConstants['$_class.${node.name.lexeme}'] =
        (file, node, position);
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

  void _creation(AstNode node, String className, ArgumentList arguments,
      [String? typeArgument]) {
    final type = typeArgument == null ? null : _typeName(typeArgument);
    (index._creations[className] ??= [])
        .add(_Creation(file, node, className, arguments, _decl, type));
    if (className == 'TypedGoRoute' && type != null) {
      index._typedClasses.add(type);
    }
  }

  void _shell(AstNode node, ArgumentList arguments) {
    if (_named(arguments, 'branches') case final ListLiteral branches) {
      index._shellArguments.add((file, node, branches));
    }
  }
}

/// A variable's declared type, or the class its initializer constructs.
String? _variableType(TypeAnnotation? type, Expression? initializer) {
  if (type != null) return _typeName(type.toSource());
  return switch (initializer) {
    InstanceCreationExpression c =>
      _typeName(c.constructorName.type.toSource()),
    MethodInvocation(target: null, :final methodName)
        when _upper.hasMatch(methodName.name) =>
      methodName.name,
    _ => null,
  };
}

/// Names declared inside a declaration, including nested closures.
class _Scope extends GeneralizingAstVisitor<void> {
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

  @override
  void visitFormalParameter(FormalParameter node) {
    if (node.name case final name?) locals.add(name.lexeme);
    _defaultValue(node)?.accept(this);
  }

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
