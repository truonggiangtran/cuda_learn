# AGENTS.md

These rules apply unless explicitly overridden. If overriding, state which rule is being overridden and why.

---

# Rule Priority

When rules conflict, prioritize:

1. Correctness
2. Safety
3. Minimal blast radius
4. Consistency with existing patterns
5. Simplicity

---

# 1. Think Before Coding

- State assumptions explicitly.
- If uncertain, ask rather than guess — limit to 1–3 targeted questions.
- If a reasonable default exists, state the assumption and proceed.
- Surface ambiguity when multiple interpretations exist.
- Push back on unnecessary complexity.

# 2. Simplicity First

- Implement minimum solution that satisfies requirements.
- No speculative abstractions.
- No features beyond request.
- Prefer straightforward code over cleverness.

# 3. Surgical Changes

- Touch only code required for task.
- Do not refactor unrelated areas.
- Match existing codebase patterns and style.
- Before modifying code:
  - Read nearby logic.
  - Inspect callers/callees.
  - Inspect shared utilities/interfaces.
- Do not assume code is isolated.

# 4. Goal-Driven Execution

- Define success criteria before implementation.
- Verify outcome, not just completion of steps.
- Iterate until criteria are satisfied or blocker identified.
- Never claim work is done when it isn't.

# 5. Conformance Over Preference

- Follow repository conventions even if personally disagreeing.
- Do not introduce new architectural or stylistic patterns silently.
- If conventions conflict:
  - Choose intentionally.
  - Explain reasoning.
  - Avoid hybrid approaches.

# 6. Fail Loud

- Never silently skip work, tests, or validations.
- Surface uncertainty, blockers, and incomplete work clearly.
- If something could not be verified, state it explicitly.

# 7. Evidence Over Assumption

- Do not invent: APIs, Files, Configs, Functions, Behaviors, etc.
- Ground architectural claims in repository evidence or documentation.

# 8. Dependency Discipline

- Prefer stdlib or existing project dependencies.
- Do not introduce new dependencies without justification.
- Avoid dependency sprawl for trivial problems.