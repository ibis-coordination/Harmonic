# Type Checker

Run type checkers for Ruby (Sorbet), TypeScript (V1 legacy), and V2 React client.

## Usage

- `/typecheck` - Run all type checkers (Sorbet, V1 TypeScript, V2 Client)
- `/typecheck ruby` or `/typecheck sorbet` - Run only Sorbet
- `/typecheck ts` or `/typecheck typescript` - Run only V1 TypeScript
- `/typecheck client` or `/typecheck v2` - Run only V2 React client TypeScript

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run all type checkers
   - If `ruby` or `sorbet`, run only Sorbet
   - If `ts` or `typescript`, run only V1 TypeScript
   - If `client` or `v2`, run only V2 client TypeScript

2. Execute the appropriate commands:
   - Sorbet: `docker compose exec web bundle exec srb tc`
   - V1 TypeScript: `docker compose exec js npm run typecheck`
   - V2 Client: `cd client && npm run typecheck`

3. If running multiple checkers, run them in parallel for efficiency

4. Report results from each checker, clearly indicating which checker produced which output

## Examples

```bash
# Sorbet (Ruby)
docker compose exec web bundle exec srb tc

# V1 TypeScript (legacy)
docker compose exec js npm run typecheck

# V2 React Client TypeScript
cd client && npm run typecheck

# Combined check (V2 client lint + typecheck)
cd client && npm run check
```
