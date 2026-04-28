# Permission Model

Recommended rollout:

1. Start with `templates/claude-settings.conservative.example.json`.
2. Run checks manually and inspect output.
3. Allow `hermes gateway restart` only after you trust the flow and have confirmed the gateway is installed as a managed service.
4. Consider `templates/claude-settings.autonomous-devops.example.json` only after testing.
5. Keep destructive and security-sensitive operations behind approval.

The templates are examples. Claude Code's permission syntax may change; verify against current Claude Code docs before installing.
