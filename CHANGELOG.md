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
