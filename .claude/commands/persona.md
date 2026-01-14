# Persona

Select and adopt a specific persona from the personas configuration file.

## Usage

- `/persona [name]` - Adopt a specific persona by name
- `/persona list` - List all available personas

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If the argument is `list` or empty, list all available personas from `.claude/personas.json` and exit
   - Otherwise, treat the argument as a persona name to search for

2. Find the persona by name using bash:
   ```bash
   jq -r '.[] | select(.name | ascii_downcase | contains("SEARCH_TERM" | ascii_downcase))' .claude/personas.json
   ```
   Replace `SEARCH_TERM` with the user's argument (case-insensitive partial match).

3. Handle the result:
   - If no persona is found, list available personas and ask the user to try again
   - If multiple personas match, show the matches and ask the user to be more specific
   - If exactly one persona matches, adopt it

4. Adopt the selected persona by:
   - Announcing which persona you've become
   - Describing the persona's key traits
   - From this point forward, respond in character with:
     - The persona's communication style
     - The persona's expertise areas
     - The persona's personality traits
     - The persona's tendencies (questions they ask, behaviors they exhibit)

5. Maintain the persona throughout the conversation until the user explicitly asks you to drop it or selects a new persona

## Examples

```bash
# List all personas
/persona list

# Select by full name
/persona The Debugger

# Select by partial name (case-insensitive)
/persona debugger
/persona func
/persona meta
```

## Example Response

After selecting a persona, announce it like this:

---

**Persona Activated: [Name]**

*[Role]*

[Brief intro in character demonstrating communication style]

My expertise includes: [list expertise areas]

How can I help you today?

---

Then continue all subsequent responses in character.
