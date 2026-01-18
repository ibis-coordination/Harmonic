# Async Chat Interface for Ask Harmonic

## Goal

Convert the current synchronous form-based Ask feature to an async interface with a better UX - no page reloads, loading indicator, and immediate response display.

**Constraints:**
- Complete response (not streaming)
- Stateless (no database persistence)
- Single Q&A display (one question, one answer at a time)

## Implementation Summary

### 1. Controller (app/controllers/ask_controller.rb)

Added JSON response support to `create` action using `respond_to`:
- HTML format: Renders full page (no-JS fallback)
- JSON format: Returns `{ success, question, answer }` or `{ success: false, error }`

### 2. Stimulus Controller (app/javascript/controllers/ask_chat_controller.ts)

New controller handling:
- Submit form via fetch with JSON
- Submit on Enter key (Shift+Enter for newlines)
- Show loading indicator while waiting
- Display answer (question not duplicated since it's in the input)
- Handle errors gracefully

### 3. View (app/views/ask/index.html.erb)

Structure:
- Input form with textarea and submit button
- Loading indicator (hidden by default)
- Result area for displaying the answer

Key data attributes:
- `data-controller="ask-chat"` on container
- `data-action="submit->ask-chat#submit"` on form
- `data-action="keydown->ask-chat#keydown"` on textarea
- Targets: `input`, `submitButton`, `loading`, `result`

### 4. CSS (app/assets/stylesheets/application.css)

Added styles for:
- `.ask-chat-container` - main container
- `.ask-chat-input-container` - input row layout
- `.ask-chat-loading` - loading indicator with spinner
- `.ask-chat-result` - answer display area
- `.ask-chat-message` - message styling

## Files Modified

- `app/controllers/ask_controller.rb` - JSON response support
- `app/javascript/controllers/ask_chat_controller.ts` - New Stimulus controller
- `app/javascript/controllers/index.ts` - Controller registration
- `app/views/ask/index.html.erb` - Updated view structure
- `app/assets/stylesheets/application.css` - Chat styles
- `test/controllers/ask_controller_test.rb` - Tests for JSON API

## Verification

Run tests:
```bash
docker compose exec web bundle exec rails test test/controllers/ask_controller_test.rb
docker compose exec js npm run typecheck
```

Manual testing:
1. Visit `/ask`
2. Type a question and press Enter (or click Ask)
3. Verify loading indicator appears
4. Verify answer displays without page reload
5. Test with JS disabled - form still works via full page reload
