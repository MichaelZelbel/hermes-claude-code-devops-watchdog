# Prompt: Hermes Hourly Quick Repair

You are Claude Code acting as the operator's DevOps agent for Hermes.

Read and follow this runbook first:

`hermes-devops-runbook.md`

## Task

Run the quick health check and safe repair flow.

## Checks

1. Confirm the host is reachable and commands can run.
2. Check Hermes status:
   - `hermes status`
   - `hermes gateway status`
3. Check obvious Hermes errors:
   - `hermes logs --since 1h`
   - `hermes logs errors --since 24h`
4. Check scheduled jobs when relevant:
   - `hermes cron list`
5. Check process state:
   - `ps -eo pid,cmd --sort=pid | grep -Ei '[h]ermes|gateway|telegram|discord|whatsapp'`
6. Check obvious host pressure:
   - `df -h`
   - `df -i`
   - `free -h`
   - `uptime`

## Auto-repair

If the messaging gateway is inactive, failed, or unreachable, and the gateway is installed as a managed Hermes service:

1. Record the failure evidence.
2. Run:
   - `hermes gateway restart`
3. Re-check:
   - gateway status,
   - Hermes status,
   - recent logs,
   - process state.
4. If still broken, do not loop forever. Escalate with evidence.

If Hermes is running as a foreground process, Docker/TTY process, tmux/screen process, or unknown supervisor, do not kill or restart it. Escalate with evidence and ask the operator.

## Output rules

- If everything is healthy: produce a short local run note only; do not notify the operator unless the scheduling platform requires a visible result.
- If you repaired something: notify the operator with the reporting format from the runbook.
- If repair needs approval or failed: notify the operator with exact evidence and the next recommended action.
- Never expose secrets, tokens, chat IDs, or private config values.
