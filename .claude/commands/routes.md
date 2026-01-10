# Rails Routes

Show Rails routes for the application.

## Usage

- `/routes` - Show all routes
- `/routes <pattern>` - Filter routes by pattern (grep)

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose exec web bundle exec rails routes`
   - If a pattern is provided, pipe through grep: `docker compose exec web bundle exec rails routes | grep <pattern>`

2. Execute the command using Bash

3. Note: This app has a dual interface pattern - the same routes serve both HTML (for browsers) and Markdown (for LLMs) based on the `Accept` header.

## Examples

```bash
# All routes
docker compose exec web bundle exec rails routes

# Filter for notes routes
docker compose exec web bundle exec rails routes | grep note

# Filter for API routes
docker compose exec web bundle exec rails routes | grep api
```

## Tips

- Routes ending in common paths serve both HTML and Markdown
- Use `Accept: text/markdown` header to get LLM-friendly responses
- Key route prefixes: `/n/` (notes), `/d/` (decisions), `/c/` (commitments), `/cycles/`
