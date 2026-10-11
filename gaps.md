# Gaps

- **Handlers are not idempotent.** A job re-runs after a crash or stale reclaim, but its side effect (e.g. sending an email) may already have happened before the worker learns its claim was lost. The fence token only protects the `jobs` row, not the outside world, so the email is delivered twice. To close: project 08 (idempotency keys).
