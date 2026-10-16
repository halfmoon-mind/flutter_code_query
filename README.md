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
  the calls of a helper that returns it, or the constructor calls of a widget
  when its fields change the destination. Arguments and fields are bound
  through it.
- `hops` run from the root to the navigation call. A hop with `nameMatches`
  was linked by its name alone. A hop with `deferred` only creates a closure
  or passes a tear-off (a builder, listener or returned callback).
- `destination.value` shows unknown parts as `{expression}`. `templated`
  marks a value with unknown parts that matched the route's shape, such as
  `/items/{id}` for `/items/:id`.
  `alternative` marks one of several values the call can produce, such as a
  branch of `cond ? '/a' : '/b'` or an element of `items[index].path`. A
  `goBranch` call has `branch` instead, and a go_router_builder call such as
  `const HomeRoute().go(context)` has `routeClass`.
- `conditions` are source expressions that must hold. `at_creation`
  conditions decide whether a callback or listener is set up, and `on_event`
  ones are checked when it fires; conditions without a `phase` hold whenever
  the root declaration runs. The condition picking an `alternative`, such as
  `cond` in `cond ? '/a' : '/b'`, is listed too when the choice is written in
  the call or in a final local it names. Chains whose literal arguments
  contradict a condition, such as `open(context, false)` into `if (replace)`,
  are dropped.
- `prefixMatches` and `dynamicSites` list navigation calls that could reach
  the route without being candidates. `truncatedSites`, `skippedLinks` and
  `parseErrors` mark places where candidates for any route can be missing.
  Each appears only when it is not empty.

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
`alternative`, is unconfirmed. A root of kind `ambiguous_callers`,
`no_callers`, `cycle`, `depth_limit` or `no_owner` means the triggering
control was not found. When the query output contains `prefixMatches`,
`dynamicSites`, `truncatedSites`, `skippedLinks` or `parseErrors`, say the
candidate list can be incomplete.
```

## What it indexes

- **Registrations**: `GoRoute(...)` (also import-prefixed), project subclasses
  of `GoRoute` including `super.path` parameters, routes built in a collection
  `for` over a list of config objects (one per element), and go_router_builder
  `@TypedGoRoute<T>` / `TypedGoRoute<T>(...)` declarations. A route that a
  function or getter builds from its parameters or with a relative path is
  registered where that function is called, and a route in a list variable
  where the variable is used, so a shared child list is joined with every
  parent it is used under. The branches of a `StatefulShellRoute` or
  `TypedStatefulShellRoute` are kept for `goBranch`.
- **Navigation**: `go`/`push`/`pushReplacement`/`replace`, their `*Named`
  forms, `goBranch`, and the same calls on a go_router_builder route object
  (`const HomeRoute().go(context)`). The receiver ends in `context` or
  contains `router`, or is a parameter, local or field declared as or
  initialized from a `BuildContext` or `GoRouter`, or the first parameter of a
  `*builder` closure. Bare and `this.` calls inside an extension on those
  types count too.
- **Chains**: from each navigation call up to an `on*` callback slot, one
  chain per call site. Callbacks may be tear-offs (`onTap: c.open`), closures
  in conditional, switch or `??` expressions, callback factories, or
  callbacks passed to a parameter named `on*`. Calls resolve through local
  functions, the enclosing class, project superclasses and their mixins,
  subclass overrides and `implements`, `part` files, imports and import
  prefixes (with what the imported libraries export, through `show` and
  `hide`), and receivers whose type is written in the source (`C.m()`,
  `C().m()`, `getIt<C>().m()`) or declared on a field, parameter or local
  (`final CartFlow flow;`). On a
  `BuildContext`, a `GoRouter` or a class outside the project, such as
  `Navigator.of(context)`, a call links only to project extension members on
  that type, so go_router's own `context.pop()` never reaches a project
  method named `pop`.
- **Values**: string literals and interpolation, constants and static fields
  (preferring the imported declaration), getters and functions by their return
  values, enum `.name`, `.index` and constructor fields, dot shorthands
  (`.settings`) when one project enum has that constant, forwarded parameters
  with defaults, widget and object fields set by a constructor call, list
  elements by index (`items[index].path`; spreads of known lists are expanded,
  and an `if` or `for` element makes every element a possible value),
  conditional and switch expressions, `??` and null tests, `Uri(path:
  ...).toString()`, `namedLocation(name)`, `TypedRoute().location`, and record
  fields of a Riverpod `Provider` default.
- **Conditions**: if/else, conditional and switch branches (including earlier
  cases that must not match), `&&`/`||`/`??` operands, loops and collection
  `for`, and early-exit guards, including else-if chains and `continue`.

Files whose first lines say `GENERATED ... DO NOT MODIFY`, `*.g.dart` and
`*.freezed.dart` are skipped.

## Checks

| Check | Severity | Meaning |
| --- | --- | --- |
| `unknown_destination` | warning | A resolved location or name matches no registered route. It is `info` when a route whose path or name could not be fully evaluated might match it. |
| `duplicate_route` | warning | The same full path is registered twice in one router configuration (`GoRouter` or `RoutingConfig`). Routes outside any such call are compared with all others. |
| `parse_error` | warning | A file or directory was only partly read, so its routes and calls can be missing. |
| `unresolved_destination` | info | The destination could not be evaluated statically, or is relative. |
| `uncalled_navigation` | info | Every chain ends in a declaration nothing references. |
| `route_without_navigation` | info | No navigation call resolves to the route. `otherReferences` counts lines that mention its full path or name as a string literal, the constant its path is written with, or its go_router_builder class's constructor, such as in a redirect. |
| `unresolved_route_path` | info | A route path could not be evaluated; `knownPrefix` gives its start. |

`check` exits 0 whenever it runs, whatever it finds; read the `severity` of
each finding. A usage error or a missing `lib/` exits 2.

## Limits

- Calls on an untyped receiver (`x.open()`) are linked by name, and only when
  at most 3 declarations share it; those hops carry `nameMatches`. Calls of
  lifecycle methods such as `build` or `dispose` are left to the framework.
- A `deferred` hop is not established to run.
- Conditions are source expressions, never evaluated values. Static and
  top-level variables are read from their initializers.
- Redirects, deep links and fully dynamic destinations are not candidates.
- An `on*` argument of any constructor counts as the callback slot, including
  a config object (`MenuItem(onTap: ...)`) a widget binds later.
- go_router_builder routes are all registered, even a library's top-level
  `@TypedGoRoute` that no `GoRouter` includes.
- A navigation site keeps at most 200 chains, and a callback root at most 20
  `builtBy` paths; sites past either limit appear under `truncatedSites`.
- Symbolic links under `lib/` are not followed; `check` counts them in
  `stats.skippedLinks` and `query` in `skippedLinks`.
- Not supported yet: Navigator 1.0, auto_route, `Link` widgets, and API data
  flow.

## Versions

The tool does not depend on Flutter, so the app's Flutter version needs no
pinning. It runs on Dart 3.5 or later with `analyzer` 7.6 to 12; pub picks the
newest your SDK allows, and analyzer 12 (Dart 3.9+) parses dot shorthands.
Syntax newer than that analyzer, such as Dart 3.13 primary constructors,
shows up as `parse_error` findings instead of being dropped silently.
