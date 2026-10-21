import 'package:analyzer/dart/ast/ast.dart';

import 'index.dart';

const schemaVersion = 1;

const _limits = [
  'Parse-only: a hop with nameMatches was linked by its name alone and may '
      'belong to another declaration.',
  'A deferred hop only creates a closure or passes a tear-off; whether it '
      'runs is not established.',
  'Conditions are source expressions, never evaluated values.',
  'Redirects, deep links and fully dynamic destinations are not candidates.',
];

/// One way to reach a navigation call: an incoming chain, preceded by the
/// path that builds the widget binding its callback root when there is one,
/// with one destination value or `goBranch` index.
class _Path {
  _Path(this.chain, this.build, this.destination, this.branch,
      {this.alternative = false, this.selectedBy});

  final Chain chain;
  final Chain? build;
  final Evaluation? destination;

  /// The `goBranch` index, when the call is one and the index is known.
  final int? branch;

  /// Whether [destination] is one of several values the call can produce.
  final bool alternative;

  /// The branch condition that picks [destination], for `c ? a : b` or a
  /// switch expression written in the call.
  final Map<String, Object?>? selectedBy;
}

class _Site {
  _Site(this.site, this.paths, this.truncated);

  final NavigationSite site;
  final List<_Path> paths;
  final bool truncated;
}

List<_Site> _sites(CodeIndex index) {
  final sites = <_Site>[];
  for (final site in index.navigations) {
    var (chains, truncated) = index.chainsTo(site);
    final paths = <_Path>[];
    for (final chain in chains) {
      final plain = index.destination(site, chain);
      Chain whole(Chain? build) => build == null
          ? chain
          : Chain([...build.hops, ...chain.hops], chain.rootKind, chain.slot,
              chain.slotNode);
      final (builds, cut) = index.buildPaths(chain,
          widgets:
              site.kind != 'branch' && site.kind != 'typed' && !plain.complete);
      truncated |= cut;
      // Widget constructor calls matter only when they change the destination;
      // the others still stand for the unresolved destination.
      List<Chain?> kept = builds;
      if (builds.isNotEmpty && builds.first.hops.last.ref?.creation == true) {
        final changed = [
          for (final build in builds)
            if (_shape(index.destination(site, whole(build))) != _shape(plain))
              build,
        ];
        kept = [...changed, if (changed.length < builds.length) null];
      }
      for (final build in kept.isEmpty ? const <Chain?>[null] : kept) {
        final full = whole(build);
        if (!index.feasible(full)) continue;
        if (site.kind == 'branch') {
          paths.add(_Path(chain, build, null, index.branchIndex(site, full)));
          continue;
        }
        if (site.kind == 'typed') {
          paths.add(_Path(chain, build, null, null));
          continue;
        }
        final destination =
            build == null ? plain : index.destination(site, full);
        // `c ? '/a' : '/b'`, written in the call or in a final local it
        // names: each branch with the condition that picks it.
        final choices = destination.alternatives == null
            ? null
            : _choices(site, chain, index.choiceExpression(site, chain));
        if (choices != null) {
          for (final (branch, selectedBy) in choices) {
            for (final value in index.evaluateAt(branch, full).expand()) {
              paths.add(_Path(chain, build, value, null,
                  alternative: true, selectedBy: selectedBy));
            }
          }
          continue;
        }
        for (final value in destination.expand()) {
          paths.add(_Path(chain, build, value, null,
              alternative: destination.alternatives != null));
        }
      }
    }
    sites.add(_Site(site, paths, truncated));
  }
  return sites;
}

/// Registered routes a path reaches, whether the location was templated,
/// and whether conditional shell branches make the match uncertain.
(List<RouteDecl>, bool templated, bool alternative) _targets(
    CodeIndex index, NavigationSite site, _Path path) {
  if (site.kind == 'typed') {
    return (
      [
        for (final route in index.routes)
          if (route.typedClass == site.typedClass) route,
      ],
      false,
      false,
    );
  }
  if (site.kind == 'branch') {
    final matches = [
      for (final shell in index.shells)
        for (final branch in shell)
          if (branch.route != null &&
              (path.branch == null ||
                  (path.branch! >= branch.first &&
                      (branch.last == null || path.branch! <= branch.last!))))
            branch,
    ];
    return (
      [for (final branch in matches) branch.route!],
      false,
      matches.any((b) => b.conditional),
    );
  }
  final destination = path.destination!;
  if (site.named) {
    // An unevaluated name still matches a registration written the same way.
    final source = site.destination.toSource();
    return (
      index.routes
          .where((r) => destination.complete
              ? r.name == destination.text
              : r.name == null && r.nameExpression?.toSource() == source)
          .toList(),
      false,
      false,
    );
  }
  if (destination.path case final location?) {
    return (index.routesFor(location), false, false);
  }
  if (destination.pathPattern case final pattern?) {
    return (index.routesForPattern(pattern), true, false);
  }
  return (const [], false, false);
}

/// What a destination is known to be, alternatives included.
String _shape(Evaluation e) => [
      for (final value in e.expand()) '${value.complete}${value.pattern}',
    ].join('|');

/// The branches of a conditional or switch expression written as the
/// destination, each with the condition that picks it.
List<(Expression, Map<String, Object?>)>? _choices(
    NavigationSite site, Chain chain, Expression? expression) {
  final phase =
      chain.rootKind == 'callback' || chain.rootKind == 'callback_factory'
          ? 'on_event'
          : null;
  Map<String, Object?> condition(
          AstNode at, String kind, String expression, Object value) =>
      {
        'at': site.file.at(at),
        'kind': kind,
        'expression': expression,
        'is': value,
        if (phase != null) 'phase': phase,
      };
  return switch (expression) {
    ConditionalExpression e => [
        (e.thenExpression, condition(e, 'if', '${e.condition}', true)),
        (e.elseExpression, condition(e, 'if', '${e.condition}', false)),
      ],
    SwitchExpression e => [
        for (final c in e.cases)
          (
            c.expression,
            condition(
                c, 'switch', '${e.expression}', 'case ${c.guardedPattern}')
          ),
      ],
    _ => null,
  };
}

Map<String, Object?> routeList(CodeIndex index) => {
      'schemaVersion': schemaVersion,
      'routes': [
        for (final route in index.routes)
          {
            'path': route.path,
            if (route.pathPrefix != null) 'pathPrefix': route.pathPrefix,
            if (route.name != null)
              'name': route.name
            else if (route.nameExpression != null)
              'nameExpression': '${route.nameExpression}',
            'at': route.file.at(route.node),
          },
      ],
      if (index.skippedLinks > 0) 'skippedLinks': index.skippedLinks,
      if (index.parseErrors.isNotEmpty)
        'parseErrors': [
          for (final e in index.parseErrors) {'at': e.at, 'message': e.message},
        ],
    };

Map<String, Object?> check(CodeIndex index) {
  final sites = _sites(index);
  final findings = <Map<String, Object?>>[];
  final reached = <RouteDecl>{};
  // A destination can still match a route whose path or name did not evaluate.
  final partial = [
    for (final route in index.routes)
      if (route.path == null) route.pathPrefix ?? '',
  ];
  final anyPathUnknown = partial.any((prefix) => prefix.length <= 1);
  final anyNameUnknown =
      index.routes.any((r) => r.nameExpression != null && r.name == null);
  for (final s in sites) {
    final unknown = <String>{};
    final uncertain = <String>{};
    final unresolved = <String, String?>{};
    for (final path in s.paths) {
      final (targets, _, _) = _targets(index, s.site, path);
      reached.addAll(targets);
      final destination = path.destination;
      if (targets.isNotEmpty || destination == null) continue;
      final value = s.site.named
          ? (destination.complete ? destination.text : null)
          : destination.path;
      if (value == null) {
        unresolved[destination.text] = destination.reason ??
            (destination.complete ? 'relative_location' : null);
      } else if (s.site.named ||
          !partial.any((p) => p.length > 1 && value.startsWith(p))) {
        unknown.add(value);
      } else {
        // A route with a partly known path may match it.
        uncertain.add(value);
      }
    }
    final at = s.site.file.at(s.site.node);
    for (final destination in {...unknown, ...uncertain}) {
      final info = uncertain.contains(destination) ||
          (s.site.named ? anyNameUnknown : anyPathUnknown);
      findings.add({
        'check': 'unknown_destination',
        'severity': info ? 'info' : 'warning',
        'at': at,
        'destination': destination,
        'expression': '${s.site.destination}',
        if (info)
          'note': 'Some route ${s.site.named ? 'names' : 'paths'} could not '
              'be evaluated, so this destination may match one of them.',
      });
    }
    if (unresolved.isNotEmpty) {
      findings.add({
        'check': 'unresolved_destination',
        'severity': 'info',
        'at': at,
        'expression': '${s.site.destination}',
        'knownPrefixes': unresolved.keys.toList(),
        'reasons': unresolved.values.whereType<String>().toSet().toList(),
      });
    }
    if (s.paths.isNotEmpty &&
        s.paths.every((p) => p.chain.rootKind == 'no_callers')) {
      findings.add({
        'check': 'uncalled_navigation',
        'severity': 'info',
        'at': at,
        'symbol': s.site.owner?.symbol,
      });
    }
  }
  // Routes of different router configurations never conflict.
  final byPath = <(String, AstNode?), List<RouteDecl>>{};
  for (final route in index.routes) {
    final path = route.path;
    if (path == null) {
      findings.add({
        'check': 'unresolved_route_path',
        'severity': 'info',
        'at': route.file.at(route.node),
        'expression': '${route.pathExpression}',
        if (route.pathPrefix != null) 'knownPrefix': route.pathPrefix,
      });
      continue;
    }
    (byPath[(path, route.tree)] ??= []).add(route);
    if (reached.contains(route)) continue;
    final references = _references(index, route);
    findings.add({
      'check': 'route_without_navigation',
      'severity': 'info',
      'route': path,
      'at': route.file.at(route.node),
      'otherReferences': references.length,
      if (references.isNotEmpty) 'referencedAt': references.take(5).toList(),
    });
  }
  final byFullPath = <String, List<RouteDecl>>{};
  for (final MapEntry(key: (path, _), value: routes) in byPath.entries) {
    (byFullPath[path] ??= []).addAll(routes);
  }
  for (final MapEntry(key: path, value: routes) in byFullPath.entries) {
    // Copies of one registration under several parents are not duplicates,
    // and two router configurations never conflict. A route outside any
    // GoRouter or RoutingConfig call can end up in either.
    final unique = {for (final r in routes) r.node: r}.values.toList();
    final registrations = [
      for (final r in unique)
        if (unique.any((o) =>
            !identical(o, r) &&
            (o.tree == null || r.tree == null || identical(o.tree, r.tree))))
          r,
    ];
    if (registrations.length > 1) {
      findings.add({
        'check': 'duplicate_route',
        'severity': 'warning',
        'route': path,
        'at': registrations.first.file.at(registrations.first.node),
        'alsoAt': [
          for (final r in registrations.skip(1)) r.file.at(r.node),
        ],
      });
    }
  }
  for (final error in index.parseErrors) {
    findings.add({
      'check': 'parse_error',
      'severity': 'warning',
      'at': error.at,
      'message': error.message,
    });
  }
  return {
    'schemaVersion': schemaVersion,
    'stats': {
      'files': index.files.length,
      'routes': index.routes.length,
      'navigationSites': sites.length,
      'chains': sites.fold<int>(0, (n, s) => n + s.paths.length),
      'truncatedSites': sites.where((s) => s.truncated).length,
      'parseErrors': index.parseErrors.length,
      if (index.skippedLinks > 0) 'skippedLinks': index.skippedLinks,
    },
    'findings': [
      ...findings.where((f) => f['severity'] == 'warning'),
      ...findings.where((f) => f['severity'] != 'warning'),
    ],
    'limits': _limits,
  };
}

/// Candidates for a route given by path (`/settings`) or by route name.
Map<String, Object?> query(CodeIndex index, String target) {
  final byName = !target.startsWith('/');
  final cut = target.indexOf(RegExp('[?#]'));
  final path = byName || cut < 0 ? target : target.substring(0, cut);
  final registrations = index.routes
      .where((r) => byName ? r.name == target : r.path == path)
      .toList();
  final names = {
    for (final r in registrations)
      if (r.name != null) r.name!,
  };
  final paths = {
    for (final r in registrations)
      if (r.path != null) r.path!,
  };
  final candidates = <Map<String, Object?>>[];
  final possible = <Map<String, Object?>>[];
  final dynamicSites = <Map<String, Object?>>[];
  final truncated = <String>[];
  for (final s in _sites(index)) {
    final at = s.site.file.at(s.site.node);
    if (s.truncated) truncated.add(at);
    String? prefix;
    var dynamic = false;
    for (final p in s.paths) {
      final (targets, templated, alternative) = _targets(index, s.site, p);
      if (targets.any(registrations.contains)) {
        candidates.add(
            _candidate(index, s.site, p, templated, alternative: alternative));
        continue;
      }
      final destination = p.destination;
      // A templated value matching one route may also reach a static sibling
      // of the same shape, so it still gets the prefix check below.
      if (destination == null || (targets.isNotEmpty && !templated)) continue;
      final known = destination.text;
      if (s.site.named) {
        if (destination.complete) continue;
        if (known.isNotEmpty && names.any((n) => n.startsWith(known))) {
          prefix = known;
        } else if (known.isEmpty) {
          dynamic = true;
        }
      } else if (destination.path == null) {
        // Relative, or nothing beyond `/` known: it can reach any route.
        final pattern = destination.pathPattern;
        if (!known.startsWith('/') || known.length <= 1) {
          dynamic = true;
        } else if (paths.any((path) =>
            _prefixFits(known, path) ||
            // `/items/$id` can also be `/items/new`.
            (pattern != null && _sameShape(pattern, path)))) {
          prefix = known;
        }
      }
    }
    final expression = {'at': at, 'expression': '${s.site.destination}'};
    if (prefix != null) {
      possible.add({...expression, 'knownPrefix': prefix});
    } else if (dynamic) {
      dynamicSites.add(expression);
    }
  }
  return {
    'schemaVersion': schemaVersion,
    'route': target,
    'registrations': [
      for (final r in registrations)
        {
          'at': r.file.at(r.node),
          if (byName && r.path != null) 'path': r.path,
          if (r.name != null) 'name': r.name,
        },
    ],
    if (registrations.isEmpty) 'suggestions': _suggest(index, path),
    'candidates': candidates,
    // Any of these can make the candidate list incomplete.
    if (possible.isNotEmpty) 'prefixMatches': possible,
    if (dynamicSites.isNotEmpty) 'dynamicSites': dynamicSites,
    if (truncated.isNotEmpty) 'truncatedSites': truncated,
    if (index.skippedLinks > 0) 'skippedLinks': index.skippedLinks,
    if (index.parseErrors.isNotEmpty)
      'parseErrors': [
        for (final e in index.parseErrors) {'at': e.at, 'message': e.message},
      ],
    'limits': _limits,
  };
}

/// Whether a location starting with [prefix] can match [pattern], segment by
/// segment; `:param` segments match anything.
bool _prefixFits(String prefix, String pattern) {
  final known = prefix.split('/');
  final wanted = pattern.split('/');
  for (var i = 0; i < known.length; i++) {
    if (i >= wanted.length) return false;
    if (wanted[i].startsWith(':')) continue;
    final last = i == known.length - 1;
    if (last ? !wanted[i].startsWith(known[i]) : wanted[i] != known[i]) {
      return false;
    }
  }
  return true;
}

/// Whether a location with unknown parts has as many segments as [path]
/// and agrees with it wherever both are known.
bool _sameShape(String pattern, String path) {
  final wanted = pattern.split('/');
  final have = path.split('/');
  if (wanted.length != have.length) return false;
  for (var i = 0; i < wanted.length; i++) {
    if (wanted[i].contains(hole) || have[i].startsWith(':')) continue;
    if (wanted[i] != have[i]) return false;
  }
  return true;
}

Map<String, Object?> _candidate(
    CodeIndex index, NavigationSite site, _Path path, bool templated,
    {bool alternative = false}) {
  final chain = path.chain;
  final build = path.build;
  final first = chain.hops.first;
  final within = index.within(chain);
  final destination = path.destination;
  return {
    'root': {
      'kind': chain.rootKind,
      if (chain.slot != null) 'slot': chain.slot,
      'at': first.file.at(chain.slotNode ?? first.node),
      'symbol': first.owner?.symbol,
      if (within != null)
        'within': {'slot': within.$2, 'at': first.file.at(within.$1)},
    },
    if (build != null)
      'builtBy': {
        'kind': build.rootKind,
        if (build.slot != null) 'slot': build.slot,
        'hops': [for (final hop in build.hops) _hop(index, hop)],
      },
    'hops': [for (final hop in chain.hops) _hop(index, hop)],
    'destination': {
      'expression': '${site.destination}',
      if (destination != null) ...{
        'value': destination.display,
        if (destination.forwarded) 'forwarded': true,
        if (templated) 'templated': true,
      } else if (site.kind == 'typed')
        'routeClass': site.typedClass
      else
        'branch': path.branch ?? 'any',
      if (path.alternative || alternative) 'alternative': true,
    },
    'conditions': [
      if (build != null)
        for (final hop in build.hops)
          ...index.conditionsAt(hop, phase: 'at_creation'),
      for (final (i, hop) in chain.hops.indexed)
        ...switch ((i, chain.rootKind)) {
          (0, 'callback' || 'callback_factory') =>
            index.conditionsAt(hop, root: true),
          (1, 'callback_factory') => index.conditionsAt(hop, factory: true),
          (_, 'callback' || 'callback_factory') =>
            index.conditionsAt(hop, phase: 'on_event'),
          // A listener or other closure: outside it at creation, inside when
          // it runs.
          _ => index.conditionsAt(hop, factory: index.deferred(hop)),
        },
      if (path.selectedBy case final selected?) selected,
    ],
  };
}

Map<String, Object?> _hop(CodeIndex index, Hop hop) => {
      'at': hop.file.at(hop.node),
      'symbol': hop.owner?.symbol,
      'code': _code(hop.node),
      if (hop.guessed) 'nameMatches': hop.matches,
      if (index.deferred(hop)) 'deferred': true,
    };

String _code(AstNode node) => switch (node) {
      MethodInvocation n => '${n.methodName}(...)',
      InstanceCreationExpression n => '${n.constructorName}(...)',
      _ => '$node',
    };

/// Lines outside the registration that mention the route: its full path or
/// name as a string literal, or the constant its path is written with.
List<String> _references(CodeIndex index, RouteDecl route) {
  final constant = index.pathConstant(route);
  final needles = [
    if (route.path case final path?) ...["'$path'", '"$path"'],
    if (route.name case final name?) ...["'$name'", '"$name"'],
    if (constant != null) constant.$1,
  ];
  final typed = index.typedUses(route);
  if (needles.isEmpty) return typed;
  final pattern =
      RegExp('(${needles.map(RegExp.escape).join('|')})(?![\\w\$])');
  // One per line; the line declaring the path constant is its definition.
  return {
    ...typed,
    for (final file in index.files)
      for (final match in pattern.allMatches(file.content))
        if (file != route.file ||
            match.start < route.node.offset ||
            match.start >= route.node.end)
          '${file.path}:${file.lineInfo.getLocation(match.start).lineNumber}',
  }.where((at) => at != constant?.$2).toList();
}

List<Map<String, Object?>> _suggest(CodeIndex index, String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toSet();
  return [
    for (final route in index.routes)
      if (route.path != null && route.path!.split('/').any(segments.contains))
        {'path': route.path, 'at': route.file.at(route.node)},
  ].take(10).toList();
}
