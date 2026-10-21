# Open-source validation

On 2026-10-21, `routes`, `check` and representative `query` commands were
run against these GitHub snapshots with Dart 3.9.2 and analyzer 12.1.0.
Query roots, constructor bindings and navigation calls were compared with
the source. This checks static navigation evidence; the apps were not built
or driven through their UI.

| Snapshot | Files | Routes | Navigation sites | Result |
| --- | ---: | ---: | ---: | --- |
| [Flutter navigation sample](https://github.com/flutter/samples/tree/21c71902bb2c7da3cce328ba5946cba2f35a660a/navigation_and_routing) | 17 | 10 | 12 | No parse errors or warnings; book-detail callback found. |
| [Flutter Compass](https://github.com/flutter/samples/tree/21c71902bb2c7da3cce328ba5946cba2f35a660a/compass_app/app) | 89 | 7 | 13 | No parse errors or warnings; booking callback and forwarded ID found. |
| [Hiddify](https://github.com/hiddify/hiddify-app/tree/f26aadb351fb23c222e06fcf4f5350d0ba596bb9) | 327 | 22 | 28 | No parse errors or warnings after the fixes below. |
| [Saber v1.30.0](https://github.com/saber-notes/saber/tree/0680cd1c813ad85d5961d2960d29305c8a1827ab) | 139 | 6 | 13 | Nine `/edit` candidates; four unresolved destinations and two truncated sites remain. |

The Hiddify audit exposed two omissions, reproduced in
[`test/oss_regression_test.dart`](../test/oss_regression_test.dart):

- `namedLocation('about')` and `namedLocation('logs')` have different paths
  in mobile and desktop configurations. Both paths now appear as
  alternatives instead of an unresolved destination.
- Conditional shell branches and spreads hid the last tab. They now keep
  every branch and its possible index range. `query about` increased from
  zero candidates to five, including the settings tile's constructor
  binding and tab callbacks. The unresolved-destination count fell from one
  to zero. The two remaining info findings concern the loading `/home`
  configuration and redirect-only `/intro`.

Two additional snapshots establish limits rather than successful support:

- [Saber development](https://github.com/saber-notes/saber/tree/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd)
  uses primary constructors: 115 files report parse errors. `routes` now
  exposes those errors too. In the stable snapshot, `pathToFunction` and
  mutable local values still leave home-tab destinations unresolved.
- [Spotube v5.1.2](https://github.com/KRTirtho/spotube/tree/69a310c78f5ceaf4eab7dfee98f187d38211c9ba)
  uses `auto_route`, which is unsupported. Its zero registered GoRoutes
  must not be interpreted as a successful navigation audit; its one
  router-like `push` call remains unresolved.
