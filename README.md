# flutter_code_query

Static navigation queries and checks for Flutter apps that use
[go_router](https://pub.dev/packages/go_router). It parses your app's `lib/`
without resolving types, so a run takes about a second where full analyzer
resolution takes 30 seconds or more. Output is JSON, made for coding agents
and scripts.

- **`query <route>`**: which controls lead to a route, through which calls,
  and under which source conditions.
- **`check`**: repo-wide findings such as navigation to unregistered paths or
  duplicate routes.
- **`routes`**: every registered `GoRoute` path.

## Install

```sh
dart pub global activate flutter_code_query
```

`~/.pub-cache/bin` must be on `PATH`. Activation precompiles a snapshot, so
stdout carries only JSON.

To pin one version for a whole team, add it as a dev dependency instead and run
it with `dart run flutter_code_query`:

```yaml
dev_dependencies:
  flutter_code_query: ^0.1.0
```

## Usage

Run from the app root, or pass `--root=<app>`. The tool reads `<root>/lib`.

```sh
flutter_code_query routes
flutter_code_query query /settings
flutter_code_query check
```

`query` output, abbreviated:

```json
{
  "route": "/detail",
  "registrations": [{"at": "lib/router.dart:16"}],
  "candidates": [
    {
      "root": {"kind": "callback", "slot": "onPressed", "at": "lib/home_screen.dart:18", "symbol": "HomeScreen.build"},
      "hops": [
        {"at": "lib/home_screen.dart:18", "symbol": "HomeScreen.build", "code": "_openDetail(...)"},
        {"at": "lib/home_screen.dart:39", "symbol": "HomeScreen._openDetail", "code": "navigateTo(...)"},
        {"at": "lib/navigation.dart:8", "symbol": "navigateTo", "code": "push(...)"}
      ],
      "destination": {"expression": "'$location?id=$id'", "value": "/detail?id=a", "forwarded": true},
      "conditions": [
        {"at": "lib/home_screen.dart:16", "kind": "if", "expression": "canEdit", "is": true, "phase": "at_creation"},
        {"at": "lib/navigation.dart:7", "kind": "guard", "expression": "id.isEmpty", "is": false}
      ]
    }
  ],
  "fullyDynamicSites": 2
}
```

Read a candidate from `root` (the callback slot that starts it) through `hops`
to the navigation call. `phase: at_creation` conditions decide whether the
callback is bound; `on_event` conditions are checked when it fires.

## Agent instructions

Paste this block into the app's `AGENTS.md` or `CLAUDE.md`:

```markdown
## Navigation evidence: flutter_code_query

For questions about which control opens a go_router route, under which
conditions, or whether a destination exists, answer from `flutter_code_query`
output run at the app root. Install once with
`dart pub global activate flutter_code_query`.

- `flutter_code_query routes` lists registered paths. Map a product term to one
  of them before querying.
- `flutter_code_query query <path>` lists incoming candidates. Report each
  candidate separately: its `root`, `hops`, `destination`, and `conditions`
  with their `phase`.
- `flutter_code_query check` lists repo-wide findings. Run it after changing
  routes or navigation calls and resolve every `warning`.

The output is static source evidence: cite its `at` locations. A candidate is
a possible chain, and conditions are unevaluated expressions. A hop with
`inClosure` or `nameMatches` is unconfirmed. When `prefixMatches`,
`fullyDynamicSites`, `truncatedSites` or `parseErrors` appear, say the
candidate list can be incomplete.
```

## What it indexes

- `GoRoute(path:, name:)` registrations, joining nested relative paths. Paths
  may be literals, constants, or single-argument wrappers such as
  `RouteInfo('/home')`.
- `go`/`push`/`pushReplacement`/`replace` and their `*Named` forms on a
  receiver ending in `context` or containing `router`.
- Incoming chains from each navigation call up to an `on*` callback slot,
  including tear-offs (`onTap: controller.open`), closures inside conditional
  or switch expressions, and callback factories (`onTap: _onTapFor(x)`).
- Destinations through string interpolation, `final` locals, forwarded
  parameters, and record fields of a Riverpod `Provider` default value.
- Source conditions on each hop: if/else, conditional and switch branches,
  `&&`/`||` operands, loops and early-exit guards.

Files whose header says `GENERATED ... DO NOT MODIFY`, `*.g.dart` and
`*.freezed.dart` are skipped.

## Checks

| Check | Severity | Meaning |
| --- | --- | --- |
| `unknown_destination` | warning | A resolved location matches no registered route. |
| `duplicate_route` | warning | The same full path is registered more than once. |
| `parse_error` | warning | A file was only partly parsed, so its routes and calls can be missing. |
| `unresolved_destination` | info | The destination could not be evaluated statically. |
| `uncalled_navigation` | info | Every chain ends in a declaration nothing references. |
| `route_without_navigation` | info | No navigation call resolves to the route; `otherReferences` counts other mentions such as redirects or widget parameters. |
| `unresolved_route_path` | info | A `GoRoute` path could not be evaluated. |

## Limits

- Calls are linked by name, scope and library privacy, not by type. A hop with
  `nameMatches > 1` may belong to another declaration with the same name.
- A hop with `inClosure` only creates a closure (a builder, listener or
  returned callback); whether the closure runs is not established.
- Conditions are source expressions, never evaluated values.
- Redirects, deep links and fully dynamic destinations are not candidates.
  `query` lists dynamic destinations with a matching known prefix under
  `prefixMatches` and counts the rest in `fullyDynamicSites`.
- A navigation site keeps at most 200 incoming chains; sites past that appear
  under `truncatedSites`.
- Not supported yet: go_router_builder typed routes, Navigator 1.0,
  auto_route, import-prefixed `GoRoute`, and API data flow.

## Versions

The tool does not depend on Flutter, so the app's Flutter version needs no
pinning. It runs on Dart 3.5 or later and parses with the newest language
version its `analyzer` 7.x knows. If the app adopts newer syntax, the affected
files appear as `parse_error` findings instead of being dropped silently.
