# Plan: Internal Agents Bypass API Enabled Check

## Problem

Internal subagents cannot access studios that don't have API enabled, even though they are Harmonic-powered system agents. This is because `api_authorize!` in `ApplicationController` checks `current_superagent.api_enabled? && current_tenant.api_enabled?` for all API requests.

**Current behavior:**
- Internal subagents use internal API tokens (created via `ApiToken.find_or_create_internal_token`)
- The `api_authorize!` method blocks them when API is disabled at studio or tenant level
- Internal tokens are persistent (100-year expiry) and stored encrypted
- This prevents Harmonic's own agent runners from accessing studios

**Desired behavior:**
- Internal subagents should bypass API enabled checks (both studio and tenant level)
- External subagents should still require API to be enabled
- Internal tokens should be ephemeral (created per-run, deleted after)

## Solution

Two changes:
1. Modify `api_authorize!` to bypass API enabled check for internal tokens
2. Change internal token lifecycle from persistent to ephemeral (per-run)

### Why check `current_token.internal?` (not `current_user.internal_subagent?`)

1. `current_token` is available before `current_user` is set in the auth flow
2. It's a direct property of the authentication mechanism
3. Internal tokens can only be created for internal subagents via controlled system methods

### Why ephemeral tokens?

- **Security:** Token only exists during active task execution (seconds/minutes vs forever)
- **Minimal attack window:** Compromise of one token doesn't affect future runs
- **No encryption needed:** Token doesn't persist, so no need to store recoverable form
- **Performance:** Equivalent query count (INSERT+DELETE vs SELECT+UPDATE)

## Implementation

### Part 1: API Bypass Check

#### File: [app/controllers/application_controller.rb](app/controllers/application_controller.rb)

Change `api_authorize!` method (around line 96):

```ruby
def api_authorize!
  # Internal tokens bypass API enabled checks - they are system-managed
  # and used for internal operations like agent runners
  unless current_token&.internal? || (current_superagent.api_enabled? && current_tenant.api_enabled?)
    superagent_or_tenant = current_tenant.api_enabled? ? 'studio' : 'tenant'
    return render json: { error: "API not enabled for this #{superagent_or_tenant}" }, status: 403
  end
  return render json: { error: 'API only supports JSON or Markdown formats' }, status: 403 unless json_or_markdown_request?
  request.format = :md unless request.format == :json
  current_token || render(json: { error: 'Unauthorized' }, status: 401)
end
```

### Part 2: Ephemeral Token Lifecycle

#### File: [app/models/api_token.rb](app/models/api_token.rb)

Replace `find_or_create_internal_token` with `create_internal_token`:

```ruby
# Create a new internal token for a task run
# Token should be deleted when the run completes
def self.create_internal_token(user:, tenant:, expires_in: 1.hour)
  token_string = SecureRandom.urlsafe_base64(32)

  create!(
    user: user,
    tenant: tenant,
    name: "Internal Agent Token",
    token_hash: hash_token(token_string),
    internal: true,
    scopes: valid_scopes,
    expires_at: Time.current + expires_in,
    # No encrypted storage needed - caller holds plaintext for duration of run
  )

  # Return a struct with the token record and plaintext
  OpenStruct.new(record: token, plaintext: token_string)
end
```

Remove or deprecate:
- `find_or_create_internal_token` method
- `internal_encrypted_token` column (migration to remove)
- `decrypted_token` method

#### File: [app/services/markdown_ui_service.rb](app/services/markdown_ui_service.rb)

Update to use ephemeral tokens:

```ruby
def initialize(user:, tenant:, superagent:)
  @user = user
  @tenant = tenant
  @superagent = superagent
  @internal_token = nil
end

def with_internal_token
  @internal_token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
  yield @internal_token.plaintext
ensure
  @internal_token&.record&.destroy
end
```

#### File: [app/services/agent_navigator.rb](app/services/agent_navigator.rb)

Wrap run in token lifecycle:

```ruby
def run(task:, max_steps:)
  @markdown_service.with_internal_token do |token|
    # ... existing run logic using token ...
  end
end
```

### Part 3: Cleanup Job (safety net)

#### File: [app/jobs/cleanup_expired_internal_tokens_job.rb](app/jobs/cleanup_expired_internal_tokens_job.rb)

```ruby
class CleanupExpiredInternalTokensJob < ApplicationJob
  queue_as :default

  def perform
    # Delete internal tokens that have expired (safety net for crashed runs)
    ApiToken.unscope(where: :internal)
      .where(internal: true)
      .where("expires_at < ?", Time.current)
      .delete_all
  end
end
```

Schedule via cron/whenever to run hourly.

### Part 4: Migration

#### Remove `internal_encrypted_token` column

```ruby
class RemoveInternalEncryptedTokenFromApiTokens < ActiveRecord::Migration[7.0]
  def change
    remove_column :api_tokens, :internal_encrypted_token, :text
  end
end
```

## Tests

### File: [test/integration/api_auth_test.rb](test/integration/api_auth_test.rb)

Add tests for:

1. **Internal token bypasses studio-level API check** - Create internal subagent with internal token, access a studio with API disabled, expect success
2. **Internal token bypasses tenant-level API check** - Disable API at tenant level, internal token should still work
3. **External token still blocked** - Verify external tokens are still blocked when API is disabled

### File: [test/models/api_token_test.rb](test/models/api_token_test.rb)

Add tests for:

1. **create_internal_token creates valid token** - Returns plaintext and record
2. **create_internal_token sets short expiry** - Default 1 hour
3. **Internal token can be destroyed** - Cleanup works

### File: [test/jobs/cleanup_expired_internal_tokens_job_test.rb](test/jobs/cleanup_expired_internal_tokens_job_test.rb)

Add tests for:

1. **Job deletes expired internal tokens**
2. **Job does not delete non-expired internal tokens**
3. **Job does not delete external tokens**

## Security Considerations

Ephemeral internal tokens provide defense in depth:
- **Temporal:** Token only exists during run (1 hour max expiry)
- **Scoped:** Still filtered by default scope (hidden from queries)
- **Capability-restricted:** Still respects capability restrictions
- **Membership-required:** User must still be member of studio
- **Cleanup:** Background job removes any orphaned tokens

## Verification

1. Run existing tests: `./scripts/run-tests.sh test/integration/api_auth_test.rb`
2. Run new tests for internal token bypass and ephemeral lifecycle
3. Manual test:
   - Create internal subagent
   - Run task on studio without API enabled
   - Verify token is created at start, deleted at end
   - Verify no tokens remain after run completes
