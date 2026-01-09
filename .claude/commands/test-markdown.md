# Test Markdown API

Test the Markdown API responses for a given route.

## Usage

- `/test-markdown <path>` - Fetch a route with Accept: text/markdown header

## Instructions

1. This app serves two interfaces from the same routes:
   - HTML for browsers
   - Markdown for LLMs (when `Accept: text/markdown` header is sent)

2. Parse `$ARGUMENTS` to get the path to test

3. Make a request with the markdown accept header:
   ```bash
   curl -H "Accept: text/markdown" http://localhost:3000<path>
   ```

4. Display the markdown response

5. Note any available actions listed in the response (these are the API actions LLMs can take)

## Examples

```bash
# Test notes list
curl -H "Accept: text/markdown" http://localhost:3000/n

# Test a specific note (use truncated ID)
curl -H "Accept: text/markdown" http://localhost:3000/n/a1b2c3d4

# Test decisions
curl -H "Accept: text/markdown" http://localhost:3000/d

# Test cycles
curl -H "Accept: text/markdown" http://localhost:3000/cycles/today
```

## Tips

- Truncated IDs are 8-character short IDs used in URLs
- The markdown response includes available actions that can be performed via API
- This is the interface AI agents use to interact with the app
