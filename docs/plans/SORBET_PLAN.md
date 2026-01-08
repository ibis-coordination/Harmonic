# Sorbet Type Checking Plan

This document outlines the plan to integrate [Sorbet](https://sorbet.org/) for gradual type checking in the Harmonic codebase. Sorbet is a fast, powerful type checker for Ruby developed by Stripe that enables incremental adoption.

## Table of Contents

1. [Overview & Goals](#overview--goals)
2. [Phase 1: Initial Setup](#phase-1-initial-setup)
3. [Phase 2: Generate RBI Files](#phase-2-generate-rbi-files)
4. [Phase 3: Establish Baseline Strictness](#phase-3-establish-baseline-strictness)
5. [Phase 4: Type Core Models](#phase-4-type-core-models)
6. [Phase 5: Type Services](#phase-5-type-services)
7. [Phase 6: Type Controllers](#phase-6-type-controllers)
8. [Phase 7: CI Integration](#phase-7-ci-integration)
9. [Sorbet Patterns for Rails](#sorbet-patterns-for-rails)
10. [Known Challenges & Solutions](#known-challenges--solutions)

---

## Overview & Goals

### Why Sorbet?

1. **Catch bugs early**: Type errors are caught at development time, not runtime
2. **Better IDE support**: Enables better autocomplete and refactoring
3. **Documentation**: Types serve as executable documentation
4. **Gradual adoption**: Can be added incrementally without blocking development
5. **Fast feedback**: Sorbet is extremely fast, providing instant feedback

### Goals

- [ ] Add Sorbet to the project with minimal disruption
- [ ] Generate RBI files for gems and Rails magic
- [ ] Achieve `typed: true` on all service objects
- [ ] Achieve `typed: true` on core domain models
- [ ] Integrate type checking into CI pipeline
- [ ] Document patterns for team adoption

### Non-Goals (for initial rollout)

- Achieving `typed: strict` across entire codebase immediately
- Typing view helpers or complex metaprogramming
- Blocking deploys on type errors (initially warnings only)

---

## Phase 1: Initial Setup

### Objective
Install Sorbet and its dependencies, initialize the project for type checking.

### Tasks

#### 1.1 Add Sorbet Gems

Add to `Gemfile`:

```ruby
group :development do
  # Sorbet type checking
  gem 'sorbet', require: false
  gem 'sorbet-runtime'

  # Tapioca for RBI generation (Rails-aware)
  gem 'tapioca', require: false
end

# Runtime type checking (needed in all environments)
gem 'sorbet-runtime'
```

**Note**: `sorbet-runtime` must be available in all environments (not just development) because typed method signatures use runtime assertions.

#### 1.2 Install Dependencies

```bash
bundle install
```

#### 1.3 Initialize Tapioca

Tapioca is the recommended tool for generating RBI files for Rails projects (replaces the older `srb rbi` commands):

```bash
bundle exec tapioca init
```

This creates:
- `sorbet/config` - Sorbet configuration file
- `sorbet/tapioca/` - Tapioca configuration directory

#### 1.4 Configure Sorbet

Create/update `sorbet/config`:

```
--dir
.
--ignore=/vendor/
--ignore=/tmp/
--ignore=/log/
--ignore=/storage/
--ignore=/coverage/
--ignore=/node_modules/
```

### Verification

```bash
bundle exec srb tc
```

Should run without crashing (will likely have many errors initially).

---

## Phase 2: Generate RBI Files

### Objective
Generate type definitions for gems, Rails DSLs, and dynamic Ruby patterns.

### Tasks

#### 2.1 Generate Gem RBIs

```bash
bundle exec tapioca gems
```

This generates `sorbet/rbi/gems/` with type definitions for all bundled gems.

#### 2.2 Generate DSL RBIs for Rails

```bash
bundle exec tapioca dsl
```

This generates `sorbet/rbi/dsl/` with type definitions for:
- ActiveRecord models (columns, associations, scopes)
- ActiveJob jobs
- Rails routes
- And more Rails magic

#### 2.3 Generate Shims for Missing Definitions

```bash
bundle exec tapioca annotations
```

Downloads community-maintained type annotations from [ruby-community/rbi-central](https://github.com/Shopify/rbi-central).

#### 2.4 Create Custom Shims

Create `sorbet/rbi/shims/` directory for manual type definitions:

```ruby
# sorbet/rbi/shims/current.rbi
# typed: true

class Current
  class << self
    sig { returns(T.nilable(Tenant)) }
    def tenant; end

    sig { params(tenant: T.nilable(Tenant)).void }
    def tenant=(tenant); end

    sig { returns(T.nilable(User)) }
    def user; end

    sig { params(user: T.nilable(User)).void }
    def user=(user); end
  end
end
```

### Commit Checklist

- [ ] `sorbet/rbi/gems/` - Generated gem RBIs
- [ ] `sorbet/rbi/dsl/` - Generated Rails DSL RBIs
- [ ] `sorbet/rbi/shims/` - Custom shims
- [ ] `sorbet/config` - Sorbet configuration
- [ ] Add `sorbet/rbi/gems/` to `.gitignore` (regenerated, optional)

---

## Phase 3: Establish Baseline Strictness

### Objective
Add `typed:` sigils to all Ruby files and establish a baseline.

### Tasks

#### 3.1 Add Sigils to All Files

```bash
bundle exec srb tc --typed-override all:false
bundle exec spoom srb bump --from false --to true
```

Or manually/via script, add to top of each `.rb` file:

```ruby
# typed: false
```

This tells Sorbet to parse but not check the file.

#### 3.2 Install Spoom (Optional but Recommended)

Spoom provides helpful commands for managing Sorbet adoption:

```ruby
# Gemfile
group :development do
  gem 'spoom', require: false
end
```

Useful commands:
```bash
# See coverage metrics
bundle exec spoom coverage

# Bump strictness levels
bundle exec spoom bump

# Generate coverage report
bundle exec spoom coverage report
```

#### 3.3 Strictness Level Strategy

| Level | Meaning | Target Files |
|-------|---------|--------------|
| `ignore` | Sorbet ignores this file | Generated files, complex metaprogramming |
| `false` | Parse only, no checking | Initial default for all files |
| `true` | Type check, infer types | Services, simple models, lib/ |
| `strict` | All methods must have sigs | New code, critical paths |
| `strong` | No `T.untyped` allowed | Rarely used |

**Recommended progression:**
1. Start everything at `typed: false`
2. Move services to `typed: true`
3. Move models to `typed: true`
4. New files start at `typed: true` or `typed: strict`

---

## Phase 4: Type Core Models

### Objective
Add type signatures to core domain models.

### Priority Order

Based on the codebase, type these models in order:

1. **User** - Core identity model
2. **Tenant** - Multi-tenancy foundation
3. **Studio** - Workspace model
4. **Note** - Primary content model
5. **Decision** & **Option** - Voting system
6. **Commitment** & **CommitmentParticipant** - Pledges
7. **Cycle** - Time-based organization

### Example: Typing a Model

```ruby
# typed: true
# app/models/note.rb

class Note < ApplicationRecord
  extend T::Sig

  # Sorbet signatures for custom methods
  sig { returns(T::Boolean) }
  def published?
    status == 'published'
  end

  sig { params(user: User).returns(T::Boolean) }
  def editable_by?(user)
    author_id == user.id || user.admin?
  end

  sig { returns(String) }
  def display_title
    title.presence || "Untitled"
  end
end
```

### Tasks

#### 4.1 Add Signatures to Model Methods

For each model:
1. Change sigil from `# typed: false` to `# typed: true`
2. Add `extend T::Sig` after class declaration
3. Add `sig` blocks to all public methods
4. Run `bundle exec srb tc` and fix errors

#### 4.2 Type Concerns

```ruby
# typed: true
# app/models/concerns/has_truncated_id.rb

module HasTruncatedId
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  sig { returns(String) }
  def truncated_id
    id.to_s[0..7]
  end
end
```

#### 4.3 Handle ActiveRecord Associations

Tapioca DSL generates types for associations, but you may need custom handling:

```ruby
sig { returns(T.nilable(User)) }
def author
  # Association type is auto-generated by tapioca dsl
  super
end
```

---

## Phase 5: Type Services

### Objective
Add comprehensive type signatures to service objects.

### Services to Type

Based on the codebase structure:

1. `ApiHelper` - Central business logic (high priority)
2. `*ParticipantManager` services
3. Webhook services (when implemented)

### Example: Typed Service

```ruby
# typed: strict
# app/services/api_helper.rb

class ApiHelper
  extend T::Sig

  sig { params(user: User, tenant: Tenant).void }
  def initialize(user:, tenant:)
    @user = user
    @tenant = tenant
  end

  sig { params(params: T::Hash[Symbol, T.untyped]).returns(Note) }
  def create_note(params)
    Note.create!(params.merge(author: @user))
  end

  sig { params(note: Note).returns(T::Boolean) }
  def can_edit_note?(note)
    note.author_id == @user.id
  end

  private

  sig { returns(User) }
  attr_reader :user

  sig { returns(Tenant) }
  attr_reader :tenant
end
```

### Tasks

#### 5.1 Create Service Base Class (Optional)

```ruby
# typed: strict
# app/services/application_service.rb

class ApplicationService
  extend T::Sig
  extend T::Helpers
  abstract!

  sig { returns(T.attached_class) }
  def self.build
    new
  end
end
```

#### 5.2 Type Each Service

For each service in `app/services/`:
1. Set sigil to `# typed: strict`
2. Add signatures to all methods
3. Use `T.nilable`, `T::Array`, `T::Hash` as needed

---

## Phase 6: Type Controllers

### Objective
Add type checking to controllers where practical.

### Challenges

Controllers are difficult to type because:
- Heavy use of Rails magic (params, callbacks)
- Instance variables set in callbacks used in actions
- Implicit rendering

### Recommended Approach

#### 6.1 Keep Controllers at `typed: false` Initially

Controllers rely heavily on Rails metaprogramming. Keep them at `typed: false` and focus typing efforts on extracted methods.

#### 6.2 Extract Logic to Typed Methods

```ruby
# typed: false
class NotesController < ApplicationController
  def create
    result = create_note_from_params
    # ...
  end

  private

  # This method can be typed
  sig { returns(Note) }
  def create_note_from_params
    Note.new(note_params)
  end
end
```

#### 6.3 Type API Controllers

API controllers are often simpler and more amenable to typing:

```ruby
# typed: true
module Api
  module V1
    class NotesController < BaseController
      extend T::Sig

      sig { void }
      def index
        notes = Note.all
        render json: notes
      end
    end
  end
end
```

---

## Phase 7: CI Integration

### Objective
Add Sorbet type checking to the CI pipeline.

### Tasks

#### 7.1 Add Sorbet to GitHub Actions

Update `.github/workflows/ruby-tests.yml`:

```yaml
- name: Run Sorbet type check
  run: bundle exec srb tc

# Or with a warning-only approach initially:
- name: Run Sorbet type check
  run: bundle exec srb tc || true
  continue-on-error: true
```

#### 7.2 Add Pre-commit Hook (Optional)

Create `scripts/hooks/pre-commit-sorbet`:

```bash
#!/bin/bash
echo "Running Sorbet type check..."
bundle exec srb tc
```

#### 7.3 Generate RBIs in CI

Ensure RBIs are regenerated if needed:

```yaml
- name: Generate Tapioca RBIs
  run: |
    bundle exec tapioca gems
    bundle exec tapioca dsl
```

#### 7.4 Track Coverage Over Time

Add Spoom coverage to CI:

```yaml
- name: Check Sorbet coverage
  run: bundle exec spoom coverage
```

---

## Sorbet Patterns for Rails

### Pattern: Typed Structs for Data Objects

```ruby
class NoteData < T::Struct
  const :title, String
  const :body, String
  const :author_id, Integer
  prop :published, T::Boolean, default: false
end
```

### Pattern: Enums with T::Enum

```ruby
class NoteStatus < T::Enum
  enums do
    Draft = new
    Published = new
    Archived = new
  end
end
```

### Pattern: Nilable Return Types

```ruby
sig { params(id: Integer).returns(T.nilable(Note)) }
def find_note(id)
  Note.find_by(id: id)
end
```

### Pattern: Block Parameters

```ruby
sig { params(block: T.proc.params(note: Note).void).void }
def each_note(&block)
  Note.find_each(&block)
end
```

### Pattern: Type Aliases

```ruby
# sorbet/rbi/shims/type_aliases.rbi
NoteCollection = T.type_alias { T::Array[Note] }
UserOrNil = T.type_alias { T.nilable(User) }
```

---

## Known Challenges & Solutions

### Challenge: Rails Metaprogramming

**Problem**: Rails uses extensive metaprogramming (e.g., `has_many`, `scope`, `delegate`).

**Solution**: Tapioca's DSL compiler handles most cases. For custom metaprogramming, write manual RBI shims.

### Challenge: Current.user / Current.tenant

**Problem**: `Current` uses thread-local storage with dynamic attributes.

**Solution**: Create manual RBI shim (see Phase 2.4).

### Challenge: Params Hash

**Problem**: `params` returns untyped hash-like object.

**Solution**: Use `T.let` to add type information:

```ruby
title = T.let(params[:title], T.nilable(String))
```

Or create typed param objects:

```ruby
class NoteParams < T::Struct
  const :title, String
  const :body, String
end
```

### Challenge: Default Scopes

**Problem**: The codebase uses `default_scope` with `Current.tenant` checks.

**Solution**: This is handled by Tapioca DSL generation. Ensure RBIs are regenerated after model changes.

### Challenge: Concerns and Mixins

**Problem**: Modules included in models need special handling.

**Solution**: Use `requires_ancestor`:

```ruby
module Publishable
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  sig { returns(T::Boolean) }
  def published?
    # ...
  end
end
```

### Challenge: Polymorphic Associations

**Problem**: Polymorphic associations return different types.

**Solution**: Use `T.any` or abstract interfaces:

```ruby
sig { returns(T.any(User, Studio)) }
def owner
  # polymorphic association
end
```

---

## Appendix: Useful Commands

```bash
# Run type checker
bundle exec srb tc

# Run with specific file
bundle exec srb tc path/to/file.rb

# Generate all RBIs
bundle exec tapioca gems && bundle exec tapioca dsl

# Check coverage
bundle exec spoom coverage

# Bump strictness levels
bundle exec spoom bump --from false --to true --dry-run

# Find untyped code
bundle exec spoom coverage --sort

# Autocorrect some errors
bundle exec srb tc --autocorrect
```

---

## Progress Tracking


### Phase Checklist

- [x] **Phase 1**: Initial Setup ✅
  - [x] Add gems to Gemfile
  - [x] Run `tapioca init`
  - [x] Configure `sorbet/config`

- [x] **Phase 2**: Generate RBI Files ✅
  - [x] Generate gem RBIs
  - [x] Generate DSL RBIs
  - [ ] Create custom shims for `Current`

- [ ] **Phase 3**: Establish Baseline _(in progress)_
  - [ ] Add `# typed: false` to all files
  - [ ] Install Spoom
  - [ ] Measure initial coverage

- [ ] **Phase 4**: Type Core Models
  - [ ] User model
  - [ ] Tenant model
  - [ ] Studio model
  - [ ] Note model
  - [ ] Decision/Option models
  - [ ] Commitment model
  - [ ] Cycle model

- [ ] **Phase 5**: Type Services
  - [ ] ApiHelper
  - [ ] Participant manager services

- [ ] **Phase 6**: Type Controllers
  - [ ] API controllers to `typed: true`
  - [ ] Extract typed methods from main controllers

- [ ] **Phase 7**: CI Integration
  - [ ] Add Sorbet check to GitHub Actions
  - [ ] Add coverage reporting
  - [ ] Optional: pre-commit hook

---

## Resources

- [Sorbet Documentation](https://sorbet.org/docs/overview)
- [Tapioca GitHub](https://github.com/Shopify/tapioca)
- [Spoom GitHub](https://github.com/Shopify/spoom)
- [Sorbet Rails Guide](https://sorbet.org/docs/adopting#getting-started-with-ruby-on-rails)
- [RBI Central](https://github.com/Shopify/rbi-central) - Community type definitions
