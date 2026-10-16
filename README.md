# flutter_code_query

Static navigation queries and checks for Flutter apps that use
[go_router](https://pub.dev/packages/go_router). It parses your app's `lib/`
without resolving types, so a run takes about a second where full analyzer
resolution takes 30 seconds or more. Output is JSON, made for coding agents
and scripts.

- **`query <route>`**: which controls lead to a route, through which calls,
  and under which source conditions. Takes a path (`/settings`) or a route
  name (`settings`).
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

- `root` is where the chain starts; `root.at` is the slot binding for a
  callback. Its `kind` is one of:
  - `callback`: a closure or tear-off bound to an `on*` slot (`slot` names it).
    `within` names an enclosing slot, as for a button in a dialog another
    button opens.
  - `callback_factory`: a call whose result is bound to an `on*` slot.
  - `framework`: a lifecycle method such as `build`, `initState` or
    `Action.invoke`. `entry_point`: `main`. `initializer`: a field
    initializer, such as a `listen(...)` subscription.
  - `ambiguous_callers`: called only through a name shared by too many
    declarations to link.
  - `no_callers`: nothing in the project references the declaration.
  - `cycle`, `depth_limit` (12 hops) or `no_owner`: the walk stopped there.
- `builtBy` is the call path that builds the widget binding a callback root:
  the calls of a helper that returns it, or, when the destination needs it,
  the constructor calls of a widget whose field holds the location. Arguments
  and fields are bound through it.
- `hops` run from the root to the navigation call. A hop with `nameMatches`
  was linked by its name alone. A hop with `deferred` only creates a closure
  or passes a tear-off (a builder, listener or returned callback).
- `destination.value` shows unknown parts as `{expression}`. `templated`
  marks a value with unknown parts that matched a `:param` route.
  `alternative` marks one of several values the call can produce, such as a
  branch of `cond ? '/a' : '/b'`. A `goBranch` call has `branch` instead.
- `conditions` are source expressions that must hold. In a callback chain,
  `at_creation` conditions decide whether the callback is bound and `on_event`
  ones are checked when it fires. Chains whose literal arguments contradict a
  condition, such as `open(context, false)` into `if (replace)`, are dropped.
- `prefixMatches`, `dynamicSites`, `truncatedSites` and `parseErrors` appear
  only when some navigation could reach the route without being a candidate.

## Agent instructions

Paste this block into the app's `AGENTS.md` or `CLAUDE.md`:

```markdown
## Navigation evidence: flutter_code_query

For questions about which control opens a go_router route, under which
conditions, or whether a destination exists, answer from `flutter_code_query`
output run at the app root. Install once with
`dart pub global activate flutter_code_query`.

- `flutter_code_query routes` lists registered paths and names. Map a product
  term to one of them first, matching against the app's UI strings.
- `flutter_code_query query <path-or-name>` lists incoming candidates. Report
  each candidate separately: its `root`, `builtBy`, `hops`, `destination`, and
  `conditions` with their `phase`.
- `flutter_code_query check` lists repo-wide findings, warnings first. After
  changing routes or navigation calls, resolve every `warning`; `info`
  findings are leads to inspect.

The output is static source evidence: cite its `at` locations. A candidate is
a possible chain, and conditions are unevaluated expressions; to say who can
trigger one, trace the state a condition names in source. A hop with
`deferred` or `nameMatches`, and a destination marked `templated` or
`alternative`, is unconfirmed. When the query output contains
`prefixMatches`, `dynamicSites`, `truncatedSites` or `parseErrors`, say the
candidate list can be incomplete.
```

## What it indexes

- **Registrations**: `GoRoute(...)` (also import-prefixed), project subclasses
  of `GoRoute` including `super.path` parameters, and routes built by
  functions or getters, registered where they are called. Nested relative
  paths are joined with every parent they are used under. The branches of a
  `StatefulShellRoute` are kept for `goBranch`.
- **Navigation**: `go`/`push`/`pushReplacement`/`replace`, their `*Named`
  forms, and `goBranch`. The receiver ends in `context` or contains `router`,
  or is a parameter, local or field declared as or initialized from a
  `BuildContext` or `GoRouter`, or the first parameter of a `*builder`
  closure. Bare calls inside an extension on those types count too.
- **Chains**: from each navigation call up to an `on*` callback slot, one
  chain per call site. Callbacks may be tear-offs (`onTap: c.open`), closures
  in conditional, switch or `??` expressions, callback factories, or
  callbacks passed to a parameter named `on*`. Calls resolve through local
  functions, the enclosing class, project superclasses, mixins and subclass
  overrides, `part` files, and receivers whose type is written in the source
  (`C.m()`, `C().m()`, `getIt<C>().m()`). go_router's own methods and classes
  outside the project, such as `Navigator`, are never linked to project
  declarations.
- **Values**: string literals and interpolation, constants and static fields
  (preferring the imported declaration), getters and functions by their
  return values, enum `.name` and constructor fields, forwarded parameters with
  defaults, widget fields set by a constructor call, conditional and switch
  expressions, `??` and null tests, `Uri(path: ...).toString()`,
  `namedLocation(name)`, and record fields of a Riverpod `Provider` default.
- **Conditions**: if/else, conditional and switch branches (including earlier
  cases that must not match), `&&`/`||`/`??` operands, loops and collection
  `for`, and early-exit guards, including else-if chains and `continue`.

Files whose header says `GENERATED ... DO NOT MODIFY`, `*.g.dart` and
`*.freezed.dart` are skipped.

## Checks

| Check | Severity | Meaning |
| --- | --- | --- |
| `unknown_destination` | warning | A resolved location or name matches no registered route. It is `info` when some route paths or names could not be evaluated. |
| `duplicate_route` | warning | The same full path is registered twice in one router configuration (`GoRouter` or `RoutingConfig`). |
| `parse_error` | warning | A file or directory was only partly read, so its routes and calls can be missing. |
| `unresolved_destination` | info | The destination could not be evaluated statically, or is relative. |
| `uncalled_navigation` | info | Every chain ends in a declaration nothing references. |
| `route_without_navigation` | info | No navigation call resolves to the route. `otherReferences` counts mentions of its full path or name as a string literal, or of the constant its path is written with. |
| `unresolved_route_path` | info | A route path could not be evaluated; `knownPrefix` gives its start. |

`check` always exits 0; read the `severity` of each finding.

## Limits

- Calls on an untyped receiver (`x.open()`) are linked by name, and only when
  at most 3 declarations share it; those hops carry `nameMatches`. Calls of
  lifecycle methods such as `build` or `dispose` are left to the framework.
- A `deferred` hop is not established to run.
- Conditions are source expressions, never evaluated values. Static and
  top-level variables are read from their initializers.
- Redirects, deep links and fully dynamic destinations are not candidates.
- A navigation site keeps at most 200 chains; sites past that appear under
  `truncatedSites`.
- Symbolic links under `lib/` are not followed; `check` counts them in
  `stats.skippedLinks`.
- Not supported yet: go_router_builder typed routes, Navigator 1.0,
  auto_route, `Link` widgets, and API data flow.

## Versions

The tool does not depend on Flutter, so the app's Flutter version needs no
pinning. It runs on Dart 3.5 or later with `analyzer` 7 to 12; pub picks the
newest your SDK allows, and analyzer 12 (Dart 3.9+) parses dot shorthands.
Syntax newer than that analyzer, such as Dart 3.13 primary constructors,
shows up as `parse_error` findings instead of being dropped silently.
