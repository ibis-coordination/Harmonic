# frozen_string_literal: true

require "test_helper"

# How a declared electorate is reported back: JSON, markdown, and the decision
# page. Disclosure is deliberate — someone who cannot vote is told the decision
# is restricted, not who is in the electorate.
class DecisionEligibilityReadSurfacesTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Readable?", description: "A decision with a rule to report",
      deadline: 1.week.from_now
    )
    @alice = make_member("alice")
    @bob = make_member("bob")
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def make_member(suffix)
    user = create_user(email: "r-#{suffix}-#{SecureRandom.hex(4)}@example.com", name: "R #{suffix}")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user
  end

  def scoped
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    yield
  ensure
    Collective.clear_thread_scope
    Tenant.clear_thread_scope
  end

  def restrict_voting_to(*users)
    scoped do
      Decision.find(@decision.id).update!(voter_eligibility: {
        "any_of" => [{ "type" => "users", "user_ids" => users.map(&:id) }],
      })
    end
  end

  # ---- api_json ----

  test "api_json reports both rules" do
    restrict_voting_to(@alice)
    json = scoped { Decision.find(@decision.id).api_json }

    assert_equal({ "any_of" => [{ "type" => "users", "user_ids" => [@alice.id] }] },
                 json[:voter_eligibility])
    assert_equal({ "any_of" => [{ "type" => "open" }] }, json[:proposer_eligibility])
  end

  # ---- markdown ----

  test "markdown omits eligibility rows when both rules are open" do
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
        headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/eligible to vote/i, response.body)
  end

  test "markdown names the electorate to an ineligible reader" do
    restrict_voting_to(@alice)
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
        headers: { "Accept" => "text/markdown" }

    assert_response :success
    # An electorate you cannot see is one you cannot contest, and every clause
    # type references data this reader can already see.
    assert_match(/#{Regexp.escape(@alice.name)}/, response.body)
    assert_match(/not eligible/i, response.body)
  end

  test "the decision page names the electorate to someone outside it" do
    restrict_voting_to(@alice)
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/#{Regexp.escape(@alice.name)}/, response.body)
  end

  test "a lottery does not claim a voting restriction" do
    lottery = scoped do
      Decision.create!(tenant: @tenant, collective: @collective, created_by: @user,
                       subtype: "lottery", question: "Draw?", deadline: 1.week.from_now)
    end
    sign_in_as(@bob, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{lottery.truncated_id}",
        headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_no_match(/eligible to vote/i, response.body)
  end

  test "markdown tells an eligible reader they can vote" do
    restrict_voting_to(@alice)
    sign_in_as(@alice, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}",
        headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/eligible to vote/i, response.body)
  end

  test "the settings markdown page shows both rules in full" do
    restrict_voting_to(@alice)
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}/settings",
        headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Who Can Vote/i, response.body)
    assert_match(/Who Can Add Options/i, response.body)
  end

  # ---- decision page ----

  test "the decision page describes the electorate to someone who is in it" do
    restrict_voting_to(@alice)
    sign_in_as(@alice, tenant: @tenant)

    get "/collectives/#{@collective.handle}/d/#{@decision.truncated_id}"

    assert_response :success
    assert_match(/#{Regexp.escape(@alice.name)}/, response.body)
  end
end
