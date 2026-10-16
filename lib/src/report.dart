import 'package:analyzer/dart/ast/ast.dart';

import 'index.dart';

const schemaVersion = 1;

const _limits = [
  'Parse-only: a hop with nameMatches was linked by its name alone and may '
      'belong to another declaration.',
  'A deferred hop only creates a closure or passes a tear-off; whether it '
      'runs is not established.',
  'Conditions are source expressions, never evaluated values.',
  'Redirects, deep links, shell branch switches and dynamic destinations are '
      'not candidates.',
];

/// One way to reach a navigation call: an incoming chain, preceded by the
/// path that builds the widget binding its callback root when there is one.
class _Path {
  _Path(this.chain, this.build, this.destination);

  final Chain chain;
  final Chain? build;
  final Evaluation destination;
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
    final (chains, truncated) = index.chainsTo(site);
    final paths = <_Path>[];
    for (final chain in chains) {
      final builds = index.buildPaths(chain);
      for (final build in builds.isEmpty ? const <Chain?>[null] : builds) {
        final full = build == null
            ? chain
            : Chain([...build.hops, ...chain.hops], chain.rootKind, chain.slot);
        paths.add(_Path(chain, build, index.destination(site, full)));
      }
    }
    sites.add(_Site(site, paths, truncated));
  }
  return sites;
}

/// Registered routes reached by [destination], by path or by route name.
List<RouteDecl> _targets(
    CodeIndex index, NavigationSite site, Evaluation destination) {
  if (site.named) {
    // An unevaluated name still matches a registration written the same way.
    final source = site.destination.toSource();
    return index.routes
        .where((r) => destination.complete
            ? r.name == destination.text
            : r.name == null && r.nameExpression?.toSource() == source)
        .toList();
  }
  final path = destination.path;
  return path == null ? const [] : index.routesFor(path);
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
    final unresolved = <String, String?>{};
    for (final path in s.paths) {
      final destination = path.destination;
      final targets = _targets(index, s.site, destination);
      reached.addAll(targets);
      if (targets.isNotEmpty) continue;
      final value = s.site.named
          ? (destination.complete ? destination.text : null)
          : destination.path;
      if (value == null) {
        unresolved[destination.text] = destination.reason ??
            (destination.complete ? 'relative_location' : null);
      } else if (s.site.named ||
          !partial.any((p) => p.length > 1 && value.startsWith(p))) {
        unknown.add(value);
      }
    }
    final at = s.site.file.at(s.site.node);
    for (final destination in unknown) {
      final uncertain = s.site.named ? anyNameUnknown : anyPathUnknown;
      findings.add({
        'check': 'unknown_destination',
        'severity': uncertain ? 'info' : 'warning',
        'at': at,
        'destination': destination,
        'expression': '${s.site.destination}',
        if (uncertain)
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
  final byPath = <String, List<RouteDecl>>{};
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
    (byPath[path] ??= []).add(route);
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
  for (final MapEntry(key: path, value: routes) in byPath.entries) {
    if (routes.length > 1) {
      findings.add({
        'check': 'duplicate_route',
        'severity': 'warning',
        'route': path,
        'at': routes.first.file.at(routes.first.node),
        'alsoAt': [for (final r in routes.skip(1)) r.file.at(r.node)],
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
    },
    'findings': [
      ...findings.where((f) => f['severity'] == 'warning'),
      ...findings.where((f) => f['severity'] != 'warning'),
    ],
    'limits': _limits,
  };
}

Map<String, Object?> query(CodeIndex index, String target) {
  final cut = target.indexOf(RegExp('[?#]'));
  final path = cut < 0 ? target : target.substring(0, cut);
  final registrations = index.routes.where((r) => r.path == path).toList();
  final names = {
    for (final r in registrations)
      if (r.name != null) r.name!,
  };
  final candidates = <Map<String, Object?>>[];
  final possible = <Map<String, Object?>>[];
  final truncated = <String>[];
  var dynamicSites = 0;
  for (final s in _sites(index)) {
    final at = s.site.file.at(s.site.node);
    if (s.truncated) truncated.add(at);
    String? prefix;
    var dynamic = false;
    for (final p in s.paths) {
      final destination = p.destination;
      final targets = _targets(index, s.site, destination);
      if (targets.any(registrations.contains)) {
        candidates.add(_candidate(index, s.site, p));
        continue;
      }
      if (targets.isNotEmpty) continue;
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
        if (!known.startsWith('/') || known.length <= 1) {
          dynamic = true;
        } else if (_prefixFits(known, path)) {
          prefix = known;
        }
      }
    }
    if (prefix != null) {
      possible.add({
        'at': at,
        'expression': '${s.site.destination}',
        'knownPrefix': prefix,
      });
    } else if (dynamic) {
      dynamicSites++;
    }
  }
  return {
    'schemaVersion': schemaVersion,
    'route': path,
    'registrations': [
      for (final r in registrations)
        {'at': r.file.at(r.node), if (r.name != null) 'name': r.name},
    ],
    if (registrations.isEmpty) 'suggestions': _suggest(index, path),
    'candidates': candidates,
    // Any of these can make the candidate list incomplete.
    if (possible.isNotEmpty) 'prefixMatches': possible,
    if (dynamicSites > 0) 'fullyDynamicSites': dynamicSites,
    if (truncated.isNotEmpty) 'truncatedSites': truncated,
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

Map<String, Object?> _candidate(
    CodeIndex index, NavigationSite site, _Path path) {
  final chain = path.chain;
  final build = path.build;
  final first = chain.hops.first;
  return {
    'root': {
      'kind': chain.rootKind,
      if (chain.slot != null) 'slot': chain.slot,
      'at': first.file.at(first.node),
      'symbol': first.owner?.symbol,
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
      'value': path.destination.text,
      if (path.destination.forwarded) 'forwarded': true,
    },
    'conditions': [
      if (build != null)
        for (final hop in build.hops) ...index.conditionsAt(hop, build: true),
      for (final (i, hop) in chain.hops.indexed)
        ...index.conditionsAt(hop, root: i == 0),
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
      _ => '$node',
    };

/// Lines outside the registration that mention the route's path expression.
List<String> _references(CodeIndex index, RouteDecl route) {
  final source = route.pathExpression?.toSource();
  if (source == null) return const [];
  final pattern = RegExp('${RegExp.escape(source)}(?![\\w\$])');
  return [
    for (final file in index.files)
      for (final match in pattern.allMatches(file.content))
        if (file != route.file ||
            match.start < route.node.offset ||
            match.start >= route.node.end)
          '${file.path}:${file.lineInfo.getLocation(match.start).lineNumber}',
  ];
}

List<Map<String, Object?>> _suggest(CodeIndex index, String path) {
  final segments = path.split('/').where((s) => s.isNotEmpty).toSet();
  return [
    for (final route in index.routes)
      if (route.path != null && route.path!.split('/').any(segments.contains))
        {'path': route.path, 'at': route.file.at(route.node)},
  ].take(10).toList();
}
