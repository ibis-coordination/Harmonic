# Controller Refactoring Plan

This document captures observations and plans for refactoring controllers to better support Sorbet type checking. This is a future project, to be started after the initial Sorbet integration is merged.

## Background

During Phase 6 of the Sorbet implementation, we discovered that Rails controllers present unique challenges for type checking:

1. **Instance variables set by callbacks** - Data flows through `@instance_vars` set in `before_action`, which Sorbet can't trace
2. **Untyped `params`** - `ActionController::Parameters` is essentially untyped
3. **Implicit rendering** - No return values to type
4. **Heavy metaprogramming** - `before_action`, `respond_to`, strong parameters, etc.

## Current State

For the initial Sorbet rollout:
- Most controllers remain at `# typed: false`
- Simple controllers may be set to `# typed: true` with minimal changes
- Business logic lives in typed services (`ApiHelper`, etc.)

## Observations

### Controllers That Work Well with Types

These controllers have been set to `# typed: true` with minimal changes:

1. **HealthcheckController** ([healthcheck_controller.rb](../../app/controllers/healthcheck_controller.rb))
   - Standalone controller (inherits from `ActionController::Base`, not `ApplicationController`)
   - Single method, no instance variables, no callbacks
   - No changes needed beyond the sigil

2. **Api::V1::InfoController** ([api/v1/info_controller.rb](../../app/controllers/api/v1/info_controller.rb))
   - Returns static JSON, no dynamic data
   - Private methods return simple values (`nil` or model classes)
   - Only needed `extend T::Sig`

### Controllers That Need Refactoring

1. **ApplicationController** (~588 lines)
   - Central hub for all HTML controllers
   - Sets many instance variables via `before_action` callbacks
   - Heavy metaprogramming with `respond_to`, format negotiation
   - Contains business logic that should be in services
   - Key concerns: `set_current_tenant`, `set_current_user`, `load_current_resource`

2. **Api::V1::BaseController**
   - Uses metaprogramming to dynamically define resource methods
   - Sets `@current_tenant`, `@current_studio`, `@current_user`, `@current_resource` in callbacks
   - All API controllers depend on these instance variables

3. **All controllers inheriting from ApplicationController**
   - HomeController, NotesController, DecisionsController, etc.
   - Depend on untyped instance variables from parent
   - Mix controller concerns with business logic

### Common Patterns to Address

1. **Instance variables set by callbacks**
   - Pattern: `before_action :set_current_user` → `@current_user`
   - Problem: Sorbet can't trace the flow from callback to action
   - Solution: Use typed accessor methods or T::Struct for context

2. **Untyped params access**
   - Pattern: `params[:note][:title]`, `params.require(:decision).permit(...)`
   - Problem: `ActionController::Parameters` is essentially `T.untyped`
   - Solution: Parse params into T::Struct at controller boundary

3. **Method chaining on nilable associations**
   - Pattern: `current_resource.studio.tenant.subdomain`
   - Problem: Each step could be nil
   - Solution: Move to services with explicit nil handling

4. **Conditional resource loading**
   - Pattern: `current_resource_model` returns different classes based on params
   - Problem: Return type is `T.any(Note, Decision, Commitment, nil)` or worse
   - Solution: Separate controllers per resource type, or typed unions

5. **Api::V1::BaseController metaprogramming**
   - Pattern: `%w[show create update destroy].each { |action| define_method... }`
   - Problem: Dynamically defined methods can't have signatures
   - Solution: Explicit method definitions with signatures

## Proposed Refactoring Approach

### Current Duplication Problem

The codebase has two parallel interfaces that both need business logic:

1. **HTML interface** (`create`, `update` actions) - Currently has inline logic:
   - Creates records with transactions
   - Handles file attachments
   - Handles pinning to studio
   - Records representation session activity
   - Redirects on success, re-renders form on error

2. **Action/LLM interface** (`create_note`, `create_decision` actions) - Delegates to ApiHelper:
   - Calls `api_helper.create_note`, etc.
   - Renders action_success/action_error

**The problem**: Logic is duplicated. For example, representation session recording exists both in:
- `NotesController#create` (lines 36-51)
- `ApiHelper#create_note` (lines 165-180)

### Goal: Expand ApiHelper as Single Source of Truth

Rather than creating new service classes, expand `ApiHelper` to be the canonical location for all business logic. Controllers become thin wrappers.

### Changes to ApiHelper

1. **Add file upload support**:
   ```ruby
   sig { params(commentable: T.nilable(T.any(Note, Decision, Commitment)), files: T.nilable(T::Array[T.untyped])).returns(Note) }
   def create_note(commentable: nil, files: nil)
     # ... create note ...
     if files && current_tenant.allow_file_uploads? && current_studio.allow_file_uploads?
       note.attach!(files)
     end
     # ...
   end
   ```

2. **Add pinning support**:
   ```ruby
   sig { params(..., pinned: T::Boolean).returns(Note) }
   def create_note(..., pinned: false)
     # ... create note ...
     if pinned && current_studio.id != current_tenant.main_studio_id
       current_studio.pin_item!(note)
     end
     # ...
   end
   ```

3. **Representation session recording stays in ApiHelper** (already there, just remove duplicates from controllers)

### Changes to Controllers

Controllers become thin - just parse params and delegate:

```ruby
# typed: false (controller can stay untyped)
class NotesController < ApplicationController
  def create
    begin
      @note = api_helper.create_note(
        files: params[:files],
        pinned: params[:pinned] == '1',
      )
      redirect_to @note.path
    rescue ActiveRecord::RecordInvalid => e
      flash.now[:alert] = e.record.errors.full_messages.join(", ")
      @note = Note.new(title: model_params[:title], text: model_params[:text])
      render :new
    end
  end

  def create_note
    # Action/LLM interface - already uses api_helper
    begin
      note = api_helper.create_note
      render_action_success(action_name: 'create_note', resource: note, result: "Note created.")
    rescue ActiveRecord::RecordInvalid => e
      render_action_error(action_name: 'create_note', resource: current_note, error: e.message)
    end
  end
end
```

### Key Benefits

1. **Single source of truth** - Business logic in ApiHelper only
2. **Already typed** - ApiHelper is `# typed: true` with full signatures
3. **Testable** - Test business logic by testing ApiHelper directly
4. **Minimal disruption** - Controllers don't need heavy refactoring, just delegate to existing helper

## Priority Order for Refactoring

1. **Remove representation session duplication** - Delete from controllers, keep in ApiHelper
2. **Add files/pinning parameters to ApiHelper** - Expand existing methods
3. **Slim down NotesController, DecisionsController** - Delegate to api_helper
4. **Repeat for other controllers** - CommitmentsController, etc.

## Success Criteria

- No business logic duplication between controllers and ApiHelper
- Representation session recording happens in exactly one place (ApiHelper)
- Controllers only handle: param parsing, calling api_helper, rendering/redirecting
- ApiHelper has comprehensive signatures for all operations

## Non-Goals

- Controllers don't need to be `typed: true` - they can remain at `typed: false` as thin wrappers
- No need for separate service classes (NoteCreator, DecisionCreator, etc.) - ApiHelper already fills this role

## Timeline

To be determined after initial Sorbet integration is complete.
