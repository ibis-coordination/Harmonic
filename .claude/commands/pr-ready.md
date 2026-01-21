# PR Ready Check

Run all checks to ensure the code is ready for a pull request.

## Usage

- `/pr-ready` - Run all pre-PR checks

## Instructions

Run all of the following checks and report results:

### Backend (Ruby)

1. **RuboCop** (Ruby linting):
   ```bash
   docker compose exec web bundle exec rubocop
   ```

2. **Sorbet** (Ruby type checking):
   ```bash
   docker compose exec web bundle exec srb tc
   ```

3. **Ruby Tests**:
   ```bash
   docker compose exec web bundle exec rails test
   ```

### Frontend - V1 (Legacy TypeScript)

4. **TypeScript** (V1 TypeScript type checking):
   ```bash
   docker compose exec js npm run typecheck
   ```

5. **Frontend Tests** (V1):
   ```bash
   docker compose exec js npm test
   ```

### Frontend - V2 (React Client)

6. **ESLint** (V2 client linting - includes functional programming rules):
   ```bash
   cd client && npm run lint
   ```

7. **TypeScript** (V2 client type checking):
   ```bash
   cd client && npm run typecheck
   ```

8. **V2 Client Tests**:
   ```bash
   cd client && npm test
   ```

Run the linting and type checking commands in parallel since they're independent.
Run tests after linting passes.

## Summary

After running all checks, provide a summary:
- ✅ or ❌ for each check
- Total number of test failures (if any)
- Any RuboCop offenses that need attention
- Any ESLint errors (especially functional programming violations)
- Any type errors that need fixing

## CI Thresholds

For reference, CI enforces:
- Line coverage: 45%
- Branch coverage: 25%

Consider running `/coverage` if you want to check coverage before submitting.
