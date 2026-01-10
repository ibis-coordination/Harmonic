# RuboCop Linter

Run RuboCop to check Ruby code style and optionally auto-fix issues.

## Usage

- `/lint` - Run RuboCop on the entire codebase
- `/lint --fix` or `/lint -a` - Auto-fix issues
- `/lint path/to/file.rb` - Lint a specific file

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose exec web bundle exec rubocop`
   - If `--fix` or `-a`, run: `docker compose exec web bundle exec rubocop -a`
   - If a file path, run rubocop on that specific file
   - Combine flags as needed (e.g., `--fix path/to/file.rb`)

2. Execute the command using Bash

3. Summarize the results:
   - Number of files inspected
   - Number of offenses found
   - Number of offenses auto-corrected (if applicable)

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
