# Reference

Detailed behavior of `flutter_code_query`. For installation and basic
commands, start with the [README](../README.md).

- [Project dependency](#project-dependency)
- [Query output](#query-output)
- [Supported source patterns](#supported-source-patterns)
- [Checks](#checks)
- [Limits](#limits)
- [Version compatibility](#version-compatibility)

## Project dependency

To manage the tool through your app's dependencies, add it to `pubspec.yaml`:

```yaml
dev_dependencies:
  flutter_code_query: ^0.1.3
```

Run commands from the app root with `dart run flutter_code_query`:

```sh
dart run flutter_code_query routes
dart run flutter_code_query query /settings
dart run flutter_code_query check
```

Global activation precompiles a snapshot so command stdout carries only JSON.

## Query output

`query` accepts a path such as `/settings` or a route name such as `settings`.
Its output lists registrations and incoming navigation candidates. A
candidate is a possible chain; conditions are source expressions whose
runtime values are not established.

### Example

The following abbreviated result shows a callback created by a helper. The
`ready` condition determines whether the callback is created, and the
destination is forwarded through the helper's argument.

```json
{
  "route": "/users/new",
  "registrations": [
    {
      "at": "lib/router.dart:26"
    }
  ],
  "candidates": [
    {
      "root": {
        "kind": "callback",
        "slot": "onTap",
        "at": "lib/screens.dart:44",
        "symbol": "Screens._tile"
      },
      "builtBy": {
        "kind": "framework",
        "hops": [
          {
            "at": "lib/screens.dart:32",
            "symbol": "Screens.build",
            "code": "_tile(...)"
          }
        ]
      },
      "hops": [
        {
          "at": "lib/screens.dart:44",
          "symbol": "Screens._tile",
          "code": "go(...)"
        }
      ],
      "destination": {
        "expression": "location",
        "value": "/users/new",
        "forwarded": true
      },
      "conditions": [
        {
          "at": "lib/screens.dart:32",
          "kind": "if",
          "expression": "ready",
          "is": true,
          "phase": "at_creation"
        }
      ]
    }
  ]
}
```

### Roots

`root` is where the chain starts. For a callback, `root.at` points to the
slot binding, and `slot` names it. `within` identifies an enclosing slot,
such as the button that opens a dialog containing another button.

| `root.kind` | Meaning |
| --- | --- |
| `callback` | A closure or tear-off bound to an `on*` slot. |
| `callback_factory` | A call whose result is bound to an `on*` slot. |
| `framework` | A lifecycle method such as `build`, `initState` or `Action.invoke`. |
| `entry_point` | The app's `main` function. |
| `initializer` | A field initializer, such as a `listen(...)` subscription. |
| `ambiguous_callers` | Callers could only be linked by a name shared by too many declarations. |
| `no_callers` | Nothing in the project references the declaration. |
| `cycle`, `depth_limit`, `no_owner` | The walk stopped at a cycle, 12 hops or a call with no owning declaration. |

For `ambiguous_callers`, `no_callers`, `cycle`, `depth_limit` or `no_owner`,
the triggering control was not found.

### Widget construction and calls

`builtBy` describes the path that creates the widget binding a callback:
helper calls that return it, or widget constructor calls when their fields
change the destination. Arguments and fields are bound through this path.

`hops` run from the root to the navigation call:

- `nameMatches`: a hop linked by its name alone; it may belong to another
  declaration.
- `deferred`: a hop that only creates a closure or passes a tear-off, such
  as a builder, listener or returned callback. Whether it runs is unconfirmed.

### Destinations

`destination.value` shows unknown parts as `{expression}`. The destination
also carries these fields when relevant:

| Field | Meaning |
| --- | --- |
| `forwarded` | The value was evaluated through a bound argument or widget field. |
| `templated` | Unknown parts matched the route's shape, such as `/items/{id}` matching `/items/:id`. |
| `alternative` | One of several possible values, or a shell branch whose presence or index depends on collection conditions. |
| `branch` | The index passed to `goBranch`, or `any` when it is unknown. Used instead of `value`. |
| `routeClass` | A go_router_builder class, as in `const HomeRoute().go(context)`. Used instead of `value`. |

Alternatives include branches of `cond ? '/a' : '/b'`, elements of
`items[index].path`, and paths registered under the same name in different
router configurations. `templated` and `alternative` values are unconfirmed.

### Conditions

`conditions` lists source expressions that must hold along the chain.
Their `phase` distinguishes when a condition applies:

| `phase` | When the condition applies |
| --- | --- |
| `at_creation` | When a callback or listener is set up. |
| `on_event` | When the callback or listener fires. |
| Omitted | Whenever the root declaration runs. |

The condition selecting an alternative, such as `cond` in
`cond ? '/a' : '/b'`, is included when the choice is written in the call or
in a final local it names. Chains whose literal arguments contradict a
condition are dropped, such as `open(context, false)` leading into
`if (replace)`.

### Coverage and uncertainty

These top-level fields appear only when nonempty:

| Field | What may be missing from the candidate list |
| --- | --- |
| `prefixMatches` | Navigation calls with a known prefix that could reach the route. |
| `dynamicSites` | Navigation calls whose destination is too dynamic to associate with one route. |
| `truncatedSites` | Candidates omitted because a chain or construction-path limit was reached. |
| `skippedLinks` | Files or directories behind symbolic links, which are not followed. |
| `parseErrors` | Routes or calls in files or directories that were only partly read. |

`prefixMatches` and `dynamicSites` are leads to inspect rather than
candidates. `truncatedSites`, `skippedLinks` and `parseErrors` can indicate
missing candidates for any route.

`routes` also reports `parseErrors` and `skippedLinks` when present, so its
registration list can be recognized as incomplete. `check` includes parse
errors as findings and counts skipped links in `stats.skippedLinks`.

## Supported source patterns

### Route registrations

- `GoRoute(...)`, including import-prefixed calls and project subclasses
  with `super.path` parameters.
- Routes built in a collection `for` over a list of config objects, one
  registration per element.
- go_router_builder `@TypedGoRoute<T>` and `TypedGoRoute<T>(...)`
  declarations.
- `StatefulShellRoute` and `TypedStatefulShellRoute` branches for
  `goBranch`, including branch spreads and collection conditions.

A route that a function or getter builds from parameters, or with a relative
path, is registered where that function is called. Routes in a list variable
are registered where the variable is used, joining a shared child list with
every parent under which it appears.

### Navigation calls

Supported methods are `go`, `push`, `pushReplacement`, `replace`, their
`*Named` forms, and `goBranch`. Calls on go_router_builder route objects,
such as `const HomeRoute().go(context)`, are supported too.

A receiver is recognized when its name ends in `context` or contains
`router`, or when a parameter, local or field is declared as or initialized
from a `BuildContext` or `GoRouter`. The first parameter of a `*builder`
closure also counts. Bare and `this.` calls inside extensions on these
types are recognized.

### Call chains

The tool follows navigation calls up to `on*` callback slots, with one chain
per call site. Slots can bind tear-offs (`onTap: c.open`), closures in
conditional, switch or `??` expressions, callback factories, or callbacks
passed to parameters named `on*`.

Calls link through:

- Local functions, the enclosing class, project superclasses and mixins.
- Subclass overrides and `implements`.
- `part` files, imports and import prefixes, following library exports and
  `show` / `hide` restrictions.
- Receivers whose type is written in source (`C.m()`, `C().m()`,
  `getIt<C>().m()`) or declared on a field, parameter or local
  (`final CartFlow flow;`).

For `BuildContext`, `GoRouter` and classes outside the project, such as
`Navigator.of(context)`, calls link only to project extension members on
that type. A go_router `context.pop()` therefore does not link to an
unrelated project method named `pop`.

### Values

- **Strings and declarations:** literals, interpolation, constants and
  static fields, preferring imported declarations; getters and functions
  evaluated by their return values.
- **Enums:** `.name`, `.index`, constructor fields, and dot shorthands such
  as `.settings` when exactly one project enum has that constant.
- **Arguments and objects:** forwarded parameters with defaults, final
  widget and object fields set by constructor calls, and getters of those
  objects or extension types, such as `RouteName.home.displayName` on a
  `static const` object.
- **Collections:** list elements by index (`items[index].path`) and map
  entries by key (`titles[key]`). Known spreads are expanded. An `if` or
  `for` list element makes every element a possible value. Conditional map
  entries and entries with unknown keys are possible values; a map that is
  not `const` can change.
- **Expressions:** conditionals, switch expressions, `??`, `!` and null
  tests.
- **Helpers:** `Uri(path: ...).toString()`, `namedLocation(name)`,
  `TypedRoute().location`, and record fields of a Riverpod `Provider` default.

### Source conditions

Conditions include if/else, conditional and switch branches (including
earlier cases that must not match), `&&` / `||` / `??` operands, loops,
collection `for`, and early-exit guards including else-if chains and
`continue`.

### Generated files

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
  `stats.skippedLinks`, and `query` and `routes` report them in
  `skippedLinks`.
- Not supported yet: Navigator 1.0, auto_route, `Link` widgets, and API data
  flow.

## Version compatibility

The tool does not depend on Flutter, so the app's Flutter version needs no
pinning. It runs on Dart 3.5 or later with `analyzer` 7.6 to 14; pub picks the
newest your SDK allows. Analyzer 12 (Dart 3.9+) parses dot shorthands, and
analyzer 14.6 requires Dart 3.13 or later. Syntax newer than the selected
analyzer supports shows up as `parse_error` findings instead of being
dropped silently.
