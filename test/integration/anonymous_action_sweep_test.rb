require "test_helper"

# Route-introspection sweep for writes. Iterates every POST route under
# /actions/ and executes it as a caller with no account, on a login-required
# tenant and on a login-optional one. Sibling of
# anonymous_read_access_route_sweep_test.rb, which covers GET.
#
# The invariant: a caller with no account can execute an action only when the
# action is declared anonymous. Any other 2xx is a leak. Adding an anonymous
# action requires three things, all visible in code review:
#   1. `authorization: :anonymous` on its ACTION_DEFINITIONS entry
#   2. `allows_anonymous_actions` in its controller
#   3. An entry in ANONYMOUS_ACTIONS below
#
# The login-optional tenant matters because there is no login redirect there:
# the execute-time gate is the only thing between an anonymous POST and the
# controller.
class AnonymousActionSweepTest < ActionDispatch::IntegrationTest
  LOGIN_REQUIRED_SUBDOMAIN = "anonactrequired".freeze
  LOGIN_OPTIONAL_SUBDOMAIN = "anonactoptional".freeze

  ANONYMOUS_ACTIONS = ["start_agent_signup", "check_agent_signup"].freeze

  # 302 — redirect to /login; 401/403 — refused; 404 — resource not found or
  # feature off; 405/410 as in the GET sweep. A 2xx is a leak and a 5xx is a
  # crash that hides one.
  DENIAL_STATUSES = [302, 401, 403, 404, 405, 410].freeze

  def setup
    @tenants = [LOGIN_REQUIRED_SUBDOMAIN, LOGIN_OPTIONAL_SUBDOMAIN].index_with do |subdomain|
      tenant = Tenant.create!(subdomain: subdomain, name: subdomain)
      user = User.create!(email: "#{subdomain}@example.com", name: subdomain, user_type: "human")
      tenant.add_user!(user)
      tenant.create_main_collective!(created_by: user)
      # Everything on, so a route is never denied merely because its feature is off.
      tenant.enable_api!
      tenant.set_feature_flag!("external_ai_agents", true)
      tenant.set_feature_flag!("agent_signup", true)
      tenant
    end
    optional = @tenants.fetch(LOGIN_OPTIONAL_SUBDOMAIN)
    optional.settings["require_login"] = false
    optional.save!
    assert_not optional.reload.require_login?
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "no anonymous POST executes an action on a login-required tenant, except the declared anonymous actions" do
    assert_sweep_clean(LOGIN_REQUIRED_SUBDOMAIN)
  end

  test "no anonymous POST executes an action on a login-optional tenant, except the declared anonymous actions" do
    assert_sweep_clean(LOGIN_OPTIONAL_SUBDOMAIN)
  end

  test "the sweep covers the declared anonymous actions and many others" do
    names = action_routes.map { |r| r[:action_name] }

    ANONYMOUS_ACTIONS.each { |name| assert_includes names, name }
    assert_operator names.uniq.size, :>, 50
  end

  test "an anonymous POST to a resource-free action creates nothing on a login-optional tenant" do
    host! "#{LOGIN_OPTIONAL_SUBDOMAIN}.#{ENV.fetch("HOSTNAME", nil)}"
    tenant = @tenants.fetch(LOGIN_OPTIONAL_SUBDOMAIN)

    assert_no_difference -> { Note.tenant_scoped_only(tenant.id).count } do
      post "/note/actions/create_note", params: { text: "anonymous write" }, headers: { "Accept" => "text/markdown" }
    end
    assert_includes DENIAL_STATUSES, response.status
  end

  private

  def assert_sweep_clean(subdomain)
    host! "#{subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    leaks = []
    unexpected = []

    action_routes.each do |route|
      next if ANONYMOUS_ACTIONS.include?(route[:action_name])

      begin
        post route[:path], headers: { "Accept" => "text/markdown" }, env: { "REMOTE_ADDR" => fresh_test_ip }
        status = response.status
      rescue ActiveRecord::RecordNotFound
        # Rendered as a 404 outside the test environment: the synthetic
        # collective handle or resource id did not resolve.
        next
      rescue StandardError => e
        unexpected << "  POST #{route[:path]} — raised #{e.class}: #{e.message.lines.first&.strip}"
        next
      end

      line = "  POST #{route[:path]} (#{route[:controller]}##{route[:action]}) — #{status}"
      if (200..299).cover?(status)
        leaks << line
      elsif DENIAL_STATUSES.exclude?(status)
        unexpected << line
      end
    end

    assert_empty leaks, <<~MSG
      Anonymous POST returned 2xx on #{subdomain} for actions NOT declared
      anonymous. Each is either a forgotten gate or needs the three-step
      declaration described at the top of this file:

      #{leaks.join("\n")}
    MSG
    assert_empty unexpected, <<~MSG
      Anonymous POST returned an unexpected status on #{subdomain} (not 2xx,
      not a known denial status #{DENIAL_STATUSES.inspect}). A crash hides
      the write it might have made:

      #{unexpected.join("\n")}
    MSG
  end

  # Every POST route whose path ends in /actions/<name>, with synthetic values
  # for path params.
  def action_routes
    Rails.application.routes.routes.filter_map do |route|
      next unless route.verb.match?("POST")

      spec = route.path.spec.to_s.sub("(.:format)", "")
      match = spec.match(%r{/actions/([a-z_]+)\z})
      next unless match

      {
        path: spec.gsub(/[:*]\w+/, "00000000"),
        action_name: match[1],
        controller: route.defaults[:controller],
        action: route.defaults[:action],
      }
    end
  end

  def fresh_test_ip
    "10.#{rand(1..254)}.#{rand(1..254)}.#{rand(1..254)}"
  end
end
