---
title: Persistent infrastructure and writer ownership
status: accepted
last-reviewed: 2026-11-19
---

# Persistent infrastructure and writer ownership

This boundary governs future Workspace provider designs. The project owner
accepted the boundary in the infrastructure design interview on 2026-11-19.
The [base design plan](../plans/2026-11-19-0740-workspace-base-design-plan.md)
still requires approval.

## Separate lifetimes

| Value | Responsibility |
| --- | --- |
| Infrastructure reference | The host keeps a durable provider and resource ID. It can reconnect to the same machine, with the files and installed dependencies that the provider preserves. The host can also request a fresh machine when the provider supports it. |
| Workspace session | Workspace grants access to one managed tree on that resource. Close releases the session. The infrastructure lifecycle has separate operations for stop, retain, and destroy. |
| Snapshot reference | An explicit save of the managed tree. The host can use it for recovery, handoff, or restoring files onto a fresh resource. It has its own retention policy. |

Preserve persistent infrastructure when the Workspace session closes or the
BEAM stops. The developer controls the disposition of the machine and of
commands that can still be running. The host selects the provider and owns
credentials, placement, and fleet policy.

## Recovery and write access

Give the developer hooks to **inspect, wait for, or stop** prior commands.
Make those hooks available while write access is blocked. The provider
reports what it can establish. An unreachable machine or uncertain command
state stays unknown. A wait timeout leaves the command available for further
inspection.

Before granting a new writer, establish both conditions:

1. The previous session can no longer start work that writes to the tree.
2. Its existing commands and their descendants can no longer write to the tree.

Verify both at the provider boundary. A local process exit or elapsed lease
timer alone supplies insufficient evidence. Keep writes and saves blocked
when the provider cannot establish quiescence. Accept a provider stop response
as confirmation only when the provider confirms that the writers have stopped.

## Developer controls

Use durable resource and command identities or equivalent provider lookup.
The recovery design must cover a lost reply after allocation or command
start. Expose provider-specific diagnostics when the common hooks lack
detail. Diagnostic access conveys no authority to grant a writer.

An external editor, SSH shell, or provider console that can change the tree
also counts as a writer. Any such writer must be accounted for before Workspace
can claim exclusive control. An explicit maintenance handoff is a candidate
for how to do this. Its API, provider recovery callbacks, and first remote
provider remain open design questions.

## Review cases

- If the BEAM stops during a write, a new BEAM can recover the resource
  identity and inspect the old command. The developer can wait or request a
  stop. Write access stays blocked until the provider confirms both conditions.
- If the old BEAM comes back after a network partition, its old session cannot
  start a new writer once a replacement has gained write access.
- If a provider cannot confirm the status of the old writers, diagnostics
  remain useful and the tree stays unavailable for writes and saves.
