---
name: primary-resource-handover
description: >-
  Agent-only playbook for main-session resource protection wakes from
  bin/fm-primary-resource.sh. Load on a check wake naming primary-resource
  context or quota handover, or an alert-only primary-resource line.
  On a handover wake: run /stow, write the structured reset-safe attestation,
  call commit, end the turn. On alert-only wakes: tell the captain in plain
  outcome language.
user-invocable: false
metadata:
  internal: true
---

# primary-resource-handover

Handle a main-session resource-protection wake from `bin/fm-primary-resource.sh`.
The script owns thresholds, incident identity, receipts, and the helper lifecycle.
This skill owns only the primary agent's stow-and-commit turn, and captain-facing alert wording.
Only Claude and Codex have context adapters, verified at parser level against recorded transcript shapes; [`docs/verification/runtime-backends.md`](../../../docs/verification/runtime-backends.md) "Primary-resource handover" owns the verification grades, and every other adapter is alert-only.
Antigravity (agy) is a quota-handover destination only; source sessions stay alert-only until primary binding and idle signals are verified.
Its transcripts carry no token usage, and stale or unknown destination quota excludes it from selection.
The commit gate registers the successor home through `bin/fm-agy-trust.sh` before reserving the handover; a registration failure keeps the source session.

## Handover wake (`primary-resource context <id>` or `primary-resource quota <id>`)

1. Load and run the existing `/stow` skill completely, including its cascade and reset-safe contract.
2. Write exactly this structured attestation file (regular file, never a symlink), with the wake's incident id and the current binding generation (`binding.json` `sessionId`):

```
FM_PRIMARY_RESOURCE_STOW_V1
verdict=reset-safe
incidentId=<incident-id>
generation=<binding.sessionId>
```

Do not use prose substitutes.
`not reset-safe`, `reset-safe: no`, and any other negative or unbound wording will be rejected.
3. Only when that attestation is written, run:
   `bin/fm-primary-resource.sh commit <incident-id> --stow-receipt <path>`
4. End the turn after commit returns.
   Do not kill this session from a tool call; the bounded helper exits the old adapter and launches the successor.
5. If stow reports an exception, the attestation cannot be made reset-safe, or commit refuses, keep the session, tell the captain the durable state was preserved or not, and do not retry the same incident.

## Alert-only wake (`primary-resource alert: ...`)

Tell the captain in plain outcome language per `AGENTS.md` section 9.
Translate the condition into the session consequence (context reading unavailable, quota high with no independent replacement, unsupported backend, stranded handover, failed handover) and that the current session was kept.
Do not expose internal paths, thresholds as mechanism jargon, or receipt filenames unless the captain needs them to act.
