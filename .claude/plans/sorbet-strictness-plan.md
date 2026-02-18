# Sorbet Strictness Improvement Plan

Strengthen type checking guarantees in the Ruby codebase by progressively increasing Sorbet strictness levels and adding comprehensive type signatures.

## Current State (Baseline)

As of January 2026:

| Metric | Value |
|--------|-------|
| Files at `# typed: false` | 257 (43%) |
| Files at `# typed: true` | 341 (57%) |
| Files at `# typed: strict` | 3 (0%) |
| Methods with signatures (excl. RBIs) | 1,758 (56%) |
| Methods without signatures | 1,362 (44%) |
| Typed calls | 78% |
| Untyped calls | 22% |

Only 3 files are currently at `strict` level:
- `app/models/concerns/single_tenant_mode.rb`
- `app/services/trio_client.rb`
- `app/services/concerns/harmonic_assistant.rb`

## Goals

### Immediate
- All new code requires `# typed: true` minimum with signatures on public methods
- Eliminate `# typed: false` from core domain models
- Reduce untyped calls to < 15%

### Target State
- 80%+ of files at `# typed: strict`
- 90%+ of methods have signatures
- Runtime type checking enabled in test/development
- T.untyped eliminated except at system boundaries

## Phase 1: Foundation

### 1.1 Enforce Signatures on New Code

Add RuboCop rule to require Sorbet signatures on new public methods:

```yaml
# .rubocop.yml
Sorbet/EnforceSigil:
  Enabled: true
  SuggestedStrictness: true

Sorbet/SignaturesEnforced:
  Enabled: true
```

**Acceptance criteria:**
- [ ] RuboCop rules added and passing
- [ ] CI fails if new public methods lack signatures
- [ ] Documentation updated in CLAUDE.md

### 1.2 Upgrade Core Models to `typed: true`

Priority order (by dependency count and usage):
1. `app/models/user.rb`
2. `app/models/tenant.rb`
3. `app/models/collective.rb`
4. `app/models/note.rb`
5. `app/models/decision.rb`
6. `app/models/commitment.rb`
7. `app/models/cycle.rb`

For each file:
- [ ] Add `# typed: true` sigil
- [ ] Add `extend T::Sig` if missing
- [ ] Add signatures to all public methods
- [ ] Run `srb tc` and fix errors
- [ ] Run tests to verify behavior

### 1.3 Create Shared Type Definitions

Create `app/types/` directory for reusable types:

```ruby
# app/types/common.rb
# typed: strict

module Types
  extend T::Sig

  # Common type aliases
  ID = T.type_alias { Integer }
  TruncatedID = T.type_alias { String }
  Timestamp = T.type_alias { ActiveSupport::TimeWithZone }

  # Nullable versions
  NullableString = T.type_alias { T.nilable(String) }
  NullableID = T.type_alias { T.nilable(Integer) }
end
```

**Acceptance criteria:**
- [ ] `app/types/` directory created
- [ ] Common type aliases defined
- [ ] Domain-specific types for OODA models

## Phase 2: Strict Mode Migration

### 2.1 Upgrade Services to `typed: strict`

Services are easier to type than ActiveRecord models. Priority:
1. `app/services/api_helper.rb`
2. `app/services/decision_participant_manager.rb`
3. `app/services/commitment_participant_manager.rb`
4. `app/services/markdown_renderer.rb`
5. All other services

For each service:
- [ ] Change sigil to `# typed: strict`
- [ ] Add signatures to ALL methods (public and private)
- [ ] Replace `T.untyped` with concrete types where possible
- [ ] Document any remaining `T.untyped` with comments explaining why

### 2.2 Add T::Struct for Data Objects

Replace loose hashes with typed structs:

```ruby
# Before
def create_note(params)
  # params is Hash, could be anything
end

# After
class CreateNoteParams < T::Struct
  const :title, String
  const :text, T.nilable(String)
  const :author_id, Integer
  const :deadline, T.nilable(Date)
end

sig { params(params: CreateNoteParams).returns(Note) }
def create_note(params)
  # Type-safe access to params.title, params.text, etc.
end
```

Target areas:
- [ ] API request/response objects
- [ ] Service method parameters
- [ ] Background job arguments

### 2.3 Define Interfaces for Polymorphic Behavior

```ruby
# app/types/interfaces/publishable.rb
# typed: strict

module Publishable
  extend T::Sig
  extend T::Helpers
  interface!

  sig { abstract.returns(String) }
  def content_for_publish; end

  sig { abstract.returns(T::Array[User]) }
  def subscribers; end

  sig { abstract.returns(T::Boolean) }
  def publishable?; end
end
```

**Acceptance criteria:**
- [ ] Interfaces defined for shared behaviors
- [ ] Models implement interfaces with `include`
- [ ] Sorbet validates interface compliance

## Phase 3: Runtime Verification

### 3.1 Enable Runtime Checking in Test Environment

```ruby
# config/initializers/sorbet_runtime.rb
if Rails.env.test?
  T::Configuration.default_checked_level = :always
end

if Rails.env.development?
  T::Configuration.default_checked_level = :tests
end
```

This catches type mismatches that static analysis can't detect (e.g., from ActiveRecord dynamic methods).

### 3.2 Add Runtime Checks for Critical Paths

For high-risk code paths, add explicit runtime assertions:

```ruby
sig { params(user: User).returns(T::Boolean) }
def can_edit?(user)
  T.must(user.id) # Fails fast if user.id is nil
  # ...
end
```

**Acceptance criteria:**
- [ ] Runtime checking enabled in test/development
- [ ] No runtime type errors in test suite
- [ ] Critical paths have explicit `T.must` guards

## Phase 4: Eliminate T.untyped

### 4.1 Audit T.untyped Usage

```bash
# Find all T.untyped usages
grep -r "T.untyped" app/ lib/ --include="*.rb" | wc -l
```

Categorize each usage:
- **Removable**: Can be replaced with concrete type
- **Boundary**: External data (API responses, user input)
- **Metaprogramming**: Dynamic Ruby features

### 4.2 Replace Removable T.untyped

For each removable `T.untyped`:
1. Identify the actual type
2. Create T::Struct if needed for complex shapes
3. Update signature
4. Run type checker and tests

### 4.3 Document Remaining T.untyped

For unavoidable `T.untyped` (system boundaries):

```ruby
# External API response - shape varies by endpoint
# TODO: Create typed response structs per endpoint
sig { returns(T.untyped) }
def fetch_external_data
  # ...
end
```

## Phase 5: Advanced Patterns

### 5.1 Use T::Enum for Known Values

```ruby
# app/types/enums/note_status.rb
# typed: strict

class NoteStatus < T::Enum
  enums do
    Draft = new('draft')
    Published = new('published')
    Archived = new('archived')
  end
end
```

### 5.2 Sealed Classes for Discriminated Unions

```ruby
# app/types/result.rb
# typed: strict

class Result
  extend T::Helpers
  sealed!
  abstract!
end

class Success < Result
  extend T::Sig
  sig { returns(T.untyped) }
  attr_reader :value

  sig { params(value: T.untyped).void }
  def initialize(value)
    @value = value
  end
end

class Failure < Result
  extend T::Sig
  sig { returns(String) }
  attr_reader :error

  sig { params(error: String).void }
  def initialize(error)
    @error = error
  end
end
```

### 5.3 Generic Types for Collections

```ruby
sig { params(items: T::Array[Note]).returns(T::Array[String]) }
def extract_titles(items)
  items.map(&:title)
end
```

## Tooling and Automation

### Spoom Commands

```bash
# Check current coverage
bundle exec spoom srb coverage

# Bump files from true to strict
bundle exec spoom srb bump --from true --to strict

# Find files that could be bumped
bundle exec spoom srb bump --from true --to strict --dry

# Generate timeline of coverage changes
bundle exec spoom srb coverage --timeline
```

### CI Integration

Add to `.github/workflows/ci.yml`:

```yaml
- name: Check Sorbet coverage
  run: |
    bundle exec spoom srb coverage
    # Fail if coverage drops below threshold
    STRICT_COUNT=$(grep -r "# typed: strict" app/ lib/ --include="*.rb" | wc -l)
    if [ "$STRICT_COUNT" -lt 50 ]; then
      echo "Sorbet strict coverage too low: $STRICT_COUNT files"
      exit 1
    fi
```

### Pre-commit Hook

Already included in `scripts/hooks/pre-commit` - runs `srb tc` before commits.

## Metrics and Tracking

Track these metrics:

| Metric | Target |
|--------|--------|
| Files at `strict` | 80%+ |
| Methods with signatures | 90%+ |
| Untyped calls | < 10% |
| Runtime type errors in tests | 0 |

## Risks and Mitigations

### Risk: ActiveRecord Dynamic Methods

ActiveRecord generates methods dynamically that Sorbet can't see.

**Mitigation**: Use `tapioca` to generate RBI files:
```bash
bundle exec tapioca dsl
bundle exec tapioca gem
```

### Risk: Breaking Changes During Migration

Changing types can break existing code.

**Mitigation**:
- Make changes incrementally
- Run full test suite after each file upgrade
- Use `T.unsafe` temporarily if needed, with TODO comments

### Risk: Developer Friction

Stricter typing requires more upfront work.

**Mitigation**:
- Document patterns in CLAUDE.md and style guide
- Provide snippets/templates for common patterns
- Gradual rollout, not big bang

## Success Criteria

Phase 1 complete when:
- [ ] All core models at `typed: true`
- [ ] New code requires signatures (enforced by CI)
- [ ] Common type definitions in `app/types/`

Phase 2 complete when:
- [ ] All services at `typed: strict`
- [ ] T::Struct used for complex parameters
- [ ] Interfaces defined for shared behaviors

Phase 3 complete when:
- [ ] Runtime checking enabled in test/dev
- [ ] Zero runtime type errors in test suite

Phase 4 complete when:
- [ ] T.untyped reduced by 50%
- [ ] All remaining T.untyped documented

Phase 5 complete when:
- [ ] T::Enum used for all status fields
- [ ] Result types for fallible operations
- [ ] Generic types for collections

## References

- [Sorbet Documentation](https://sorbet.org/docs/overview)
- [Spoom CLI](https://github.com/Shopify/spoom)
- [Tapioca](https://github.com/Shopify/tapioca)
- [Sorbet at Stripe](https://stripe.com/blog/sorbet-stripes-type-checker-for-ruby)
