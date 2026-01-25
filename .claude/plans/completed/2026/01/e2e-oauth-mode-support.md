# Plan: E2E Tests with OAuth Mode Support

## Goal
Remove the `honor_system` auth mode requirement from E2E tests so they work with the standard `oauth` mode used by Ruby tests and production.

## Approach
Use the existing identity provider (email/password) authentication that's already built into the app. Create a rake task to set up a known test user, and update E2E helpers to log in via the identity form.

---

## Implementation Steps

### 1. Create Rake Task: `lib/tasks/e2e.rake`

Create an idempotent task that sets up the E2E test user:

```ruby
namespace :e2e do
  desc "Setup test user for E2E tests (idempotent)"
  task setup: :environment do
    e2e_email = ENV.fetch('E2E_TEST_EMAIL', 'e2e-test@example.com')
    e2e_password = ENV.fetch('E2E_TEST_PASSWORD', 'e2e-test-password-14chars')
    e2e_name = ENV.fetch('E2E_TEST_NAME', 'E2E Test User')
    tenant_subdomain = ENV.fetch('PRIMARY_SUBDOMAIN', 'app')

    tenant = Tenant.find_by!(subdomain: tenant_subdomain)

    # Enable identity provider
    unless tenant.auth_providers.include?('identity')
      tenant.add_auth_provider!('identity')
    end

    # Create/update OmniAuthIdentity
    identity = OmniAuthIdentity.find_or_initialize_by(email: e2e_email)
    identity.name = e2e_name
    identity.password = e2e_password
    identity.password_confirmation = e2e_password
    identity.save!

    # Create/find User
    user = User.find_or_create_by!(email: e2e_email) do |u|
      u.name = e2e_name
      u.user_type = 'person'
    end

    # Add to tenant
    tenant.add_user!(user) unless tenant.tenant_users.exists?(user: user)

    # Add to main studio
    if tenant.main_superagent
      tenant.main_superagent.add_user!(user) unless tenant.main_superagent.superagent_members.exists?(user: user)
    end

    puts "E2E test user ready: #{e2e_email}"
  end
end
```

### 2. Update `e2e/helpers/auth.ts`

Replace honor_system login with identity provider (email/password) login:

**Key changes:**
- Add `password` to `LoginOptions` interface
- Export default test credentials
- Update `login()` to fill email (`auth_key`) and password fields
- Handle redirect flow: tenant -> auth subdomain -> back to tenant
- Add `loginAsTestUser()` convenience function

**Form field names** (from `_email_password_form.html.erb`):
- Email: `input[name="auth_key"]`
- Password: `input[name="password"]`
- Submit: `input[type="submit"][value="Log in"]`

### 3. Update `e2e/global-setup.ts`

- Remove the honor_system mode check (lines 38-62)
- Keep the healthcheck and basic login page accessibility check
- Update error messages to reference the rake task

### 4. Update `e2e/fixtures/test-fixtures.ts`

- Remove random user generation (`testUser` fixture)
- Use the pre-configured E2E test user with known credentials
- Update `authenticatedPage` fixture to use `loginAsTestUser()`

### 5. Update `scripts/run-e2e.sh`

- Remove AUTH_MODE warning/check
- Add rake task execution before running tests:
  ```bash
  docker compose exec -T web bundle exec rake e2e:setup
  ```

### 6. Update `e2e/tests/auth/login.spec.ts`

Update test assertions for the OAuth/identity flow.

---

## Files to Modify

| File | Action |
|------|--------|
| `lib/tasks/e2e.rake` | **CREATE** |
| `e2e/helpers/auth.ts` | **MODIFY** |
| `e2e/global-setup.ts` | **MODIFY** |
| `e2e/fixtures/test-fixtures.ts` | **MODIFY** |
| `scripts/run-e2e.sh` | **MODIFY** |
| `e2e/tests/auth/login.spec.ts` | **MODIFY** |

---

## Verification

1. **Run rake task:**
   ```bash
   docker compose exec web bundle exec rake e2e:setup
   ```

2. **Test login manually with Playwright MCP:**
   - Navigate to `https://app.harmonic.local/login`
   - Verify redirect to `https://auth.harmonic.local/login`
   - Fill email/password form
   - Verify redirect back to app and logged-in state

3. **Run E2E tests:**
   ```bash
   ./scripts/run-e2e.sh
   ```

4. **Verify Ruby tests still work:**
   ```bash
   ./scripts/run-tests.sh
   ```
