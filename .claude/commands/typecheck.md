# Type Checker

Run type checkers for Ruby (Sorbet) and TypeScript.

## Usage

- `/typecheck` - Run all type checkers (Sorbet and TypeScript)
- `/typecheck ruby` or `/typecheck sorbet` - Run only Sorbet
- `/typecheck ts` or `/typecheck typescript` - Run only TypeScript

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run all type checkers
   - If `ruby` or `sorbet`, run only Sorbet
   - If `ts` or `typescript`, run only TypeScript

2. Execute the appropriate commands:
   - Sorbet: `docker compose exec web bundle exec srb tc`
   - TypeScript: `docker compose exec js npm run typecheck`

3. If running multiple checkers, run them in parallel for efficiency

4. Report results from each checker, clearly indicating which checker produced which output

## Examples

```bash
# Sorbet (Ruby)
docker compose exec web bundle exec srb tc

# TypeScript
docker compose exec js npm run typecheck
```
