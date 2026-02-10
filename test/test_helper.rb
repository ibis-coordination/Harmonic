# typed: false
# SimpleCov must be started before any application code is loaded
if ENV['COVERAGE'] || ENV['CI']
  require 'simplecov'
  require 'simplecov-json'

  SimpleCov.start 'rails' do
    # Enable coverage merging for parallel tests
    enable_coverage :branch

    add_filter '/test/'
    add_filter '/config/'
    add_filter '/vendor/'
    add_filter '/db/'

    add_group 'Models', 'app/models'
    add_group 'Controllers', 'app/controllers'
    add_group 'Services', 'app/services'
    add_group 'Helpers', 'app/helpers'
    add_group 'Jobs', 'app/jobs'
    add_group 'Mailers', 'app/mailers'

    # Generate JSON for CI parsing
    SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::JSONFormatter
    ])

    # Minimum coverage threshold - baseline is 47.12%, set slightly below
    minimum_coverage line: 45, branch: 25
  end
end

ENV["RAILS_ENV"] ||= "test"
ENV["MAILER_FROM_ADDRESS"] ||= "test@example.com"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# Allow real connections to localhost for integration tests
WebMock.disable_net_connect!(allow_localhost: true)

# Check AUTH_MODE - Ruby tests require oauth mode
if ENV["AUTH_MODE"] != "oauth"
  raise <<~ERROR
    ❌ Ruby tests require AUTH_MODE=oauth, but AUTH_MODE=#{ENV["AUTH_MODE"].inspect} is set.

    The Ruby test suite expects OAuth authentication mode. Please:
    1. Set AUTH_MODE: export AUTH_MODE=oauth
    2. Restart the app: ./scripts/stop.sh && ./scripts/start.sh

    Note: E2E tests currently require AUTH_MODE=honor_system, so you may need to switch modes.
  ERROR
end

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  # Note: When running with COVERAGE=true, consider using workers: 1 for accurate results
  parallelize(workers: ENV['COVERAGE'] ? 1 : :number_of_processors)

  # Note: No fixtures loaded - we create test data programmatically
  # fixtures :all  # Removed - no fixture YAML files exist

  setup do
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope
    @global_tenant = Tenant.create!(subdomain: "global", name: "Global Tenant")
    @global_user = User.create!(email: "global_user@example.com", name: "Global User", user_type: "human")
    @global_tenant.add_user!(@global_user)
    @global_tenant.create_main_superagent!(created_by: @global_user)
    @global_superagent = Superagent.create!(tenant: @global_tenant, created_by: @global_user, name: "Global Studio", handle: "global-studio")
    @global_superagent.add_user!(@global_user)
  end

  # Clear thread-local state between tests
  teardown do
    Superagent.clear_thread_scope
    Tenant.clear_thread_scope
    AiAgentTaskRun.clear_thread_scope
  end

  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "human")
    User.create!(email: email, name: name, user_type: user_type)
  end

  def create_superagent(tenant:, created_by:, name: "Test Studio", handle: "test-studio")
    Superagent.create!(tenant: tenant, created_by: created_by, name: name, handle: handle)
  end
  alias_method :create_studio, :create_superagent

  def create_note(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Test Note", text: "This is a test note.", commentable: nil)
    Note.create!(tenant: tenant, superagent: superagent, created_by: created_by, title: title, text: text, deadline: Time.current + 1.week, commentable: commentable)
  end

  def create_decision(tenant: @tenant, superagent: @superagent, created_by: @user, question: "Test Decision?", description: "This is a test decision.")
    Decision.create!(tenant: tenant, superagent: superagent, created_by: created_by, question: question, description: description, deadline: Time.current + 1.week, options_open: true)
  end

  def create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user, title: "Test Commitment", description: "This is a test commitment.")
    Commitment.create!(tenant: tenant, superagent: superagent, created_by: created_by, title: title, description: description, critical_mass: 1, deadline: Time.current + 1.week)
  end

  def create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision:, title: "Test Option")
    decision_participant = DecisionParticipantManager.new(decision: decision, user: created_by).find_or_create_participant
    Option.create!(tenant: tenant, superagent: superagent, decision_participant: decision_participant, decision: decision, title: title)
  end

  def create_tenant_superagent_user
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    superagent = create_superagent(tenant: tenant, created_by: user)
    superagent.add_user!(user)
    [tenant, superagent, user]
  end
  alias_method :create_tenant_studio_user, :create_tenant_superagent_user

  # Creates a ai_agent user with the given parent
  # AiAgents authenticate via API tokens generated by their parent
  # Note: This sets tenant context temporarily because ai_agent creation triggers
  # the create_parent_trustee_grant! callback which requires tenant context
  def create_ai_agent(parent:, name: "Test AiAgent")
    # Infer tenant from parent's tenant_user association
    parent_tenant_user = parent.tenant_users.first
    raise "Parent user must belong to a tenant to create a ai_agent" unless parent_tenant_user

    tenant = parent_tenant_user.tenant
    previous_tenant_id = Tenant.current_id

    begin
      Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
      User.create!(
        email: "#{SecureRandom.uuid}@not-a-real-email.com",
        name: name,
        user_type: "ai_agent",
        parent_id: parent.id,
      )
    ensure
      # Restore previous tenant context (or clear if there wasn't one)
      if previous_tenant_id
        prev_tenant = Tenant.unscoped.find(previous_tenant_id)
        Tenant.scope_thread_to_tenant(subdomain: prev_tenant.subdomain)
      else
        Tenant.clear_thread_scope
      end
    end
  end

  # Creates a representation session for a user acting on behalf of a superagent
  # The representative must have can_represent? permission on the superagent
  def create_representation_session(
    tenant:,
    superagent:,
    representative:,
    confirmed_understanding: true,
    began_at: Time.current
  )
    RepresentationSession.create!(
      tenant: tenant,
      superagent: superagent,
      representative_user: representative,
      confirmed_understanding: confirmed_understanding,
      began_at: began_at,
    )
  end

  # Creates a trustee permission allowing trustee_user to act on behalf of granting_user
  # Note: This feature is scaffolded but not actively used in production
  def create_trustee_grant(
    tenant: nil,
    granting_user:,
    trustee_user:,
    permissions: {},
    studio_scope: { "mode" => "all" },
    expires_at: nil,
    accepted: false
  )
    permission = TrusteeGrant.create!(
      tenant: tenant,
      granting_user: granting_user,
      trustee_user: trustee_user,
      permissions: permissions,
      studio_scope: studio_scope,
      expires_at: expires_at,
    )
    permission.accept! if accepted
    permission
  end

  # Creates a representation session for a user acting via a trustee grant
  # (as opposed to a studio trustee). User representation sessions do NOT have
  # a superagent - only studio representation sessions have superagent.
  def create_trustee_grant_representation_session(
    tenant:,
    trustee_grant:,
    confirmed_understanding: true,
    began_at: Time.current
  )
    RepresentationSession.create!(
      tenant: tenant,
      superagent: nil,
      representative_user: trustee_grant.trustee_user,
      trustee_grant: trustee_grant,
      confirmed_understanding: confirmed_understanding,
      began_at: began_at,
    )
  end

end

# Integration test helpers for controller tests
class ActionDispatch::IntegrationTest
  # Sign in a user for integration tests
  # In integration tests, we need to simulate the login process
  # The app checks session[:user_id] for authentication
  #
  # This helper uses the honor_system login endpoint which is simpler.
  # If AUTH_MODE is 'oauth', this will still work because we bypass the
  # check_honor_system_auth_enabled filter by setting session directly
  # through a workaround.
  def sign_in_as(user, tenant: nil)
    tenant ||= @tenant || @global_tenant

    # Ensure user is member of tenant
    unless tenant.tenant_users.exists?(user: user)
      tenant.add_user!(user)
    end

    # Set host for the request
    host! "#{tenant.subdomain}.#{ENV['HOSTNAME']}"

    # Use the session directly through the integration test's session helper
    # In Rails 5+, we can use `get` or `post` to set up session state
    # by accessing the session after a request is made
    if ENV['AUTH_MODE'] == 'honor_system'
      post "/login", params: { email: user.email }
    else
      # For OAuth mode, we need a workaround since we can't easily simulate OAuth
      # We'll use a test-only endpoint or manipulate cookies directly
      # For now, use the encrypted token approach that works with the internal callback
      # Note: Must match the key derivation in ApplicationController#encryptor
      derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                      .generate_key("cross_subdomain_token", 32)
      crypt = ActiveSupport::MessageEncryptor.new(derived_key)
      timestamp = Time.current.to_i
      token = crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{timestamp}")
      cookies[:token] = token
      get "/login/callback"
    end
  end
end
