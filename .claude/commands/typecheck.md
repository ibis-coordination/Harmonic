# Type Checker

Run type checkers for both Ruby (Sorbet) and TypeScript.

## Usage

- `/typecheck` - Run both Sorbet and TypeScript type checkers
- `/typecheck ruby` or `/typecheck sorbet` - Run only Sorbet
- `/typecheck ts` or `/typecheck typescript` - Run only TypeScript

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run both type checkers
   - If `ruby` or `sorbet`, run only Sorbet
   - If `ts` or `typescript`, run only TypeScript

2. Execute the appropriate commands:
   - Sorbet: `docker compose exec web bundle exec srb tc`
   - TypeScript: `docker compose exec js npm run typecheck`

3. If running both, run them in parallel for efficiency

4. Report results from each checker, clearly indicating which checker produced which output

## Examples

```bash
# Sorbet (Ruby)
docker compose exec web bundle exec srb tc

# TypeScript
docker compose exec js npm run typecheck
```
