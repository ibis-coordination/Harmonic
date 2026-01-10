# TODO Index Check

Check the synchronization status of TODO comments with the TODO index.

## Usage

- `/todos` - Check TODO index sync status
- `/todos list` - List all TODOs in the codebase

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty or `check`, run: `./scripts/check-todo-index.sh --all`
   - If `list`, run: `./scripts/check-todo-index.sh --list`

2. Execute the command using Bash

3. Report results:
   - If in sync, confirm everything is good
   - If out of sync, list what needs to be updated in `docs/TODO_INDEX.md`

## Reference

The TODO index is maintained in `docs/TODO_INDEX.md` and should be updated whenever TODO comments are added, modified, or removed in the codebase.
