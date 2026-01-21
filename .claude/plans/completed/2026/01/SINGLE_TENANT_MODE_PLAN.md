# Single Tenant Mode Implementation Plan

## Overview

Add a `SINGLE_TENANT_MODE=true` environment variable that enables running Harmonic on a single domain (e.g., `http://localhost:3000`) without subdomains or Caddy reverse proxy. Multi-tenant mode remains fully functional when not set.

**Two-phase approach:**
- **Phase A**: Single-tenant mode with `honor_system` auth only (TDD)
- **Phase B**: Add OAuth support (future, separate effort)

**TDD Approach:** Write failing tests first, then implement to make them pass.

---

## Phase A: Single-Tenant Mode with Honor System Auth

### Target Configuration

```bash
SINGLE_TENANT_MODE=true
HOSTNAME=localhost:3000
PRIMARY_SUBDOMAIN=app
AUTH_MODE=honor_system
```

---

## Step 1: Write Failing Tests (RED)

### 1.1 Tenant Model Tests

**Add to `test/models/tenant_test.rb`:**

```ruby
# === Single Tenant Mode Tests ===

test "Tenant.single_tenant_mode? returns false by default" do
  ENV.delete('SINGLE_TENANT_MODE')
  assert_not Tenant.single_tenant_mode?
end

test "Tenant.single_tenant_mode? returns true when env var set" do
  ENV['SINGLE_TENANT_MODE'] = 'true'
  assert Tenant.single_tenant_mode?
ensure
  ENV.delete('SINGLE_TENANT_MODE')
end

test "Tenant.scope_thread_to_tenant handles empty subdomain in single-tenant mode" do
  ENV['SINGLE_TENANT_MODE'] = 'true'
  tenant = create_tenant(subdomain: ENV['PRIMARY_SUBDOMAIN'])

  # Empty subdomain should resolve to PRIMARY_SUBDOMAIN tenant
  result = Tenant.scope_thread_to_tenant(subdomain: "")
  assert_equal tenant.id, result.id
  assert_equal tenant.id, Tenant.current_id
ensure
  ENV.delete('SINGLE_TENANT_MODE')
end

test "Tenant.scope_thread_to_tenant raises for empty subdomain in multi-tenant mode" do
  ENV.delete('SINGLE_TENANT_MODE')

  assert_raises RuntimeError, "Invalid subdomain" do
    Tenant.scope_thread_to_tenant(subdomain: "")
  end
end

test "Tenant.domain returns hostname without subdomain in single-tenant mode" do
  ENV['SINGLE_TENANT_MODE'] = 'true'
  tenant = create_tenant(subdomain: "example")

  assert_equal ENV['HOSTNAME'], tenant.domain
ensure
  ENV.delete('SINGLE_TENANT_MODE')
end

test "Tenant.domain returns subdomain.hostname in multi-tenant mode" do
  ENV.delete('SINGLE_TENANT_MODE')
  tenant = create_tenant(subdomain: "example")

  assert_equal "example.#{ENV['HOSTNAME']}", tenant.domain
end

test "Tenant.url returns http for localhost in single-tenant mode" do
  ENV['SINGLE_TENANT_MODE'] = 'true'
  original_hostname = ENV['HOSTNAME']
  ENV['HOSTNAME'] = 'localhost:3000'
  tenant = create_tenant(subdomain: "example")

  assert_equal "http://localhost:3000", tenant.url
ensure
  ENV.delete('SINGLE_TENANT_MODE')
  ENV['HOSTNAME'] = original_hostname
end

test "Tenant.url returns https for non-localhost in single-tenant mode" do
  ENV['SINGLE_TENANT_MODE'] = 'true'
  original_hostname = ENV['HOSTNAME']
  ENV['HOSTNAME'] = 'app.example.com'
  tenant = create_tenant(subdomain: "example")

  assert_equal "https://app.example.com", tenant.url
ensure
  ENV.delete('SINGLE_TENANT_MODE')
  ENV['HOSTNAME'] = original_hostname
end
```

### 1.2 Superagent Model Tests

**Create `test/models/superagent_single_tenant_test.rb`:**

```ruby
require "test_helper"

class SuperagentSingleTenantTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: ENV['PRIMARY_SUBDOMAIN'] || 'app')
    @user = create_user
    @tenant.add_user!(@user)
    @tenant.create_main_superagent!(created_by: @user)
  end

  test "Superagent.scope_thread_to_superagent handles empty subdomain in single-tenant mode" do
    ENV['SINGLE_TENANT_MODE'] = 'true'

    result = Superagent.scope_thread_to_superagent(subdomain: "", handle: nil)

    assert_equal @tenant.main_superagent.id, result.id
    assert_equal @tenant.id, Tenant.current_id
  ensure
    ENV.delete('SINGLE_TENANT_MODE')
  end

  test "Superagent.scope_thread_to_superagent raises for empty subdomain in multi-tenant mode" do
    ENV.delete('SINGLE_TENANT_MODE')

    assert_raises RuntimeError do
      Superagent.scope_thread_to_superagent(subdomain: "", handle: nil)
    end
  end
end
```

### 1.3 Integration Tests for Honor System Login

**Add to `test/controllers/honor_system_sessions_controller_test.rb`:**

```ruby
# === Single Tenant Mode Tests ===

test "login works without subdomain in single-tenant mode" do
  skip "Honor system routes not loaded" unless honor_system_routes_available?

  ENV['SINGLE_TENANT_MODE'] = 'true'

  # Create tenant matching PRIMARY_SUBDOMAIN
  tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
           create_tenant(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
  user = create_user
  tenant.add_user!(user)
  tenant.create_main_superagent!(created_by: user) unless tenant.main_superagent

  # Use localhost without subdomain
  host! ENV['HOSTNAME']

  post "/login", params: { email: user.email }

  assert_response :redirect
ensure
  ENV.delete('SINGLE_TENANT_MODE')
end

test "login creates session correctly in single-tenant mode" do
  skip "Honor system routes not loaded" unless honor_system_routes_available?

  ENV['SINGLE_TENANT_MODE'] = 'true'

  tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
           create_tenant(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
  user = create_user
  tenant.add_user!(user)
  tenant.create_main_superagent!(created_by: user) unless tenant.main_superagent

  host! ENV['HOSTNAME']

  post "/login", params: { email: user.email }

  # Verify we can access protected resource
  get "/"
  assert_response :success
ensure
  ENV.delete('SINGLE_TENANT_MODE')
end

private

def create_tenant(subdomain:, name:)
  Tenant.create!(subdomain: subdomain, name: name)
end

def create_user
  User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
end
```

### 1.4 Application Controller Tests

**Create `test/controllers/application_controller_single_tenant_test.rb`:**

```ruby
require "test_helper"

class ApplicationControllerSingleTenantTest < ActionDispatch::IntegrationTest
  def setup
    ENV['SINGLE_TENANT_MODE'] = 'true'
    @tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
              Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @user = User.create!(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    @tenant.add_user!(@user)
    @tenant.create_main_superagent!(created_by: @user) unless @tenant.main_superagent
    @superagent = @tenant.main_superagent
  end

  def teardown
    ENV.delete('SINGLE_TENANT_MODE')
  end

  test "can access app on plain hostname without subdomain" do
    host! ENV['HOSTNAME']

    # Just verify we don't get a routing error
    get "/"
    assert_response :redirect # redirects to login or home
  end

  test "tenant is resolved correctly from empty subdomain" do
    host! "localhost:3000"
    ENV['HOSTNAME'] = 'localhost:3000'

    get "/"

    # If we get here without error, tenant was resolved
    assert [200, 302].include?(response.status)
  end

  test "check_auth_subdomain is skipped in single-tenant mode" do
    # In multi-tenant mode, accessing auth subdomain without being auth controller
    # would redirect to /login. In single-tenant mode, this check is skipped.
    host! ENV['HOSTNAME']

    get "/"

    # Should not redirect to /login due to auth subdomain check
    # (may redirect for other reasons like require_login)
    assert [200, 302].include?(response.status)
  end
end
```

---

## Step 2: Run Tests to Verify They Fail (RED)

```bash
# Run all new single-tenant tests
docker compose exec web bundle exec rails test test/models/tenant_test.rb -n /single_tenant/i
docker compose exec web bundle exec rails test test/models/superagent_single_tenant_test.rb
docker compose exec web bundle exec rails test test/controllers/application_controller_single_tenant_test.rb

# Run honor system tests (with AUTH_MODE=honor_system)
docker compose exec web env AUTH_MODE=honor_system bundle exec rails test test/controllers/honor_system_sessions_controller_test.rb
```

Expected: Tests should fail because:
- `Tenant.single_tenant_mode?` method doesn't exist
- Empty subdomain handling isn't implemented
- `domain` and `url` methods don't check single-tenant mode

---

## Step 3: Implement Features (GREEN)

### 3.1 Create SingleTenantMode Concern

**Create `app/models/concerns/single_tenant_mode.rb`:**

```ruby
# typed: strict

module SingleTenantMode
  extend ActiveSupport::Concern
  extend T::Sig

  class_methods do
    extend T::Sig

    sig { returns(T::Boolean) }
    def single_tenant_mode?
      ENV['SINGLE_TENANT_MODE'] == 'true'
    end

    sig { returns(T.nilable(String)) }
    def single_tenant_subdomain
      ENV['PRIMARY_SUBDOMAIN']
    end
  end
end
```

### 3.2 Update ApplicationRecord

**Modify `app/models/application_record.rb`:**

Add near the top:
```ruby
include SingleTenantMode
```

### 3.3 Update Tenant Model

**Modify `app/models/tenant.rb`:**

Update `scope_thread_to_tenant` (around line 28):
```ruby
sig { params(subdomain: String).returns(Tenant) }
def self.scope_thread_to_tenant(subdomain:)
  # In single-tenant mode, treat empty/blank subdomain as PRIMARY_SUBDOMAIN
  if single_tenant_mode? && subdomain.blank?
    subdomain = single_tenant_subdomain.to_s
  end

  if subdomain == ENV['AUTH_SUBDOMAIN']
    # ... existing auth subdomain logic unchanged
  else
    tenant = find_by(subdomain: subdomain)
  end
  # ... rest unchanged
end
```

Update `domain` method (around line 251):
```ruby
sig { returns(String) }
def domain
  if self.class.single_tenant_mode?
    ENV['HOSTNAME']
  else
    "#{subdomain}.#{ENV['HOSTNAME']}"
  end
end
```

Update `url` method (around line 256):
```ruby
sig { returns(String) }
def url
  if self.class.single_tenant_mode?
    protocol = ENV['HOSTNAME'].to_s.include?('localhost') ? 'http' : 'https'
    "#{protocol}://#{ENV['HOSTNAME']}"
  else
    "https://#{domain}"
  end
end
```

### 3.4 Update Superagent Model

**Modify `app/models/superagent.rb`:**

Find `scope_thread_to_superagent` method and add at the beginning:
```ruby
# In single-tenant mode, treat empty/blank subdomain as PRIMARY_SUBDOMAIN
if Tenant.single_tenant_mode? && subdomain.blank?
  subdomain = Tenant.single_tenant_subdomain.to_s
end
```

### 3.5 Update Application Controller

**Modify `app/controllers/application_controller.rb`:**

Add helper method (at bottom with other helpers, around line 620):
```ruby
def single_tenant_mode?
  ENV['SINGLE_TENANT_MODE'] == 'true'
end
```

Update `check_auth_subdomain` (around line 10):
```ruby
def check_auth_subdomain
  return if single_tenant_mode?
  if request.subdomain == auth_subdomain && !is_auth_controller?
    redirect_to '/login'
  end
end
```

### 3.6 Update Host Configuration

**Modify `config/environments/development.rb`:**

Find hosts configuration section and update:
```ruby
config.hosts << ENV['HOSTNAME'] if ENV['HOSTNAME'].present?
config.hosts << 'localhost'
config.hosts << /localhost:\d+/

# Only add subdomain pattern in multi-tenant mode
unless ENV['SINGLE_TENANT_MODE'] == 'true'
  config.hosts << Regexp.new(".*\.#{ENV['HOSTNAME']}") if ENV['HOSTNAME'].present?
end
```

### 3.7 Update .env.example

Add documentation:
```bash
# Single tenant mode - run without subdomains on a single domain (e.g., localhost:3000)
# When enabled, uses PRIMARY_SUBDOMAIN as the default tenant and skips subdomain routing
# SINGLE_TENANT_MODE=true
```

---

## Step 4: Run Tests to Verify They Pass (GREEN)

```bash
# Run all single-tenant tests
docker compose exec web bundle exec rails test test/models/tenant_test.rb
docker compose exec web bundle exec rails test test/models/superagent_single_tenant_test.rb
docker compose exec web bundle exec rails test test/controllers/application_controller_single_tenant_test.rb

# Run all tests to ensure no regressions
docker compose exec web bundle exec rails test
```

---

## Step 5: Manual Verification

1. **Start app in single-tenant mode:**
   ```bash
   # Update .env with:
   # SINGLE_TENANT_MODE=true
   # HOSTNAME=localhost:3000
   # PRIMARY_SUBDOMAIN=app
   # AUTH_MODE=honor_system

   ./scripts/start.sh
   ```

2. **Test login flow:**
   - Navigate to `http://localhost:3000/login`
   - Enter email, verify session created

3. **Test content creation:**
   - Create a note
   - Verify shareable link is `http://localhost:3000/n/...`

---

## Files to Modify (Phase A)

| File | Changes |
|------|---------|
| `test/models/tenant_test.rb` | Add 7 single-tenant mode tests |
| `test/models/superagent_single_tenant_test.rb` | **New** - 2 tests |
| `test/controllers/honor_system_sessions_controller_test.rb` | Add 2 single-tenant tests |
| `test/controllers/application_controller_single_tenant_test.rb` | **New** - 3 tests |
| `app/models/concerns/single_tenant_mode.rb` | **New** - helper module |
| `app/models/application_record.rb` | Include SingleTenantMode |
| `app/models/tenant.rb` | `scope_thread_to_tenant`, `domain`, `url` |
| `app/models/superagent.rb` | Handle empty subdomain |
| `app/controllers/application_controller.rb` | `check_auth_subdomain`, helper |
| `config/environments/development.rb` | Host validation |
| `.env.example` | Document new variable |

---

## Phase B: OAuth Support (Future)

**Deferred until Phase A is complete and verified.**

---

## Notes

- Multi-tenant production setup remains **completely unchanged** when `SINGLE_TENANT_MODE` is not set
- Honor system auth already works without subdomains - no changes needed to `honor_system_sessions_controller.rb`
- The `AUTH_SUBDOMAIN` env var is effectively ignored in single-tenant mode
- Test files use `ensure` blocks to restore ENV state after tests
