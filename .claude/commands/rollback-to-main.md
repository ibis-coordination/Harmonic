# Rollback to Main

Rollback database migrations to match the main branch. This is useful when switching branches to avoid migration conflicts.

## Usage

- `/rollback-to-main` - Rollback any migrations not present on main branch

## Instructions

1. Get the list of migration files on main branch:
   ```bash
   git ls-tree --name-only origin/main db/migrate/
   ```

2. Get the current migration status:
   ```bash
   docker compose exec web bundle exec rails db:migrate:status
   ```

3. Parse both outputs to determine:
   - Which migrations are currently "up" in the database
   - Which of those migrations do NOT exist on main branch
   - These are the migrations that need to be rolled back

4. If there are no migrations to rollback, inform the user that the database is already in sync with main.

5. If there are migrations to rollback:
   - Count how many migrations need to be rolled back
   - Run: `docker compose exec web bundle exec rails db:rollback STEP=<count>`
   - Show which migrations were rolled back

6. Verify the rollback succeeded by checking `db:migrate:status` again.

## Notes

- Migration files are named with timestamps (e.g., `20260114130000_add_delegation_support.rb`)
- The timestamp is the migration version number (first 14 digits)
- Migrations must be rolled back in reverse order (newest first)
- This command only rolls back; it does not delete migration files
