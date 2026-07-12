# ENGINEERING.md

## Testing

- Run relevant existing tests before and after changes when practical.
- Write tests for new behavior.
- Never delete or weaken tests to make code pass.
- If tests cannot be executed, state that explicitly.

## Documentation

- Update relevant documentation when behavior changes.
- Keep READMEs, configs, and examples aligned with implementation.
- Add comments only for non-obvious decisions or workarounds.

## Performance

- Avoid obviously inefficient algorithms or memory usage.
- Do not load large datasets/files into memory without reason.
- Flag performance-sensitive paths when encountered.

## Change Scope

- Keep PRs and commits scoped to a single concern.
- Avoid bundling unrelated modifications.
- Prefer small, reviewable diffs.