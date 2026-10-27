# Spec Guard

A Claude Code plugin for spec-driven work: the specification is the oracle, tests have to be able
to fail, review hunts for what breaks in production, commits stay atomic, and the project's own
tests run as gates without being asked.

Nothing here is tied to a language or framework. The one project-specific thing — which tests to
run and when — lives in your repository, not in the plugin.

## Install

```bash
claude plugin marketplace add IrinaSchetckina/spec-guard
claude plugin install spec-guard@schetckina-plugins
```

Requires Claude Code 2.1.271 or later. The gate scripts need `bash`, `jq` and `git` on `PATH`;
without `jq` they exit quietly instead of failing.

## What you get

| Component | Kind | What it does |
| --- | --- | --- |
| `spec-guard:plan-verifier` | agent | Verifies one function or feature **against the specification**, not against its tests. Derives the oracle from the spec first, then checks whether each test encodes a rule, what rules and edge cases have no test, and whether the implementation holds for inputs the tests never reach. Read-only. |
| `spec-guard:reviewer` | agent | Reviews one axis only (security, correctness, contract, concurrency, layering, tests). Run several in parallel, one per axis, for a hub-and-spoke review. Read-only. |
| `spec-guard:review` | skill | The review method: axis order, what counts as a finding, the finding format, and what not to review. |
| `spec-guard:write-tests` | skill | Test-writing principles: designing testability into production code, what branches you must cover per component kind, and the two traps that eat the most time. |
| `/spec-guard:commit` | command | One atomic commit in Conventional Commits form, with the staged diff re-read after every change to the index. |
| Test gates | hooks | `PostToolUse` runs the gate for the area you just edited; `Stop` runs the project's gates once before a turn ends, as a backstop for edits made through Bash. |

The two agents are independent verifiers: they read, reason and report, and never edit or run
anything. The skills carry method only — your project's stack specifics stay in your project's
own docs, and both the review skill and the reviewer agent are told to read them when they exist.

## Test gates

The gates are off until the project defines them. Create `.claude/gates.json` in your repository:

```json
{
  "gates": [
    {
      "name": "billing domain",
      "on": ["edit", "stop"],
      "paths": ["src/domain/billing/*.ts"],
      "command": "npm test -- src/domain/billing"
    },
    {
      "name": "full suite",
      "on": ["stop"],
      "paths": ["src/**"],
      "command": "npm test"
    }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | no | Shown when the gate fails. Defaults to `tests`. |
| `on` | no | `edit`, `stop`, or both. Defaults to both. |
| `paths` | for `edit` | Shell globs against project-relative paths. `*` crosses `/`, so `src/*/domain/*.ts` matches at any depth. Brace alternatives are **not** expanded — list them as separate entries. |
| `command` | yes | Run from the project root through `bash -c`. |
| `errorPattern` | no | Extended regex used to summarise the failure. Defaults to a pattern that catches failed tests, assertion messages and compiler errors. |

How it behaves:

- **On edit** — only gates whose `paths` match the edited file run. A failure exits 2, so the
  summary goes back to Claude as feedback rather than to you.
- **On stop** — every `stop` gate runs, once. If the commit is unchanged since the last green run
  and no watched file is newer, nothing runs: conversation turns cost nothing.
- **Loop guard** — the stop gate blocks at most once per turn. If the tests still fail after
  Claude's fix attempt, the second failure reaches you as a message instead of blocking again.
- **Silent by default** — no `.claude/gates.json`, no gates. Installing this plugin never runs a
  build command you did not configure.

To point the gates at a different file, or silence them on one machine, set `SPEC_GUARD_GATES`
in the `env` block of your `settings.json` — `"off"` disables them outright:

```json
{ "env": { "SPEC_GUARD_GATES": "off" } }
```

The plugin deliberately declares no `userConfig` options. Claude Code does not run a plugin's
hooks until every declared option has a stored value, so an option here would make a fresh
install silently do nothing even with `.claude/gates.json` in place. Plugin options are also
stored per user rather than per repository — `pluginConfigs` is read from `~/.claude/settings.json`
only — which is the other reason the gate definitions belong in the repository, where they are
committed, reviewed and shared with everyone who clones.

## Using the agents

Give `plan-verifier` the spec section, the function, the test file and the implementation file:

> Verify `applyDiscount`. Oracle: `docs/specs/billing.md` §4.2. Tests:
> `src/domain/billing/discount.test.ts`. Implementation: `src/domain/billing/discount.ts`.
> Out of scope: the tiered pricing model in §6.

For a hub-and-spoke review, launch one `reviewer` per axis in a single message so they run in
parallel, then verify each finding against the code before acting on it.

## Note on language

The agent, skill and command bodies are written in Ukrainian; the manifests and this README are
in English. The content is instructions for Claude, which reads either — but if you would rather
have it all in English, open an issue.

## License

MIT
