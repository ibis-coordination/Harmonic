# Create Test Fixture

Help create test fixtures with proper multi-tenant context.

## Usage

- `/create-fixture` - Interactive fixture creation
- `/create-fixture note` - Create a Note fixture
- `/create-fixture decision` - Create a Decision fixture
- `/create-fixture commitment` - Create a Commitment fixture

## Instructions

1. This codebase uses subdomain-based multi-tenancy. All fixtures need proper tenant context.

2. Parse `$ARGUMENTS` to determine what type of fixture to create

3. Use the test helpers defined in `test/test_helper.rb`:
   - `create_tenant_studio_user` - Creates a tenant, studio, and user together
   - `create_note(author:, studio:)` - Creates a Note
   - `create_decision(author:, studio:)` - Creates a Decision
   - `create_commitment(author:, studio:)` - Creates a Commitment

4. Show example fixture code based on what the user needs

## Example Patterns

```ruby
# Basic setup - creates tenant, studio, and user
tenant, studio, user = create_tenant_studio_user

# Create a note
note = create_note(author: user, studio: studio)

# Create a decision
decision = create_decision(author: user, studio: studio)

# Create a commitment
commitment = create_commitment(author: user, studio: studio)

# For integration tests, sign in with tenant context
sign_in_as(user, tenant: tenant)
```

## Multi-Tenancy Notes

- `Tenant.current_id` and `Studio.current_id` are set via thread-local variables
- Models use `default_scope { where(tenant_id: Tenant.current_id, studio_id: Studio.current_id) }`
- New records auto-populate `tenant_id` and `studio_id` via `before_validation`
