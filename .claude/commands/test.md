# Test Runner

Run tests for this application. Backend tests run inside Docker containers.

## Usage

- `/test` - Run all Ruby tests
- `/test path/to/test_file.rb` - Run a specific Ruby test file
- `/test path/to/test_file.rb:42` - Run a specific test by line number
- `/test path/to/test_file.rb -n test_method_name` - Run a specific test by name
- `/test --client` or `/test -c` - Run V2 React client tests
- `/test --all` - Run all tests (Ruby + V1 frontend + V2 client)

## Instructions

1. Parse the argument `$ARGUMENTS` to determine what to test:
   - If empty, run all Ruby tests: `docker compose exec web bundle exec rails test`
   - If `--client` or `-c`, run V2 client tests: `cd client && npm test`
   - If `--all`, run Ruby tests, V1 frontend tests, and V2 client tests
   - If a `.rb` file path is provided, run that Ruby test file
   - If a `.ts` or `.tsx` file path is provided, run that specific test with Vitest
   - If a file path with line number (e.g., `file.rb:42`), run that specific test
   - If `-n` flag is included, pass it through for test name matching

2. Execute the appropriate command using Bash

3. Report the results, highlighting any failures

## Examples

```bash
# All Ruby tests
docker compose exec web bundle exec rails test

# Single Ruby file
docker compose exec web bundle exec rails test test/models/note_test.rb

# Specific line
docker compose exec web bundle exec rails test test/models/note_test.rb:42

# By name
docker compose exec web bundle exec rails test test/models/note_test.rb -n test_method_name

# V2 Client tests
cd client && npm test

# V2 Client specific file
cd client && npm test -- src/components/NoteDetail.test.tsx

# V1 Frontend tests
docker compose exec js npm test
```
