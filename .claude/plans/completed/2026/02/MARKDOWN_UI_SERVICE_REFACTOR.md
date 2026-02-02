# MarkdownUiService Refactor: Internal Request Dispatch

## Problem

The current `MarkdownUiService` implementation is fragile because it duplicates logic from multiple places:

1. **Route resolution** - Manual mapping in `build_route_pattern` that mirrors `config/routes.rb`
2. **Resource loading** - `ResourceLoader` reimplements what controllers do in before_actions and action methods
3. **ViewContext** - Manually maintains instance variables that controllers set automatically
4. **Action discovery** - Separate `ActionsHelper` mapping instead of deriving from actual routes

This duplication means every new route, controller change, or instance variable addition requires updates in multiple places, leading to bugs like the empty pages issue when `pulse#show` wasn't handled.

## Solution

Refactor `MarkdownUiService` to dispatch internal HTTP requests through the Rails stack, using the same code path that external API clients use. This eliminates duplication by leveraging:

- Rails router for route resolution
- Actual controllers for resource loading and business logic
- Existing markdown templates with their instance variables
- Real HTTP responses

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     MarkdownUiService                            │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│  │ navigate()  │───▶│ Internal Request │───▶│ Rails.app.call │  │
│  │ execute()   │    │ Dispatcher       │    │                │  │
│  └─────────────┘    └──────────────────┘    └───────┬────────┘  │
└─────────────────────────────────────────────────────┼───────────┘
                                                      ▼
                              ┌────────────────────────────────────┐
                              │         Rails Stack                 │
                              │  Router → Controller → Template     │
                              │         (existing code)             │
                              └────────────────────────────────────┘
```

---

## Phase 1: Internal API Tokens

### 1.1 Add columns to ApiToken

Internal tokens need a way to recover the plaintext token for in-process requests. We store an encrypted version of the plaintext that can only be decrypted with the app's secret key.

**Migration:**
```ruby
class AddInternalTokenSupport < ActiveRecord::Migration[7.0]
  def change
    add_column :api_tokens, :internal, :boolean, default: false, null: false
    add_column :api_tokens, :internal_encrypted_token, :text, null: true
    add_index :api_tokens, :internal
  end
end
```

### 1.2 Model Changes

**File: `app/models/api_token.rb`**

```ruby
# Scopes
scope :internal, -> { where(internal: true) }
scope :external, -> { where(internal: false) }

# Validations
validate :external_tokens_cannot_have_encrypted_token

def internal?
  internal
end

# Decrypt and return the plaintext token (only works for internal tokens)
def decrypted_token
  return nil unless internal? && internal_encrypted_token.present?

  encryptor.decrypt_and_verify(internal_encrypted_token)
rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveSupport::MessageEncryptor::InvalidMessage
  nil
end

# Find or create an internal token for a user within a tenant
def self.find_or_create_internal_token(user:, tenant:)
  existing = internal.find_by(user: user, tenant: tenant)
  return existing if existing

  # Generate a new token
  token = new(
    user: user,
    tenant: tenant,
    internal: true,
    scopes: valid_scopes,
    name: "Internal Agent Token"
  )

  # Generate the plaintext and hash it (normal flow)
  token.generate_token

  # Also store the encrypted plaintext for internal recovery
  token.internal_encrypted_token = token.encrypt_plaintext_token

  token.save!
  token
end

private

def external_tokens_cannot_have_encrypted_token
  if !internal? && internal_encrypted_token.present?
    errors.add(:internal_encrypted_token, "must be null for external tokens")
  end
end

def encrypt_plaintext_token
  return nil unless @plaintext_token # Only available during creation

  encryptor.encrypt_and_sign(@plaintext_token)
end

def encryptor
  @encryptor ||= begin
    key = Rails.application.secret_key_base
    derived_key = ActiveSupport::KeyGenerator.new(key).generate_key("internal_api_token", 32)
    ActiveSupport::MessageEncryptor.new(derived_key)
  end
end
```

### 1.3 Security Properties

This approach provides strong security guarantees:

| Property | External Tokens | Internal Tokens |
|----------|-----------------|-----------------|
| Plaintext stored? | No (hash only) | Encrypted with app secret |
| Recoverable from DB alone? | No | No (need secret key) |
| Shown in UI/API? | Yes | No |
| Usable if DB leaks? | No | No |

**Key insight**: Even if an attacker obtains the database, they cannot use internal tokens without the app's `SECRET_KEY_BASE`. The encryption uses the same battle-tested approach as Rails session cookies.

### 1.4 Controller Protection

Controllers don't need any changes for auth - they just see a normal bearer token. The only change is hiding internal tokens from UI/API responses:

```ruby
# In ApiTokensController or wherever tokens are listed
def index
  @tokens = current_user.api_tokens.external # Never show internal tokens
end

# In any API that returns tokens
def token_json(token)
  return nil if token.internal? # Never serialize internal tokens
  # ... normal serialization
end
```

---

## Phase 2: Actions in YAML Frontmatter

### 2.1 Current State

Currently, actions are listed in a separate "Actions" section in the markdown body. The available actions are determined by `ActionsHelper.actions_for_route`.

### 2.2 Add Actions to Frontmatter

Modify the markdown layout to include actions in the YAML frontmatter, making them machine-readable:

**File: `app/views/layouts/application.md.erb`**
```erb
---
app: Harmonic
title: <%= @page_title %>
path: <%= @current_path %>
actions:
<% available_actions_for_current_route.each do |action| -%>
  - name: <%= action[:name] %>
    description: <%= action[:description] %>
    path: <%= action[:path] %>
<% if action[:params]&.any? -%>
    params:
<% action[:params].each do |param| -%>
      - name: <%= param[:name] %>
        type: <%= param[:type] %>
        required: <%= param[:required] %>
<% if param[:description] -%>
        description: <%= param[:description] %>
<% end -%>
<% end -%>
<% end -%>
<% end -%>
---
nav: | [Home](/) | ...
```

### 2.3 Helper Method

**File: `app/helpers/markdown_helper.rb`**
```ruby
def available_actions_for_current_route
  pattern = build_route_pattern_from_request
  actions_info = ActionsHelper.actions_for_route(pattern)
  actions_info&.fetch(:actions, []) || []
end

private

def build_route_pattern_from_request
  # Derive the pattern from the current request
  # This replaces the manual mapping in MarkdownUiService
  controller = params[:controller]
  action = params[:action]

  case controller
  when "home"
    "/"
  when "pulse"
    "/studios/:studio_handle"
  when "notes"
    case action
    when "show" then "/n/:note_id"
    when "new" then "/studios/:studio_handle/note"
    # etc.
    end
  # ... other controllers
  end
end
```

### 2.4 Parsing Actions in MarkdownUiService

```ruby
def parse_frontmatter(content)
  return {} unless content.start_with?("---\n")

  # Find the closing ---
  end_index = content.index("\n---\n", 4)
  return {} unless end_index

  yaml_content = content[4...end_index]
  YAML.safe_load(yaml_content, permitted_classes: [Symbol])
rescue Psych::SyntaxError
  {}
end

def navigate(path)
  # ... dispatch request ...

  frontmatter = parse_frontmatter(response_body)

  {
    content: response_body,
    path: path,
    actions: frontmatter["actions"] || [],
    error: nil,
  }
end
```

---

## Phase 3: Internal Request Dispatcher

### 3.1 New MarkdownUiService Implementation

**File: `app/services/markdown_ui_service.rb`**

```ruby
# typed: strict
# frozen_string_literal: true

class MarkdownUiService
  extend T::Sig

  class InternalRequestDispatcher
    extend T::Sig

    sig { params(tenant: Tenant, user: T.nilable(User)).void }
    def initialize(tenant:, user:)
      @tenant = tenant
      @user = user
      @session = T.let(
        ActionDispatch::Integration::Session.new(Rails.application),
        ActionDispatch::Integration::Session
      )
      @session.host = "#{tenant.subdomain}.#{ENV['HOSTNAME']}"
      @token = T.let(nil, T.nilable(ApiToken))
    end

    sig { params(path: String).returns(T::Hash[Symbol, T.untyped]) }
    def get(path)
      ensure_token!

      @session.get(path, headers: request_headers)

      build_response
    end

    sig { params(path: String, params: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def post(path, params:)
      ensure_token!

      @session.post(path, params: params.to_json, headers: request_headers)

      build_response
    end

    private

    sig { returns(T::Hash[String, String]) }
    def request_headers
      headers = {
        "Accept" => "text/markdown",
        "Content-Type" => "application/json",
      }

      if @token
        # Use decrypted_token to recover the plaintext from encrypted storage
        headers["Authorization"] = "Bearer #{@token.decrypted_token}"
      end

      headers
    end

    sig { void }
    def ensure_token!
      return if @token
      return unless @user

      # Find or create an internal token - the encrypted plaintext
      # can be decrypted later using decrypted_token
      @token = ApiToken.find_or_create_internal_token(
        user: @user,
        tenant: @tenant
      )
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def build_response
      status = @session.response.status
      body = @session.response.body

      if status >= 200 && status < 300
        frontmatter = parse_frontmatter(body)
        {
          success: true,
          content: body,
          path: frontmatter["path"],
          actions: frontmatter["actions"] || [],
          error: nil,
        }
      else
        {
          success: false,
          content: body,
          path: nil,
          actions: [],
          error: "HTTP #{status}",
        }
      end
    end

    sig { params(content: String).returns(T::Hash[String, T.untyped]) }
    def parse_frontmatter(content)
      return {} unless content.start_with?("---\n")

      end_index = content.index("\n---\n", 4)
      return {} unless end_index

      yaml_content = content[4...end_index]
      YAML.safe_load(yaml_content, permitted_classes: [Symbol]) || {}
    rescue Psych::SyntaxError
      {}
    end
  end

  # Public interface remains the same
  sig { params(tenant: Tenant, superagent: T.nilable(Superagent), user: T.nilable(User)).void }
  def initialize(tenant:, superagent:, user:)
    @tenant = tenant
    @superagent = superagent
    @user = user
    @dispatcher = T.let(
      InternalRequestDispatcher.new(tenant: tenant, user: user),
      InternalRequestDispatcher
    )
    @current_path = T.let(nil, T.nilable(String))
  end

  sig { params(path: String, include_layout: T::Boolean).returns(T::Hash[Symbol, T.untyped]) }
  def navigate(path, include_layout: true)
    @current_path = path
    result = @dispatcher.get(path)

    {
      content: result[:content],
      path: path,
      actions: result[:actions],
      error: result[:error],
    }
  end

  sig { params(action_name: String, params: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def execute_action(action_name, params = {})
    return { success: false, error: "No current path" } unless @current_path

    action_path = "#{@current_path}/actions/#{action_name}"
    result = @dispatcher.post(action_path, params: params)

    {
      success: result[:success],
      content: result[:content],
      path: result[:path],
      error: result[:error],
    }
  end
end
```

### 3.2 Files to Delete After Migration

Once the refactor is complete and tested, these files can be removed:

- `app/services/markdown_ui_service/view_context.rb`
- `app/services/markdown_ui_service/resource_loader.rb`
- `app/services/markdown_ui_service/action_executor.rb` (if actions go through HTTP too)

The `build_route_pattern` method in the current `MarkdownUiService` can also be removed.

---

## Phase 4: Testing

### 4.1 Internal Token Tests

```ruby
# test/models/api_token_test.rb
test "find_or_create_internal_token creates internal token with encrypted plaintext" do
  token = ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)

  assert token.internal?
  assert_equal @user, token.user
  assert_equal @tenant, token.tenant
  assert token.internal_encrypted_token.present?
end

test "decrypted_token returns the original plaintext" do
  token = ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)

  # The decrypted token should be valid for authentication
  decrypted = token.decrypted_token
  assert decrypted.present?

  # Verify it matches by checking authentication works
  authenticated = ApiToken.authenticate(decrypted, tenant_id: @tenant.id)
  assert_equal token.id, authenticated.id
end

test "find_or_create_internal_token returns existing token" do
  token1 = ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)
  token2 = ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)

  assert_equal token1.id, token2.id
  # Decrypted token still works after retrieval
  assert token2.decrypted_token.present?
end

test "external tokens cannot have encrypted token" do
  token = ApiToken.new(
    user: @user,
    tenant: @tenant,
    internal: false,
    internal_encrypted_token: "should_not_be_allowed",
    scopes: ["read"],
    name: "External Token"
  )

  assert_not token.valid?
  assert_includes token.errors[:internal_encrypted_token], "must be null for external tokens"
end

test "decrypted_token returns nil for external tokens" do
  token = ApiToken.create!(
    user: @user,
    tenant: @tenant,
    internal: false,
    scopes: ["read"],
    name: "External Token"
  )

  assert_nil token.decrypted_token
end

test "internal tokens not shown in API" do
  ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)

  get api_tokens_path, headers: auth_headers

  tokens = JSON.parse(response.body)
  assert tokens.none? { |t| t["internal"] }
end

test "encrypted token cannot be decrypted without secret key" do
  token = ApiToken.find_or_create_internal_token(user: @user, tenant: @tenant)
  encrypted = token.internal_encrypted_token

  # Attempting to decrypt with wrong key should fail
  wrong_encryptor = ActiveSupport::MessageEncryptor.new(SecureRandom.bytes(32))

  assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
    wrong_encryptor.decrypt_and_verify(encrypted)
  end
end
```

### 4.2 Internal Request Dispatcher Tests

```ruby
# test/services/markdown_ui_service_test.rb
test "navigate dispatches through Rails and returns markdown" do
  service = MarkdownUiService.new(tenant: @tenant, superagent: @superagent, user: @user)

  result = service.navigate("/studios/#{@superagent.handle}")

  assert_nil result[:error]
  assert result[:content].start_with?("---\napp: Harmonic")
  assert result[:actions].any?
end

test "navigate to note returns correct actions in frontmatter" do
  note = create_note(superagent: @superagent, created_by: @user)
  service = MarkdownUiService.new(tenant: @tenant, superagent: @superagent, user: @user)

  result = service.navigate("/n/#{note.truncated_id}")

  action_names = result[:actions].map { |a| a["name"] }
  assert_includes action_names, "confirm_read"
end

test "execute_action posts to action endpoint" do
  service = MarkdownUiService.new(tenant: @tenant, superagent: @superagent, user: @user)
  service.navigate("/studios/#{@superagent.handle}/note")

  result = service.execute_action("create_note", { text: "Test note" })

  assert result[:success]
  assert Note.exists?(text: "Test note")
end
```

### 4.3 Integration Test: AgentNavigator Still Works

```ruby
# test/services/agent_navigator_test.rb
test "agent can navigate and create note using refactored service" do
  navigator = AgentNavigator.new(user: @agent, tenant: @tenant, superagent: @superagent)

  # This should work exactly as before, but now uses internal HTTP dispatch
  result = navigator.run(task: "Create a note saying hello", max_steps: 10)

  assert result.success
  assert Note.exists?(text: /hello/i)
end
```

---

## Migration Strategy

### Step 1: Add infrastructure (non-breaking)
- Add `internal` column to `api_tokens`
- Add `find_or_create_internal_token` method
- Add actions to YAML frontmatter (additive, doesn't break existing parsing)

### Step 2: Create new implementation alongside old
- Create `InternalRequestDispatcher` class
- Create new `MarkdownUiService` implementation as `MarkdownUiServiceV2`
- Run both in parallel, comparing outputs

### Step 3: Switch over
- Replace `MarkdownUiService` with new implementation
- Update `AgentNavigator` to use new service
- Run full test suite

### Step 4: Clean up
- Delete `ViewContext`, `ResourceLoader`, `ActionExecutor`
- Remove route pattern mapping code
- Update documentation

---

## Benefits

1. **Single source of truth** - Routes, controllers, and templates are authoritative
2. **No synchronization required** - New routes/controllers work automatically
3. **Same behavior for internal and external** - Internal agents see exactly what external clients see
4. **Easier testing** - Can test the full stack, not mocked pieces
5. **Security through existing mechanisms** - Uses the same auth/authz as external requests

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Performance overhead of HTTP dispatch | Internal dispatch doesn't go through network; benchmark to verify acceptable |
| Session state management | Each request is stateless, like external API calls |
| Error handling differences | Map HTTP status codes to service error types |
| Breaking changes during migration | Run old and new in parallel, compare outputs |

---

## Critical Files

| File | Change |
|------|--------|
| `db/migrate/*_add_internal_token_support.rb` | New migration (internal flag + encrypted token column) |
| `app/models/api_token.rb` | Add internal scope, encrypted token, and factory method |
| `app/views/layouts/application.md.erb` | Add actions to frontmatter |
| `app/helpers/markdown_helper.rb` | Add `available_actions_for_current_route` |
| `app/services/markdown_ui_service.rb` | Replace with dispatcher-based implementation |
| `app/controllers/api_tokens_controller.rb` | Filter out internal tokens from listings |
| `test/models/api_token_test.rb` | Tests for internal token encryption |
| `test/services/markdown_ui_service_test.rb` | Update tests for new implementation |
