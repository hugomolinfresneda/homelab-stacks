# homelab-stacks

Public-to-runtime contract: `docs/contract.md`.
Runtime overrides: `docs/runtime-overrides.md`.
Stack-specific details are documented in stack READMEs under `stacks/` when present.

## Demo mode (without runtime)
What works without runtime:
- Documentation review and static inspection of `compose.yaml`.
- Reviewing env templates like `.env.example`.

What does not work without runtime:
- Secrets, real credentials, or host mounts.
- Starting services or persisting data.
