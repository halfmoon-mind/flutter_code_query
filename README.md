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
- **`routes`**: every registered route path.

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
  "route": "/users/new",
  "registrations": [{"at": "lib/router.dart:26"}],
  "candidates": [
    {
      "root": {"kind": "callback", "slot": "onTap", "at": "lib/screens.dart:44", "symbol": "Screens._tile"},
      "builtBy": {
        "kind": "framework",
        "hops": [{"at": "lib/screens.dart:32", "symbol": "Screens.build", "code": "_tile(...)"}]
      },
      "hops": [{"at": "lib/screens.dart:44", "symbol": "Screens._tile", "code": "go(...)"}],
      "destination": {"expression": "location", "value": "/users/new", "forwarded": true},
      "conditions": [
        {"at": "lib/screens.dart:32", "kind": "if", "expression": "ready", "is": true, "phase": "at_creation"}
      ]
    }
  ]
}
```

### Reading a candidate

- `root` is where the chain starts. Its `kind` is one of:
  - `callback`: a closure or tear-off bound to an `on*` slot (`slot` names it).
  - `callback_factory`: a call whose result is bound to an `on*` slot.
  - `framework`: a lifecycle method such as `build` or `initState`.
  - `ambiguous_callers`: called only through a name shared by too many
    declarations to link.
  - `no_callers`: nothing in the project references the declaration.
  - `cycle`, `depth_limit` (12 hops) or `no_owner`: the walk stopped there.
- `builtBy` is the call path that builds the widget binding a callback root,
  when that widget comes from a helper. Arguments are bound through it.
- `hops` run from the root to the navigation call. A hop with `nameMatches`
  was linked by its name alone. A hop with `deferred` only creates a closure
  or passes a tear-off (a builder, listener or returned callback).
- `conditions` are source expressions that must hold. `phase: at_creation`
  conditions decide whether the callback is bound; `on_event` conditions are
  checked when it fires.
- `prefixMatches`, `fullyDynamicSites`, `truncatedSites` and `parseErrors`
  appear only when some navigation could reach the route without being a
  candidate.

## Agent instructions

Paste this block into the app's `AGENTS.md` or `CLAUDE.md`:

```markdown
## Navigation evidence: flutter_code_query

For questions about which control opens a go_router route, under which
conditions, or whether a destination exists, answer from `flutter_code_query`
output run at the app root. Install once with
`dart pub global activate flutter_code_query`.

- `flutter_code_query routes` lists registered paths. Map a product term to one
  of them first, matching its paths and names against the app's UI strings.
- `flutter_code_query query <path>` lists incoming candidates. Report each
  candidate separately: its `root`, `builtBy`, `hops`, `destination`, and
  `conditions` with their `phase`.
- `flutter_code_query check` lists repo-wide findings, warnings first. After
  changing routes or navigation calls, resolve every `warning`; `info`
  findings are leads to inspect.

The output is static source evidence: cite its `at` locations. A candidate is
a possible chain, and conditions are unevaluated expressions; to say who can
trigger one, trace the state a condition names in source. A hop with
`deferred` or `nameMatches` is unconfirmed. When the query output contains
`prefixMatches`, `fullyDynamicSites`, `truncatedSites` or `parseErrors`, say
the candidate list can be incomplete.
```

## What it indexes

- **Registrations**: `GoRoute(...)` (also import-prefixed), project subclasses
  of `GoRoute` including `super.path` parameters, and routes built by
  functions or getters, registered where they are called. Nested relative
  paths are joined with their parent.
- **Navigation**: `go`/`push`/`pushReplacement`/`replace` and their `*Named`
  forms on a receiver ending in `context`, containing `router`, or declared as
  a `BuildContext` or `GoRouter`, and bare calls inside an extension on those
  types.
- **Chains**: from each navigation call up to an `on*` callback slot, one
  shortest chain per root. Callbacks may be tear-offs (`onTap: c.open`),
  closures in conditional, switch or `??` expressions, or callback factories.
  Members of project superclasses and mixins and `part` files resolve like the
  compiler would; other receivers are untyped (see Limits).
- **Values**: string literals and interpolation, constants and static fields,
  getters and static or top-level functions that return one expression,
  enum `.name` and constructor fields, forwarded parameters with defaults,
  `??` and null tests, and record fields of a Riverpod `Provider` default.
- **Conditions**: if/else, conditional and switch branches (including earlier
  cases that must not match), `&&`/`||`/`??` operands, loops and collection
  `for`, and early-exit guards.

Files whose header says `GENERATED ... DO NOT MODIFY`, `*.g.dart` and
`*.freezed.dart` are skipped.

## Checks

| Check | Severity | Meaning |
| --- | --- | --- |
| `unknown_destination` | warning | A resolved location or name matches no registered route. It is `info` when some route paths or names could not be evaluated. |
| `duplicate_route` | warning | The same full path is registered more than once. |
| `parse_error` | warning | A file was only partly parsed, so its routes and calls can be missing. |
| `unresolved_destination` | info | The destination could not be evaluated statically, or is relative. |
| `uncalled_navigation` | info | Every chain ends in a declaration nothing references. |
| `route_without_navigation` | info | No navigation call resolves to the route; `otherReferences` counts other mentions such as redirects or widget parameters. |
| `unresolved_route_path` | info | A route path could not be evaluated; `knownPrefix` gives its start. |

`check` always exits 0; read the `severity` of each finding.

## Limits

- Calls on an untyped receiver (`x.open()`) are linked by name, and only when
  at most 3 declarations share it; those hops carry `nameMatches`. Calls of
  lifecycle methods such as `build` or `dispose` are left to the framework.
- A `deferred` hop is not established to run.
- Conditions are source expressions, never evaluated values. Static and
  top-level variables are read from their initializers.
- Redirects, deep links, `goBranch` shell switches and fully dynamic
  destinations are not candidates.
- A navigation site keeps at most 200 chains; sites past that appear under
  `truncatedSites`.
- Symlinked files under `lib/` are skipped.
- Not supported yet: go_router_builder typed routes, Navigator 1.0,
  auto_route, and API data flow.

## Versions

The tool does not depend on Flutter, so the app's Flutter version needs no
pinning. It runs on Dart 3.5 or later with `analyzer` 7 to 12; pub picks the
newest your SDK allows, and analyzer 12 (Dart 3.9+) parses dot shorthands.
Syntax newer than that analyzer, such as Dart 3.13 primary constructors,
shows up as `parse_error` findings instead of being dropped silently.
