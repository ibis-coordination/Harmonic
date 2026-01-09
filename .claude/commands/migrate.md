# Database Migrations

Run Rails database migrations inside Docker.

## Usage

- `/migrate` - Run pending migrations
- `/migrate status` - Show migration status
- `/migrate rollback` - Rollback the last migration
- `/migrate redo` - Rollback and re-run the last migration

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose exec web bundle exec rails db:migrate`
   - If `status`, run: `docker compose exec web bundle exec rails db:migrate:status`
   - If `rollback`, run: `docker compose exec web bundle exec rails db:rollback`
   - If `redo`, run: `docker compose exec web bundle exec rails db:migrate:redo`

2. Execute the command using Bash

3. Show the output and summarize what happened

## Examples

```bash
# Run migrations
docker compose exec web bundle exec rails db:migrate

# Check status
docker compose exec web bundle exec rails db:migrate:status

# Rollback
docker compose exec web bundle exec rails db:rollback

# Redo last migration
docker compose exec web bundle exec rails db:migrate:redo
```
