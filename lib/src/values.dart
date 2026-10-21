part of 'index.dart';

/// Static evaluation of locations, names and conditions along a chain.
extension _Values on CodeIndex {
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
    // A local function sees the bindings of the declaration around it.
    if (callee.parent != null) {
      return _Env(callee, callee.file, {...env.arguments, ...bound},
          absent: {...env.absent, ...absent}, fields: env.fields);
    }
    return _Env(callee, callee.file, bound, absent: absent);
  }

  /// The environment of a widget's `build` reached from a constructor call:
  /// fields set through `this.x` parameters or initializers.
  _Env _widgetEnv(Ref creation, Decl build, _Env env) =>
      _Env(build, build.file, const {},
          fields: _fieldsOf(creation.name, creation.arguments, env));

  /// Final fields a constructor call of [className] sets through `this.x`
  /// parameters or initializers; other fields can change later.
  Map<String, (Expression, _Env)> _fieldsOf(
      String className, ArgumentList? arguments, _Env env) {
    final constructor = _constructor(className);
    if (constructor == null) {
      // An extension type's representation field takes the one argument.
      final field = _representations[className];
      final value = arguments?.arguments.singleOrNull;
      return field == null || value == null || value is NamedExpression
          ? const {}
          : {field: (value, env)};
    }
    final inner = _call(arguments, constructor, env);
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
    fields
        .removeWhere((name, _) => _instanceFields['$className.$name'] == false);
    return fields;
  }

  /// What a field of the object an expression constructs holds, or else a
  /// getter its class declares, read with those fields: `item.path` where
  /// `item` holds `NavigationItem(path: '/products')`.
  Evaluation? _objectField(
      Expression object, String field, _Env env, int depth) {
    if (_objectOf(object, env, depth)
        case (final className, final arguments, final caller)) {
      // Classes of that name in several libraries can't be told apart.
      final libraries = {
        for (final d in _decls[className] ?? const <Decl>[])
          if (d.className == className) d.file.library,
      };
      if (libraries.length > 1) return null;
      final fields = _fieldsOf(className, arguments, caller);
      if (fields[field] case (final value, final at)) {
        return _evaluate(value, at, depth + 1);
      }
      if (_getter(className, field) case final getter?) {
        return _callValue(getter, null, caller, field, depth, fields);
      }
    }
    return null;
  }

  /// The constructor call an expression holds, following bound parameters,
  /// final locals, constants and static fields: the class, the arguments and
  /// the environment they evaluate in.
  (String, ArgumentList, _Env)? _objectOf(
      Expression object, _Env env, int depth) {
    if (depth > 8) return null;
    switch (object) {
      case SimpleIdentifier():
        final bound = env.arguments[object.name] ?? env.fields[object.name];
        if (bound != null) return _objectOf(bound.$1, bound.$2, depth + 1);
        final local = env.owner?._scope.finals[object.name];
        if (local != null && local.length == 1 && local.single != null) {
          return _objectOf(local.single!, env, depth + 1);
        }
      case MethodInvocation(
            target: null,
            :final methodName,
            :final argumentList
          )
          when _upper.hasMatch(methodName.name):
        return (methodName.name, argumentList, env);
      case InstanceCreationExpression(
            :final constructorName,
            :final argumentList
          )
          when constructorName.name == null:
        return (_typeName(constructorName.type.toSource()), argumentList, env);
    }
    return switch (_constantOf(object, env)) {
      (final value, final at) => _objectOf(value, at, depth + 1),
      null => null,
    };
  }

  /// A list or map literal's elements of type [T] in order, with spreads of
  /// known literals expanded. [maybe] marks one an `if` or `for` element may
  /// leave out or repeat. Not [complete] when an unknown spread leaves
  /// elements out.
  (List<(T, _Env, bool maybe)>, bool complete)
      _elementsOf<T extends CollectionElement>(TypedLiteral literal, _Env env) {
    final out = <(T, _Env, bool)>[];
    var complete = true;
    void addAll(TypedLiteral literal, _Env env, bool maybe, int depth) {
      void add(CollectionElement? element, bool maybe) {
        if (element is T) {
          out.add((element, env, maybe));
        } else if (element is IfElement) {
          add(element.thenElement, true);
          add(element.elseElement, true);
        } else if (element is ForElement) {
          add(element.body, true);
        } else if (element != null) {
          final inner = element is SpreadElement && depth < 4
              ? _literalOf<TypedLiteral>(element.expression, env)
              : null;
          if (inner == null) {
            complete = false;
          } else {
            addAll(inner.$1, inner.$2, maybe, depth + 1);
          }
        }
      }

      for (final element in switch (literal) {
        ListLiteral(:final elements) ||
        SetOrMapLiteral(:final elements) =>
          elements,
      }) {
        add(element, maybe);
      }
    }

    addAll(literal, env, false, 0);
    return (out, complete);
  }

  /// The literal of type [T] an expression names, with the environment its
  /// elements evaluate in: a bound parameter or widget field, a final local,
  /// a constant or a static field.
  (T, _Env)? _literalOf<T extends TypedLiteral>(Expression e, _Env env,
      [int depth = 0]) {
    if (depth > 8) return null;
    if (e is T) return (e, env);
    final name = switch (e) {
      SimpleIdentifier() => e.name,
      PrefixedIdentifier() when e.prefix.name == 'widget' => e.identifier.name,
      _ => null,
    };
    if (name != null) {
      final bound = env.arguments[name] ?? env.fields[name];
      if (bound != null) return _literalOf<T>(bound.$1, bound.$2, depth + 1);
      final local = env.owner?._scope.finals[name];
      if (e is SimpleIdentifier &&
          local != null &&
          local.length == 1 &&
          local.single != null) {
        return _literalOf<T>(local.single!, env, depth + 1);
      }
      if (e is SimpleIdentifier && env.owner == null) {
        if (_localInitializer(e) case final value?) {
          return _literalOf<T>(value, env, depth + 1);
        }
      }
    }
    return switch (_constantOf(e, env)) {
      (final value, final at) => _literalOf<T>(value, at, depth + 1),
      null => null,
    };
  }

  /// What `map[key]` reads: the value of the last entry with that key, or
  /// null when none has it. An entry an `if` or `for` element adds, or one
  /// whose key is unknown, may be the one read, and a map that is not
  /// constant can change after its initializer.
  Evaluation _entry(SetOrMapLiteral map, _Env mapEnv, Expression key, _Env env,
      String source, int depth) {
    final (entries, complete) = _elementsOf<MapLiteralEntry>(map, mapEnv);
    final matches = _equalTo(key, env, depth);
    final values = <Evaluation>[];
    var found = false;
    for (final (entry, entryEnv, maybe) in entries.reversed) {
      final same = matches(entry.key, entryEnv);
      if (same == false) continue;
      values.add(_evaluate(entry.value, entryEnv, depth + 1));
      found = same == true && !maybe;
      if (found) break;
    }
    return Evaluation.of([
      ...values.reversed,
      if (!found) Evaluation.nullValue,
      if (!complete || !map.isConst)
        Evaluation.unknown(source, 'dynamic_expression'),
    ]);
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

  /// What a call of a function with known returns evaluates to. A getter
  /// reads [fields] of its object.
  Evaluation? _callValue(
      Decl callee, ArgumentList? arguments, _Env env, String source, int depth,
      [Map<String, (Expression, _Env)> fields = const {}]) {
    final returns = _returns(callee);
    if (returns.isEmpty) return null;
    final inner = arguments == null
        ? _Env(callee, callee.file, const {}, fields: fields)
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
    final (file, constant, position) = entry;
    if (field == 'name') return Evaluation(value, true);
    if (field == 'index') return Evaluation('$position', true);
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
    // A dot shorthand (`.settings`) names a constant of the expected enum;
    // it resolves when exactly one project enum has that constant.
    if (RegExp(r'^\.(\w+)$').firstMatch(e.toSource()) case final shorthand?) {
      final matches = [
        for (final key in _enumConstants.keys)
          if (key.endsWith('.${shorthand.group(1)}')) key,
      ];
      if (matches.length != 1) return null;
      final dot = matches.single.lastIndexOf('.');
      return (
        matches.single.substring(0, dot),
        matches.single.substring(dot + 1),
      );
    }
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
        final same = _equalTo(e.leftOperand, env, depth)(e.rightOperand, env);
        return same == null ? null : same == equal;
      case SimpleIdentifier():
        final bound = env.arguments[e.name] ?? env.fields[e.name];
        return bound == null ? null : _bool(bound.$1, bound.$2, depth + 1);
      case PrefixedIdentifier() when e.prefix.name == 'widget':
        final bound = env.fields[e.identifier.name];
        return bound == null ? null : _bool(bound.$1, bound.$2, depth + 1);
    }
    return null;
  }

  /// Compares values with [e], evaluated once: equal when both are the same
  /// enum constant, or both evaluate in full to the same text and are not
  /// written as different kinds of value, such as `1` and `'1'`.
  bool? Function(Expression, _Env) _equalTo(Expression e, _Env env, int depth) {
    // The enum constant, the kind a literal or constructor call is written
    // as, and the value.
    ((String, String)?, String?, Evaluation) operand(Expression e, _Env env) =>
        (
          _enumValue(e, env, depth),
          switch (e) {
            StringLiteral() => 'String',
            IntegerLiteral() => 'int',
            _ => switch (_objectOf(e, env, depth)) {
                // An extension type is its representation at runtime.
                (final type, _, _) when !_representations.containsKey(type) =>
                  type,
                _ => null,
              },
          },
          _evaluate(e, env, depth + 1),
        );
    final a = operand(e, env);
    return (other, otherEnv) {
      final b = operand(other, otherEnv);
      if (a.$1 != null && b.$1 != null) return a.$1 == b.$1;
      if (a.$2 != null && b.$2 != null && a.$2 != b.$2) return false;
      return a.$3.complete && b.$3.complete ? a.$3.text == b.$3.text : null;
    };
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
        return Evaluation('${e.value ?? e.literal.lexeme}', true);
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
        if (_objectField(e.prefix, e.identifier.name, env, depth)
            case final value?) {
          return value.asForwarded;
        }
        // `prefix.kHome` through an import prefix names a top-level constant
        // of the libraries imported with it.
        final (key, within) = _constantKey(e, env)!;
        if (within == null && !_consts.containsKey(key)) {
          final getter = _getter(e.prefix.name, e.identifier.name);
          if (getter != null) {
            final value = _callValue(getter, null, env, key, depth);
            if (value != null) return value;
          }
        }
        return _constant(key, env.file, depth, within);
      case PropertyAccess(:final realTarget, :final propertyName)
          when propertyName.name == 'location' &&
              _typedClassOf(realTarget) != null:
        // `const HomeRoute().location` from go_router_builder.
        final type = _typedClassOf(realTarget);
        return _routeTemplate([
              for (final route in routes)
                if (route.typedClass == type) route.path,
            ]) ??
            unknown();
      case PropertyAccess(:final realTarget, :final propertyName)
          when realTarget is IndexExpression && realTarget.target != null:
        // `items[index].path` over a list literal: that element's field, or
        // every element's when the index is unknown.
        final list = _literalOf<ListLiteral>(realTarget.target!, env);
        if (list == null) return unknown();
        final (elements, complete) = _elementsOf<Expression>(list.$1, list.$2);
        final exact = complete && !elements.any((e) => e.$3);
        final index = _evaluate(realTarget.index, env, depth + 1);
        final position = index.complete ? int.tryParse(index.text) : null;
        final chosen = exact && position != null && position < elements.length
            ? [elements[position]]
            : elements;
        return Evaluation.of([
          for (final (element, elementEnv, _) in chosen)
            _objectField(element, propertyName.name, elementEnv, depth) ??
                unknown(),
          // An `if` or `for` element, or an unknown spread, can hold others.
          if (!exact || chosen.isEmpty) unknown(),
        ]);
      case PropertyAccess(realTarget: PrefixedIdentifier(:final prefix))
          when _prefixes[env.file.library]?.containsKey(prefix.name) ?? false:
        // `prefix.Paths.home` through an import prefix.
        final (key, within) = _constantKey(e, env)!;
        return _constant(key, env.file, depth, within);
      case PropertyAccess():
        final target = e.realTarget;
        if (_enumValue(target, env, depth) case (final type, final value)) {
          return _enumField(type, value, e.propertyName.name, depth) ??
              unknown();
        }
        // `RouteName.home.displayName`: a field or getter of an object.
        return _objectField(target, e.propertyName.name, env, depth)
                ?.asForwarded ??
            unknown();
      case ThisExpression():
        // In an extension type, `this` is the representation value.
        if (env.fields[_representations[env.className]]
            case (final value, final caller)) {
          return _evaluate(value, caller, depth + 1).asForwarded;
        }
      case IndexExpression(:final target?):
        // `titles[key]` over a map literal.
        final map = _literalOf<SetOrMapLiteral>(target, env);
        return map == null
            ? unknown()
            : _entry(map.$1, map.$2, e.index, env, e.toSource(), depth);
      case PostfixExpression() when e.operator.lexeme == '!':
        // Any value but null; a value that can only be null stays unknown.
        final values = [
          for (final value in _evaluate(e.operand, env, depth + 1).expand())
            if (!value.isNull) value,
        ];
        return values.isEmpty ? unknown() : Evaluation.of(values);
      case BinaryExpression() when e.operator.lexeme == '??':
        final left = _evaluate(e.leftOperand, env, depth + 1);
        if (left.isNull) return _evaluate(e.rightOperand, env, depth + 1);
        if (left.complete) return left;
        // Unknown at runtime: either side can be the value.
        return Evaluation.of([
          for (final value in left.expand())
            if (!value.isNull) value,
          _evaluate(e.rightOperand, env, depth + 1),
        ]);
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
    if (env.owner == null) {
      if (_localInitializer(e) case final value?) {
        return _evaluate(value, env, depth + 1);
      }
    }
    final className = env.className;
    if (_getter(className, name) case final getter?
        when !_consts.containsKey('$className.$name')) {
      // A State's fields are its widget's, which its getters don't read.
      final value = _callValue(getter, null, env, name, depth,
          _stateOf.containsKey(className) ? const {} : env.fields);
      if (value != null) return value;
    }
    return switch (_constantKey(e, env)) {
      (final key, _) => _constant(key, env.file, depth),
      null => Evaluation.unknown(name, 'dynamic_expression'),
    };
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
    return _routeTemplate([
      for (final route in routes)
        if (route.name == name.text) route.path,
    ]);
  }

  /// Every possible path, with its `:param` segments unknown. Responsive
  /// router configurations can register one name at different paths.
  Evaluation? _routeTemplate(Iterable<String?> paths) {
    final unique = paths.whereType<String>().toSet();
    if (unique.isEmpty) return null;
    return Evaluation.of([
      for (final path in unique)
        _concat([
          for (final (i, segment) in path.split('/').indexed) ...[
            if (i > 0) Evaluation('/', true),
            segment.startsWith(':')
                ? Evaluation.unknown(segment, 'dynamic_expression')
                : Evaluation(segment, true),
          ],
        ]),
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

  /// A constant by key, preferring the same library, then imported ones;
  /// only [within] when a prefix names the libraries.
  Evaluation _constant(String key, SourceFile from, int depth,
      [Set<String>? within]) {
    final candidates = _constantsFor(key, from, within);
    if (candidates.length != 1) {
      return Evaluation.unknown(key,
          candidates.isEmpty ? 'dynamic_expression' : 'ambiguous_constant');
    }
    final (file, initializer, className) = candidates.single;
    return _evaluate(initializer, _Env.constant(file, className), depth + 1);
  }

  /// The initializer of the constant or static field an expression names,
  /// with the environment it evaluates in.
  (Expression, _Env)? _constantOf(Expression e, _Env env) {
    if (_constantKey(e, env) case (final key, final within)) {
      if (_constantsFor(key, env.file, within)
          case [(final file, final initializer, final className)]) {
        return (initializer, _Env.constant(file, className));
      }
    }
    return null;
  }

  /// The key of the constant or static field an expression names, and the
  /// libraries an import prefix limits it to: unqualified in its class,
  /// `Class.field`, or through a prefix. Null for a local, or a member of the
  /// class the code is in, which hides a top-level constant.
  (String, Set<String>?)? _constantKey(Expression e, _Env env) {
    final prefixes = _prefixes[env.file.library] ?? const {};
    final className = env.className;
    switch (e) {
      case SimpleIdentifier(:final name):
        if (env.owner?._scope.locals.contains(name) ?? false) return null;
        if (_consts.containsKey('$className.$name')) {
          return ('$className.$name', null);
        }
        if (className != null &&
            (_instanceFields.containsKey('$className.$name') ||
                (_decls[name]?.any((d) => d.className == className) ??
                    false))) {
          return null;
        }
        return (name, null);
      case PrefixedIdentifier(:final prefix, :final identifier):
        return switch (prefixes[prefix.name]) {
          final within? => (identifier.name, _visible(within, identifier.name)),
          null => ('${prefix.name}.${identifier.name}', null),
        };
      case PropertyAccess(
            realTarget: PrefixedIdentifier(:final prefix, :final identifier),
            :final propertyName
          )
          when prefixes.containsKey(prefix.name):
        return (
          '${identifier.name}.${propertyName.name}',
          _visible(prefixes[prefix.name]!, identifier.name)
        );
    }
    return null;
  }

  /// The declarations a constant key can name from [from], as [_constant]
  /// prefers them.
  List<(SourceFile, Expression, String?)> _constantsFor(
      String key, SourceFile from, Set<String>? within) {
    final matches = [
      for (final m
          in _consts[key] ?? const <(SourceFile, Expression, String?)>[])
        if (within == null || within.contains(m.$1.library)) m,
    ];
    final sameLibrary =
        matches.where((m) => m.$1.library == from.library).toList();
    // A private name is visible only in its own library.
    if (key.startsWith('_') || key.contains('._')) return sameLibrary;
    final imports =
        _visible(_imports[from.library] ?? const [], key.split('.').first);
    final imported =
        matches.where((m) => imports.contains(m.$1.library)).toList();
    return sameLibrary.isNotEmpty
        ? sameLibrary
        : imported.isNotEmpty
            ? imported
            : matches;
  }
}

/// The initializer of a final local named [e] in an enclosing block, for code
/// outside any named declaration, such as a closure in a top-level provider.
Expression? _localInitializer(SimpleIdentifier e) {
  for (AstNode? node = e.parent; node != null; node = node.parent) {
    if (node is! Block) continue;
    for (final statement
        in node.statements.whereType<VariableDeclarationStatement>()) {
      final variables = statement.variables;
      if (!variables.isFinal && !variables.isConst) continue;
      for (final variable in variables.variables) {
        if (variable.name.lexeme == e.name) return variable.initializer;
      }
    }
  }
  return null;
}
