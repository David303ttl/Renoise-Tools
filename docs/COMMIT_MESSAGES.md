# Commit message convention

Use [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
for new commits. Its format is:

```text
<type>[optional scope][!]: <description>

[optional body]

[optional footer(s)]
```

Examples for this repository:

```text
feat(acid): add phrase gate editor
fix(arp): preserve destination notes during regeneration
docs(repo): document Renoise API setup
refactor(acid): group phrase writers by responsibility
test(arp): cover fractional gate boundaries
chore(repo): ignore local environment files
```

Use a lowercase imperative description without a trailing period, for example
`add phrase gate editor`. Keep the first line concise; aim for 72 characters or
fewer. Add a body when the reason or impact is not clear from the title.

Use scopes such as `acid`, `arp`, `digitakt`, `tests`, `repo`, or `build` when
they help identify the affected area. Omit the scope for a change spanning the
repository. Conventional Commits permits other clear types and scopes; the list
above is the usual vocabulary, not a closed registry.

Mark a breaking change with `!` and describe it in the body or with a footer:

```text
feat(acid)!: change phrase state format

BREAKING CHANGE: existing saved phrase state must be migrated.
```

Use `revert:` for a revert and reference the commit being reverted in the body.
Commit types do not automatically bump Renoise tool versions; versions remain
independent in each tool's `manifest.xml`.

This convention is documented guidance. The repository does not install commit
hooks or run a commit-message workflow.
