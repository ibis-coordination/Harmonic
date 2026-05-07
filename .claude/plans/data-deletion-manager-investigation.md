# DataDeletionManager Investigation

Deep investigation into pre-existing bugs surfaced during the audit chain work.

## Context
During the audit chain implementation, two bugs were discovered in `DataDeletionManager` and documented as skipped tests in `test/services/data_deletion_manager_test.rb`. These are not audit-chain-specific — they are pre-existing issues with collective and decision deletion.

## Known Issues

### 1. FK violation on events table during `delete_collective!`
Deleting a collective fails due to foreign key constraints on the events table. The events table likely references records that `delete_collective!` tries to delete before cleaning up events.

### 2. Options with wrong collective_id during `delete_decision!`
Some options end up with a collective_id that doesn't match their parent decision's collective_id. This causes `delete_decision!` to miss them when scoping by collective.

## Investigation Needed
- Reproduce both bugs and understand the root cause
- Determine if these affect production data or only test scenarios
- Check if there are other FK ordering issues in the deletion sequence
- Assess whether the fix is reordering deletions, adding missing cascade rules, or fixing how collective_id is assigned to options
- Review the full deletion order in `delete_collective!` for other potential issues
