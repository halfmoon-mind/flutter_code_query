part of 'index.dart';

/// Source conditions that must hold for a hop to run.
extension _Conditions on CodeIndex {
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
