# Architecture

The pattern is intentionally simple:

1. Claude Code runs independently from Hermes Agent.
2. A scheduled local task reads this repository's runbook and prompt.
3. It checks the Hermes host, CLI, messaging gateway, scheduled jobs, provider auth summary, logs, and host health.
4. It performs narrowly scoped safe repairs.
5. It escalates risky changes to a human operator.

This avoids relying on Hermes' own scheduled jobs to repair Hermes when the gateway or local environment itself is unhealthy.
