# RuboCop Linter

Run RuboCop linter to check Ruby code style and optionally auto-fix issues.

## Usage

- `/lint` - Run RuboCop on Ruby code
- `/lint --fix` or `/lint -a` - Auto-fix Ruby issues
- `/lint path/to/file.rb` - Lint a specific Ruby file

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose exec web bundle exec rubocop`
   - If `--fix` or `-a`, run: `docker compose exec web bundle exec rubocop -a`
   - If a file path ending in `.rb`, run rubocop on that specific file
   - Combine flags as needed (e.g., `--fix path/to/file.rb`)

2. Execute the command(s) using Bash

3. Summarize the results:
   - Number of files inspected, offenses found, auto-corrected

## Examples

```bash
# Full lint
docker compose exec web bundle exec rubocop

# Auto-fix
docker compose exec web bundle exec rubocop -a

# Specific file
docker compose exec web bundle exec rubocop app/models/note.rb

# Auto-fix specific file
docker compose exec web bundle exec rubocop -a app/models/note.rb
```
