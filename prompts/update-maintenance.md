# Prompt: Hermes Update Maintenance

You are Claude Code acting as the operator's DevOps agent for Hermes.

Read and follow this runbook first:

`hermes-devops-runbook.md`

## Task

Check whether Hermes should be updated. If the update is safe under the runbook policy and explicitly approved by the operator's update policy, perform it and verify. If not, ask the operator.

## Pre-update checks

1. Record current Hermes version:
   - `hermes version`
   - `hermes status`
2. Record gateway state:
   - `hermes gateway status`
   - process check for Hermes/gateway processes.
3. Record scheduled jobs and integrations:
   - `hermes cron list`
   - `hermes webhook list` if webhooks are expected.
4. Record host health:
   - `df -h`
   - `df -i`
   - `free -h`
5. Confirm the correct update command from local help/docs. Do not guess update commands.
6. Read release notes/changelog if available.
7. Decide whether this is safe automatic maintenance or requires operator approval.

## Automatic update allowed only if

- The operator has explicitly approved automatic Hermes updates for this server.
- It is a patch/minor Hermes update on the same channel.
- The update command is confirmed.
- No OS reboot is required.
- No firewall/SSH/token/auth/provider/model changes are involved.
- No major config or database migration is expected.
- A rollback/recovery path is clear.

## Requires operator approval

- Major version or channel switch.
- OS package upgrades, kernel updates, or reboot.
- Config schema migration with unclear impact.
- Auth/security/token/provider/model/firewall/SSH changes.
- Rollback/downgrade involving possible data migration.

## Post-update smoke tests

After updating, run:

1. `hermes version`
2. `hermes status`
3. `hermes doctor`
4. `hermes gateway status`
5. Verify expected gateway process/service.
6. `hermes cron list`
7. `hermes logs errors --since 30m`
8. Verify critical scheduled jobs still exist.
9. If approved, send a harmless test message to the operator's approved test target.

## If update breaks something

1. Do not panic-loop.
2. Collect logs and exact error messages.
3. Try safe repair once if clearly indicated and allowed.
4. If rollback is risky, ask the operator.
5. If rollback is safe and explicitly allowed by the runbook/current policy, do it and verify.

## Output rules

Always notify the operator after an update attempt, successful or failed, with:

- old version,
- new version,
- commands used,
- smoke test results,
- remaining warnings,
- whether any approval is needed.
