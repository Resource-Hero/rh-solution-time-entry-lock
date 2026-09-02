# Resource Hero Time Entry Lock

Three record-triggered flows that stop users from logging, changing, or deleting
hours in [Resource Hero](https://resourcehero.com) once a time period has closed.
Pick a cutoff (before this week, before this month, or older than N days),
grant a bypass permission to the people who are allowed to correct history,
and everyone else gets a clear error when they try to touch a locked entry.

Built as a community pattern in response to a customer request. It is not part
of the Resource Hero managed package and is not covered by Resource Hero
support. Use it, fork it, change it.

## What it does

| Action on a time entry | Locked period | Open period |
|---|---|---|
| Log hours on a new entry | Blocked | Allowed |
| Change Actual hours or Actual Notes | Blocked | Allowed |
| Delete an entry that has hours | Blocked | Allowed |
| Change planned (Forecast) hours only | Allowed | Allowed |
| Add or delete an entry with no hours | Allowed | Allowed |
| Anything, by a user with the bypass permission | Allowed | Allowed |

"Locked period" means the entry's Forecast Date is before the cutoff.
Only standard project assignments are locked. PTO, holiday, capacity, and
snapshot rows are ignored, so Resource Hero's own automation keeps working.

Blocked users see a message like:

> Locked: the entry dated 2026-08-28 is before this week (2026-08-31). You can
> no longer change hours or notes on it. Contact your administrator if it needs
> correcting.

## What gets deployed

| Component | Purpose |
|---|---|
| `RH_Lock_Time_Entries_Create` (flow) | Blocks new entries with hours in the locked period |
| `RH_Lock_Time_Entries_Update` (flow) | Blocks changes to Actual hours or Actual Notes in the locked period |
| `RH_Lock_Time_Entries_Delete` (flow) | Blocks deleting entries with hours in the locked period |
| `Edit_Locked_Time_Entries` (custom permission) | Bypasses all three flows |
| `Time Entry Lock Bypass` (permission set) | Grants the custom permission |
| `Is_Standard_Assignment__c` (formula field on Resource Forecast) | Mirrors the assignment's Is Standard flag so flow entry criteria can filter on it |
| `RH_Lock_Time_Entries_Test` (Apex test class) | Proves the lock behaves as described in your org |

## Prerequisites

- Resource Hero installed (namespace `ResourceHeroApp`).
- Permission to deploy metadata and edit flows.

## Install

**With the Salesforce CLI** (recommended):

```bash
git clone https://github.com/Resource-Hero/rh-time-entry-lock.git
cd rh-time-entry-lock
sf project deploy start --source-dir force-app --target-org <your-org-alias>
```

**With a coding agent.** Tools like Claude Code and Agentforce Vibes, with
Salesforce skills loaded, can read this repo and help you deploy it or rebuild
the same pattern in your own org. Point the agent at the repo, tell it which
org you want it in, and review what it proposes before approving each step.

Deploy to a sandbox first. The flows are active as soon as they land.

## Configure the cutoff

The rule is set by two constants that live in each of the three flows.
Open **Setup > Flows**, edit a flow, and open the Toolbox (Manager tab).

| Constant | Values | Default |
|---|---|---|
| `LockMode` | `Week`, `Month`, or `Days` | `Week` |
| `LockDays` | Whole number; only used when `LockMode` = `Days` | `7` |

| LockMode | Locked when Forecast Date is... |
|---|---|
| `Week` | before Monday of the current week |
| `Month` | before the 1st of the current month |
| `Days` | more than `LockDays` days ago |

Change the constants in **all three** flows and save a new version of each.
If you only change one, create/update/delete will disagree with each other.

The week starts on Monday to match Resource Hero's Week Beginning field.

## Grant bypass

Assign the **Time Entry Lock Bypass** permission set to admins, PMs, or anyone
who needs to correct closed periods. Nobody has it after deployment, including
System Administrators.

## Verify in your org

Run the included test class. It creates its own users and data, exercises
every row of the table above, and cleans up after itself.

```bash
sf apex run test --class-names RH_Lock_Time_Entries_Test --result-format human --target-org <your-org-alias>
```

The test mirrors the flow constants in two lines near the top of the class.
If you change `LockMode` or `LockDays` in the flows, change them in the test
too, or the tests will fail and tell you why:

```apex
private static final String LOCK_MODE = 'Week';
private static final Integer LOCK_DAYS = 7;
```

Only the configured mode is exercised, since the test cannot change a flow
constant. Switching modes and re-running the test covers the other branches.

## Turning it off

Deactivate the three flows in Setup. Deleting them, the custom permission,
the permission set, and the formula field removes everything.

## License

MIT. See [LICENSE](LICENSE).
