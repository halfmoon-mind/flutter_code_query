## 0.1.3

- Support analyzer 13 and 14 while keeping Dart 3.5 and analyzer 7.6
  compatibility. Preserve named arguments, record fields, parameter defaults
  and callback binding across the analyzer AST changes.
- Add a runnable Dart API example for listing routes, querying incoming
  navigation candidates and checking navigation findings.

## 0.1.2

- Keep alternative paths when responsive router configurations register the
  same route name, including `namedLocation` calls passed through widgets.
- Expand shell branch spreads and collection conditions for `goBranch`,
  marking uncertain branch matches as alternatives.
- Expose parse errors and skipped links in `routes`, so partial indexes are
  visible in every command.
- Cache caller resolution per name and remove router references in batches.
- Simplify the README and separate the reference, agent instructions and
  real GitHub snapshot validation into `doc/`.

## 0.1.1

- Evaluate map entries by key (`titles[key]`) in constants, static fields and
  final locals, and `x!` on known values. A map that is not `const` can
  change, so a lookup in it stays open.
- Evaluate getters of constant objects and extension types, so route names
  and `goNamed` calls written as `RouteName.home.displayName` resolve. A
  widget's `build` reads its own getters with its fields.
- Read list and map constants through import prefixes (`p.items[1].path`).
- Read only final fields of objects and widgets. A name a field or member of
  the class declares no longer reads a top-level constant of that name, and a
  private constant is read only in its own library.

## 0.1.0

- Initial release: `check`, `query` and `routes` commands for go_router apps.
