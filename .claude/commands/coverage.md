# Test Coverage

Run tests with coverage reporting enabled.

## Usage

- `/coverage` - Run all tests with coverage report

## Instructions

1. Run tests with coverage enabled:
   ```bash
   docker compose exec web env COVERAGE=true bundle exec rails test
   ```

2. Report the coverage results

3. Note the CI thresholds for reference:
   - Line coverage threshold: 45%
   - Branch coverage threshold: 25%

4. Highlight if coverage is below thresholds
