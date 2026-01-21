# RuboCop Linter

Run linters to check code style and optionally auto-fix issues.

## Usage

- `/lint` - Run RuboCop on Ruby code
- `/lint --fix` or `/lint -a` - Auto-fix Ruby issues
- `/lint path/to/file.rb` - Lint a specific Ruby file
- `/lint --client` or `/lint -c` - Run ESLint on V2 React client
- `/lint --all` - Run both RuboCop and ESLint

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose exec web bundle exec rubocop`
   - If `--fix` or `-a`, run: `docker compose exec web bundle exec rubocop -a`
   - If `--client` or `-c`, run: `cd client && npm run lint`
   - If `--client --fix`, run: `cd client && npm run lint:fix`
   - If `--all`, run both RuboCop and ESLint
   - If a file path ending in `.rb`, run rubocop on that specific file
   - If a file path ending in `.ts` or `.tsx`, run eslint on that specific file
   - Combine flags as needed (e.g., `--fix path/to/file.rb`)

2. Execute the command(s) using Bash

3. Summarize the results:
   - For RuboCop: Number of files inspected, offenses found, auto-corrected
   - For ESLint: Number of errors and warnings

## Examples

```bash
# Ruby: Full lint
docker compose exec web bundle exec rubocop

# Ruby: Auto-fix
docker compose exec web bundle exec rubocop -a

# Ruby: Specific file
docker compose exec web bundle exec rubocop app/models/note.rb

# Ruby: Auto-fix specific file
docker compose exec web bundle exec rubocop -a app/models/note.rb

# V2 Client: Full lint
cd client && npm run lint

# V2 Client: Auto-fix
cd client && npm run lint:fix

# V2 Client: Specific file
cd client && npx eslint src/components/NoteDetail.tsx
```

## V2 Client ESLint Rules

The V2 React client uses strict functional programming rules:
- No classes (`functional/no-classes`)
- No `let` declarations (`functional/no-let`)
- No loops (`functional/no-loop-statements`)
- No `throw` statements (`functional/no-throw-statements`)
- Immutable data (`functional/immutable-data`)

Configuration: `client/eslint.config.js`
