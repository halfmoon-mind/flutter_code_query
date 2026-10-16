part of 'index.dart';

/// Incoming chains: walking callers up from a call to the roots that start it.
extension _Chains on CodeIndex {
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
    final expanded = <Object>{...skip};
    var level = [
      [start],
    ];
    while (level.isNotEmpty) {
      final next = <List<Hop>>[];
      for (final chain in level) {
        final hop = chain.first;
        final slot = _slotOf(hop.node, hop.owner?.node);
        final owner = hop.owner;
        final context = _contextOf(chain);
        Chain? root;
        if (slot != null) {
          root = Chain(chain, slot.$3, slot.$2, slot.$1);
        } else if (owner == null) {
          root = Chain(
              chain, hop.className != null ? 'initializer' : 'no_owner', null);
        } else if (!expanded.add(context == null ? owner : (owner, context))) {
          skipped.add(chain);
          continue;
        } else if (chain.length >= maxChainLength) {
          root = Chain(chain, 'depth_limit', null);
        } else {
          final callers = [
            for (final caller in callersOf(owner))
              if (_fits(caller.$1, context)) caller,
          ];
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
    // A grafted chain can host further call sites, so repeat until stable.
    var pending = skipped;
    while (pending.isNotEmpty) {
      final waiting = <List<Hop>>[];
      for (final chain in pending) {
        final first = chain.first;
        final context = _contextOf(chain);
        Chain? grafted;
        for (final c in chains) {
          final i = c.hops.indexWhere((h) => h.owner == first.owner);
          if (i < 0 || identical(c.hops[i].node, first.node)) continue;
          if (!identical(_contextOf(c.hops.sublist(i)), context)) continue;
          grafted = Chain([...c.hops.sublist(0, i), ...chain], c.rootKind,
              c.slot, c.slotNode);
          break;
        }
        if (grafted == null) {
          waiting.add(chain);
          continue;
        }
        if (chains.length >= limit) return (chains, true);
        chains.add(grafted);
      }
      if (waiting.length == pending.length) break;
      pending = waiting;
    }
    return (chains, false);
  }

  /// The classes applying a mixin that `this` must be in the first hop's
  /// declaration: set by a `super` call of the mixin further down the chain,
  /// reached through calls on `this`.
  Set<String>? _contextOf(List<Hop> chain) {
    for (var i = 0; i < chain.length - 1; i++) {
      final ref = chain[i].ref;
      if (ref == null) return null;
      if (_superContexts[ref]?[chain[i + 1].owner] case final context?) {
        return context;
      }
      if (!_onThis(ref)) return null;
    }
    return null;
  }

  bool _onThis(Ref ref) => switch (ref.target) {
        null || ThisExpression() || SuperExpression() => true,
        _ => false,
      };

  /// Whether [caller] can make its call on an instance of a [context] class.
  bool _fits(Ref caller, Set<String>? context) {
    if (context == null) return true;
    final type = _onThis(caller)
        ? caller.owner?.root.className ?? caller.className
        : _receiverTypes[caller];
    return type == null ||
        context.any(
            (c) => _lineage(c).contains(type) || _lineage(type).contains(c));
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
}
