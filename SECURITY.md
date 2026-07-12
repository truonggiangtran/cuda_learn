# SECURITY.md

## Security Rules

- Never hardcode secrets, credentials, or tokens.
- Do not log sensitive information unnecessarily.
- Do not disable or weaken security controls.
- Preserve authentication, authorization, validation, and encryption behavior unless explicitly requested.

## Dependency Security

- Prefer existing vetted dependencies.
- Treat new dependencies as security and maintenance risks.
- Justify any new dependency introduction.

## Failure Handling

- Fail explicitly on security-sensitive paths.
- Do not silently ignore validation or authorization failures.
- Surface risky patterns or potential vulnerabilities encountered during work.

## Verification

- Do not assume security properties without evidence.
- Verify behavior against repository code, configs, or documentation.