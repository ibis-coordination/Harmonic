# Test Runner

Run tests for this Rails application. All tests run inside Docker containers.

## Usage

- `/test` - Run all tests
- `/test path/to/test_file.rb` - Run a specific test file
- `/test path/to/test_file.rb:42` - Run a specific test by line number
- `/test path/to/test_file.rb -n test_method_name` - Run a specific test by name

## Instructions

1. Parse the argument `$ARGUMENTS` to determine what to test:
   - If empty, run all tests: `docker compose exec web bundle exec rails test`
   - If a file path is provided, run that file
   - If a file path with line number (e.g., `file.rb:42`), run that specific test
   - If `-n` flag is included, pass it through for test name matching

2. Execute the appropriate command using Bash

3. Report the results, highlighting any failures

## Examples

```bash
# All tests
docker compose exec web bundle exec rails test

# Single file
docker compose exec web bundle exec rails test test/models/note_test.rb

# Specific line
docker compose exec web bundle exec rails test test/models/note_test.rb:42

# By name
docker compose exec web bundle exec rails test test/models/note_test.rb -n test_method_name
```
