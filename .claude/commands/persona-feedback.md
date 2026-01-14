# Persona Feedback

Generate feedback responses from multiple personas about the current context, code, or topic.

## Usage

- `/persona-feedback` - Get feedback from ALL personas
- `/persona-feedback [persona1, persona2, ...]` - Get feedback from specific personas (comma-separated or space-separated)

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, use ALL personas from `.claude/personas.json`
   - Otherwise, parse the comma-separated or space-separated list of persona names

2. Load the personas:
   - If using all personas:
     ```bash
     jq -r '.[]' .claude/personas.json
     ```
   - If using specific personas, find each by name (case-insensitive partial match):
     ```bash
     jq -r '.[] | select(.name | ascii_downcase | contains("SEARCH_TERM" | ascii_downcase))' .claude/personas.json
     ```
     Replace `SEARCH_TERM` with each persona name from the arguments.

3. Handle lookup errors:
   - If a specified persona is not found, note which ones weren't found and continue with the others
   - If NO personas are found (and specific ones were requested), list available personas and ask the user to try again

4. Generate feedback from each persona:
   - Consider the current conversation context, code being discussed, or topic at hand
   - For EACH persona, generate a brief feedback response (2-4 sentences) that reflects:
     - Their unique perspective based on their role and expertise
     - Their communication style
     - Their tendencies (the questions they typically ask or concerns they raise)
     - Specific, actionable insights relevant to the context

5. Format the output as follows:

---

## Persona Feedback

*[Brief description of what they're providing feedback on]*

### [Persona 1 Name] ([Role])
> [Feedback in character, reflecting their expertise and communication style]

### [Persona 2 Name] ([Role])
> [Feedback in character, reflecting their expertise and communication style]

*...continue for each persona...*

---

## Guidelines for Quality Feedback

- Each persona should offer a DISTINCT perspective - avoid redundant feedback
- Feedback should be specific to the context, not generic
- Personas should stay in character (e.g., The Minimalist gives brief feedback, The Debugger asks diagnostic questions)
- If a persona's expertise isn't relevant to the context, they should acknowledge this briefly
- Feedback should be constructive and actionable

## Examples

```bash
# Get feedback from all personas
/persona-feedback

# Get feedback from specific personas
/persona-feedback debugger, architect, tester

# Get feedback from just two personas
/persona-feedback minimalist security
```

## Example Output

---

## Persona Feedback

*Reviewing the proposed authentication flow implementation*

### The Guardian (Security Engineer)
> Have we considered rate limiting on the login endpoint? I'd also want to see the password hashing configuration - are we using bcrypt with a sufficient work factor? What happens if someone tries to enumerate valid usernames through the error messages?

### The Architect (Systems Designer)
> The separation between authentication and authorization looks clean. I'd suggest extracting the token validation into a middleware that can be reused across protected routes. Consider how this will scale if we need to support multiple auth providers later.

### The Tester (Quality Advocate)
> What's our test coverage for the failure cases? I'd want to see tests for expired tokens, malformed tokens, and concurrent session handling. Have we considered what happens at the boundary conditions - like tokens expiring mid-request?

---
