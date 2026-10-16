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
    final expanded = {...skip};
    var level = [
      [start],
    ];
    while (level.isNotEmpty) {
      final next = <List<Hop>>[];
      for (final chain in level) {
        final hop = chain.first;
        final slot = _slotOf(hop.node, hop.owner?.node);
        final owner = hop.owner;
        Chain? root;
        if (slot != null) {
          root = Chain(chain, slot.$3, slot.$2, slot.$1);
        } else if (owner == null) {
          root = Chain(
              chain, hop.className != null ? 'initializer' : 'no_owner', null);
        } else if (!expanded.add(owner)) {
          skipped.add(chain);
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
    final found = [...chains];
    for (final chain in skipped) {
      final first = chain.first;
      for (final c in found) {
        final i = c.hops.indexWhere((h) => h.owner == first.owner);
        if (i < 0 || identical(c.hops[i].node, first.node)) continue;
        if (chains.length >= limit) return (chains, true);
        chains.add(Chain([...c.hops.sublist(0, i), ...chain], c.rootKind,
            c.slot, c.slotNode));
        break;
      }
    }
    return (chains, false);
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
