# Refactoring Skill

Guidelines for refactoring code in this Rails application.

## TDD

When refactoring, write or update tests **before** modifying implementation code. This "red-green-refactor" approach ensures you have a safety net: run the tests first to confirm they pass (or fail as expected), make your changes, then run tests again to verify behavior is preserved. If tests fail after refactoring, you know exactly what broke. Never refactor code that lacks test coverage—add tests first.

## Static Types

Sorbet provides compile-time guarantees that catch type mismatches before runtime. When refactoring, run `srb tc` frequently to catch method signature changes, renamed methods, or incorrect return types. Type annotations serve as machine-checked documentation—if you change a method's contract, Sorbet will flag every caller that needs updating. This is especially valuable when renaming or restructuring code across multiple files.

## FP-style over Imperative

Prefer pure functions that take inputs and return outputs without side effects. Separate **logic** (calculations, transformations, decisions) from **effects** (database writes, API calls, file I/O). Pure logic can be tested with simple unit tests—no mocking, no setup, no teardown. Push effects to the boundaries of your code: gather data, run pure logic, then apply effects. This makes code easier to test, reason about, and refactor safely.

## Code Style Requirements

### Ruby (Backend)
- **Linter**: Run RuboCop after refactoring to catch style issues

### TypeScript/React (V2 Client)
- **Linter**: Run ESLint after refactoring: `cd client && npm run lint`
- **Functional programming**: Strictly enforced - no classes, no `let`, no loops, no `throw`
- **Error handling**: Use tagged unions with factory functions, not classes
- **Effects**: Use Effect.js `Effect.gen` with `Effect.fail` instead of throwing

## Multi-Tenancy Awareness

This app uses subdomain-based multi-tenancy. When refactoring:

- **Never remove** `default_scope` tenant filtering from models
- `Tenant.current_id` and `Studio.current_id` are set via thread-local variables
- Models use `default_scope { where(tenant_id: Tenant.current_id, studio_id: Studio.current_id) }` pattern in `ApplicationRecord`
- New records auto-populate `tenant_id` and `studio_id` via `before_validation`

- Test helpers like `create_tenant_studio_user` handle tenant setup automatically

## Model Concerns

Prefer using existing shared concerns over duplicating logic:

| Concern | Purpose | Include when... |
|---------|---------|-----------------|
| `HasTruncatedId` | Short 8-char IDs for URLs | Model needs URL-friendly IDs |
| `Linkable` | Bidirectional linking | Model can be linked to other content |
| `Pinnable` | Pin to studio | Content can be featured |
| `Attachable` | File attachments | Model supports uploads |
| `Commentable` | Comments (as Notes) | Model can be commented on |

## Service Objects

Follow the `ApiHelper` pattern in `app/services/api_helper.rb`:

- Business logic belongs in service objects, not controllers
- Controllers should be thin, delegating to services
- Services handle CRUD operations and complex business rules

## Controller Patterns

### Dual Interface Support

Controllers serve both HTML (browser) and Markdown (LLM) interfaces:

```ruby
respond_to do |format|
  format.html { render :show }
  format.text { render_markdown }
end
```

When refactoring controllers, preserve both response formats.

### Standard Actions

Follow Rails conventions for RESTful actions:
- `index`, `show`, `new`, `create`, `edit`, `update`, `destroy`
- Use `before_action` for shared setup like `set_note`

## Testing After Refactoring

Always verify refactored code:

1. Run related tests: `docker compose exec web bundle exec rails test test/path/to/test.rb`
2. Run RuboCop: `docker compose exec web bundle exec rubocop path/to/file.rb`
3. Run Sorbet if types changed: `docker compose exec web bundle exec srb tc`

## Common Refactoring Patterns

### Extract Method

When a method is too long, extract logical chunks:

```ruby
# Before
def process
  # 50 lines of code
end

# After
def process
  validate_input
  perform_calculation
  save_results
end
```

### Replace Conditional with Polymorphism

Use STI (Single Table Inheritance) or duck typing instead of case statements:

```ruby
# Before
case item.type
when "note" then handle_note(item)
when "decision" then handle_decision(item)
end

# After
item.handle  # Each subclass implements #handle
```

### Move to Concern

If multiple models share behavior, extract to a concern in `app/models/concerns/`:

```ruby
module MySharedBehavior
  extend ActiveSupport::Concern

  included do
    # callbacks, validations, scopes
  end

  def shared_method
    # implementation
  end
end
```

### Simplify Queries

Use Active Record query methods and scopes:

```ruby
# Before
Note.all.select { |n| n.created_at > 1.week.ago }

# After
Note.where("created_at > ?", 1.week.ago)
# Or define a scope
scope :recent, -> { where("created_at > ?", 1.week.ago) }
```

## Things to Avoid

- **Don't break tenant isolation** - Always maintain the default_scope pattern
- **Don't over-abstract** - Only extract when there's clear duplication
- **Don't change public APIs** - Preserve controller action signatures
- **Don't skip tests** - Refactoring without tests is risky
- **Don't add unnecessary gems** - Prefer Ruby/Rails stdlib solutions

## V2 React Client Refactoring

When refactoring TypeScript/React code in `client/`:

### Functional Programming Enforcement

ESLint strictly enforces functional programming. Common refactoring patterns:

```typescript
// BEFORE: Class-based error
class NetworkError extends Error {
  constructor(message: string) {
    super(message)
  }
}

// AFTER: Tagged union with factory function
interface NetworkError {
  readonly _tag: "NetworkError"
  readonly message: string
}
const NetworkError = (params: Omit<NetworkError, "_tag">): NetworkError => ({
  _tag: "NetworkError",
  ...params,
})
```

```typescript
// BEFORE: Throwing errors
if (!response.ok) {
  throw new Error("Request failed")
}

// AFTER: Effect.js error handling
if (!response.ok) {
  return yield* Effect.fail(ApiError({ status: response.status, message: "Failed" }))
}
```

```typescript
// BEFORE: let and mutation
let total = 0
for (const item of items) {
  total += item.price
}

// AFTER: Functional reduce
const total = items.reduce((sum, item) => sum + item.price, 0)
```

### Testing After V2 Client Refactoring

1. Run ESLint: `cd client && npm run lint`
2. Run TypeScript: `cd client && npm run typecheck`
3. Run tests: `cd client && npm test`
4. Or all at once: `cd client && npm run check`

## Checklist Before Completing Refactoring

### Ruby (Backend)
- [ ] Code follows style guide (double quotes, trailing commas)
- [ ] RuboCop passes with no new offenses
- [ ] All existing tests still pass
- [ ] New code has appropriate test coverage
- [ ] Multi-tenancy is preserved
- [ ] Both HTML and Markdown responses work (if touching controllers)

### TypeScript/React (V2 Client)
- [ ] ESLint passes with no errors: `cd client && npm run lint`
- [ ] TypeScript compiles: `cd client && npm run typecheck`
- [ ] All tests pass: `cd client && npm test`
- [ ] No classes, `let`, loops, or `throw` statements
- [ ] Errors use tagged unions with factory functions
