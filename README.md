# flutter_code_query

Find which controls can reach a [go_router](https://pub.dev/packages/go_router)
route and check for navigation mistakes in Flutter apps.

The tool parses your app's `lib/` without resolving types or running the app.
Results are JSON with source locations, for coding agents and scripts.

## Install

Requires Dart 3.5 or later. The tool does not need the Flutter SDK.

```sh
dart pub global activate flutter_code_query
```

Make sure `~/.pub-cache/bin` is on your `PATH`. You can also install it as a
[project dev dependency](doc/reference.md#project-dependency).

## Quick start

Run from your Flutter app's root directory:

```sh
# List registered paths and route names
flutter_code_query routes

# Find controls and call chains that can reach a route
flutter_code_query query /settings

# Check for unknown destinations, duplicate routes and other findings
flutter_code_query check
```

`query` accepts a path or a route name. For a route named `settings`, use
`flutter_code_query query settings`.

To analyze another app, pass its root directory:

```sh
flutter_code_query query /settings --root=../my_app
```

## Read a query result

A query lists the route's registrations and incoming `candidates`. Each
candidate describes one possible chain from a control to a navigation call.

| Field | What it tells you |
| --- | --- |
| `root` | Where the chain starts, such as a button's `onTap` callback. |
| `builtBy` | The helper or widget constructor calls that create the callback's widget, when relevant. |
| `hops` | Calls from the root to the navigation call. |
| `destination` | The resolved path, route name, shell branch or typed route class. |
| `conditions` | Source conditions around creation of the callback and execution of the chain. |

Use `at` locations to inspect the source. Conditions are unevaluated
expressions; a candidate represents a possible chain. Fields such as
`nameMatches`, `deferred`, `templated` and `alternative` mark uncertainty.

Dynamic destinations, parse errors and truncation can leave results
incomplete. See the [JSON example and field reference](doc/reference.md#query-output)
for details on interpreting each field and coverage indicator.

## Read check findings

`check` reports findings with a `severity`, with warnings first:

- **`warning`**: inspect unknown destinations, duplicate routes and parse errors.
- **`info`**: investigate unresolved values or routes with no detected navigation.

`check` exits **0 even when it finds warnings**. Scripts should inspect the
JSON findings. Invalid usage or a missing `lib/` directory exits **2**.
See [all checks](doc/reference.md#checks) for their exact meanings.

## Scope

Supports `GoRoute`, go_router_builder typed routes and stateful shell
branches. It follows project call chains, forwarded arguments, widget fields
and source conditions. See [supported source patterns](doc/reference.md#supported-source-patterns)
for the full coverage.

Navigator 1.0, `auto_route`, `Link` widgets and API data flow are unsupported.
Redirects and deep links are outside the incoming candidate chains. Read the
[limits](doc/reference.md#limits) before treating the output as complete.

## Documentation

- [Reference](doc/reference.md): JSON output, supported patterns, checks,
  limits and version compatibility.
- [Coding agent instructions](doc/agent-instructions.md): a block to copy
  into your app's `AGENTS.md` or `CLAUDE.md`.
- [Open-source validation](doc/validation.md): tested GitHub snapshots,
  fixes and remaining gaps.
