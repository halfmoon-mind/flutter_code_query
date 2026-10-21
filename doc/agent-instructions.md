# Coding agent instructions

Paste the following block into your app's `AGENTS.md` or `CLAUDE.md` to
make navigation answers use source evidence from `flutter_code_query`.
See the [quick start](../README.md#quick-start) for command examples.

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
`dynamicSites` or `truncatedSites`, say the candidate list can be
incomplete. When any command reports `parseErrors` or `skippedLinks`,
say that routes or navigation calls can be missing from the index.
```
