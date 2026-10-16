import 'package:analyzer/dart/ast/ast.dart';

import 'index.dart';

const schemaVersion = 1;

const _limits = [
  'Parse-only: calls are linked by name and library privacy, not by type. '
      'A hop with nameMatches > 1 may belong to another declaration.',
  'A hop with inClosure only creates a closure; whether it runs is not established.',
  'Conditions are source expressions, never evaluated values.',
  'Redirects, deep links and dynamic destinations are not navigation candidates.',
];

/// One navigation site with its incoming chains and per-chain destinations.
class _Site {
  _Site(this.site, this.chains, this.truncated, this.destinations);

  final NavigationSite site;
  final List<Chain> chains;
  final bool truncated;
  final List<Evaluation> destinations;
}

List<_Site> _sites(CodeIndex index) => [
      for (final site in index.navigations)
        if (index.chainsTo(site) case (final chains, final truncated))
          _Site(site, chains, truncated,
              [for (final chain in chains) index.destination(site, chain)]),
    ];

/// Registered routes reached by [destination], by path or by route name.
List<RouteDecl> _targets(
    CodeIndex index, NavigationSite site, Evaluation destination) {
  if (site.named) {
    return destination.complete
        ? index.routes.where((r) => r.name == destination.text).toList()
        : const [];
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
  for (final s in sites) {
    final unknown = <String>{};
    final unresolved = <String, String?>{};
    for (final destination in s.destinations) {
      final targets = _targets(index, s.site, destination);
      reached.addAll(targets);
      if (targets.isNotEmpty) continue;
      if (s.site.named ? destination.complete : destination.path != null) {
        unknown.add(s.site.named ? destination.text : destination.path!);
      } else {
        unresolved[destination.text] = destination.reason;
      }
    }
    final at = s.site.file.at(s.site.node);
    for (final destination in unknown) {
      findings.add({
        'check': 'unknown_destination',
        'severity': 'warning',
        'at': at,
        'destination': destination,
        'expression': '${s.site.destination}',
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
    if (s.chains.isNotEmpty &&
        s.chains.every((c) => c.rootKind == 'no_callers')) {
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
        'at': [for (final r in routes) r.file.at(r.node)],
      });
    }
  }
  for (final error in index.parseErrors) {
    findings.add({'check': 'parse_error', 'severity': 'warning', 'at': error});
  }
  return {
    'schemaVersion': schemaVersion,
    'stats': {
      'files': index.files.length,
      'routes': index.routes.length,
      'navigationSites': sites.length,
      'chains': sites.fold<int>(0, (n, s) => n + s.chains.length),
      'truncatedSites': sites.where((s) => s.truncated).length,
      'parseErrors': index.parseErrors.length,
    },
    'findings': findings,
    'limits': _limits,
  };
}

Map<String, Object?> query(CodeIndex index, String target) {
  final cut = target.indexOf(RegExp('[?#]'));
  final path = cut < 0 ? target : target.substring(0, cut);
  final registrations = index.routes.where((r) => r.path == path).toList();
  final candidates = <Map<String, Object?>>[];
  final possible = <Map<String, Object?>>[];
  var dynamicSites = 0;
  final truncated = <String>[];
  for (final s in _sites(index)) {
    if (s.truncated) truncated.add(s.site.file.at(s.site.node));
    var unresolved = '';
    var counted = false;
    for (final (i, chain) in s.chains.indexed) {
      final destination = s.destinations[i];
      final targets = _targets(index, s.site, destination);
      if (targets.any(registrations.contains)) {
        candidates.add(_candidate(index, s.site, chain, destination));
      } else if (targets.isEmpty && destination.path == null && !s.site.named) {
        if (destination.text.length > 1 && path.startsWith(destination.text)) {
          unresolved = destination.text;
        } else if (destination.text.isEmpty && !counted) {
          counted = true;
          dynamicSites++;
        }
      }
    }
    if (unresolved.isNotEmpty) {
      possible.add({
        'at': s.site.file.at(s.site.node),
        'expression': '${s.site.destination}',
        'knownPrefix': unresolved,
      });
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
    if (possible.isNotEmpty) 'prefixMatches': possible,
    'fullyDynamicSites': dynamicSites,
    // Chains past the per-site limit are dropped, so candidates may be missing.
    if (truncated.isNotEmpty) 'truncatedSites': truncated,
    // Partly parsed files can hide candidates.
    if (index.parseErrors.isNotEmpty) 'parseErrors': index.parseErrors,
    'limits': _limits,
  };
}

Map<String, Object?> _candidate(
    CodeIndex index, NavigationSite site, Chain chain, Evaluation destination) {
  final first = chain.hops.first;
  return {
    'root': {
      'kind': chain.rootKind,
      if (chain.slot != null) 'slot': chain.slot,
      'at': first.file.at(first.node),
      'symbol': first.owner?.symbol,
    },
    'hops': [
      for (final hop in chain.hops)
        {
          'at': hop.file.at(hop.node),
          'symbol': hop.owner?.symbol,
          'code': _code(hop.node),
          if (hop.matches > 1) 'nameMatches': hop.matches,
          if (index.inClosure(hop)) 'inClosure': true,
        },
    ],
    'destination': {
      'expression': '${site.destination}',
      'value': destination.text,
      if (destination.forwarded) 'forwarded': true,
    },
    'conditions': [
      for (final (i, hop) in chain.hops.indexed)
        ...index.conditionsAt(hop, root: i == 0),
    ],
  };
}

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
