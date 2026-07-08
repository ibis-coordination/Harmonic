# typed: false

require "test_helper"

# Acceptance tests for Harmonic#419 / #454 (representation policy layer).
#
# While a representation session is active, navigating directly to /chat or
# /settings used to drop out of the represented context but leave the session
# *silently still active*. The representative ended up looking at a personal
# surface (or a dead-end 403 / a crash) while the collective's
# representation-sessions list still showed the session running — the confusing
# "in-between" the issue flags.
#
# Root cause: the path/route guard lived inside the *memoized*
# ApplicationController#current_representation_session helper, so once a resolver
# had set @current_representation_session the helper returned early and the
# guard never ran in the browser flow. #454 moves enforcement into a real
# before_action (RepresentationPolicy#enforce_representation_scope!) so no route
# can dodge it.
#
# The representation contract these tests assert:
#   * User representation confines navigation to /collectives/* and
#     /representing; any other top-level route (/chat, /settings) bounces to
#     /representing rather than quietly rendering a personal surface.
#   * Collective representation routes /chat and /settings *through* the session
#     (the collective acts as itself and can edit its public profile), instead
#     of bouncing or crashing.
#
# PR #417 additionally hid the /chat and /settings nav affordances during
# representation; this is the controller-level fix behind that.

# ---------------------------------------------------------------------------
# USER representation: a parent representing their AI-agent user.
# Per #419, /chat and /settings should stay hidden/blocked in this mode.
# ---------------------------------------------------------------------------
class RepresentationUserChatSettingsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @parent = @global_user
    @ai_agent = create_ai_agent(parent: @parent, name: "AiAgent User")
    @tenant.add_user!(@ai_agent)
    @collective.add_user!(@ai_agent)
    @grant = TrusteeGrant.find_by!(granting_user: @ai_agent, trustee_user: @parent)
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def ensure_2fa!(user)
    identity = user.find_or_create_omni_auth_identity!
    unless identity.otp_enabled
      identity.generate_otp_secret!
      identity.enable_otp!
    end
    identity
  end

  def start_representing
    identity = ensure_2fa!(@parent)
    post "/u/#{@ai_agent.handle}/represent"
    if URI.parse(response.location).path == "/reverify"
      totp = ROTP::TOTP.new(identity.otp_secret)
      post "/reverify", params: { code: totp.now }
      post "/u/#{@ai_agent.handle}/represent"
    end
    follow_redirect!
    RepresentationSession.unscoped.find_by(trustee_grant: @grant, representative_user: @parent)
  end

  test "chat during user representation is scoped away instead of rendering a personal surface" do
    sign_in_as(@parent, tenant: @tenant)
    rep_session = start_representing

    get "/chat"

    # Previously (bug): 200 — the chat surface rendered while the session stayed
    # silently active (Repro steps 3-4). Now: representation keeps you scoped,
    # bouncing to /representing.
    assert_redirected_to "/representing",
      "#419: /chat should not render during user representation; it left the " \
      "session silently active (active?=#{rep_session.reload.active?}) while " \
      "showing a chat surface (status #{response.status})."
  end

  test "settings during user representation is scoped away instead of rendering a personal surface" do
    sign_in_as(@parent, tenant: @tenant)
    rep_session = start_representing

    get "/settings"

    # Previously (bug): 302 -> /u/<represented>/settings (a personal settings
    # surface), and the redirect chain dead-ended at 403 with the session still
    # active. Now: scoped to /representing.
    assert_redirected_to "/representing",
      "#419: /settings should not drop to a personal settings surface during " \
      "user representation; the session stayed active (active? " \
      "=#{rep_session.reload.active?}) with the UI implying it had ended."
  end
end

# ---------------------------------------------------------------------------
# COLLECTIVE representation: a member with the representative role acting as the
# collective. Per #419, /settings under a collective session should let the
# collective edit its own public-facing profile (settings *are* only reachable
# via representation for a collective) — and must never leave a stale-but-active
# session behind.
# ---------------------------------------------------------------------------
class RepresentationCollectiveChatSettingsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "rep419-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @tenant.add_user!(@alice)
    mark_activated!(@alice)
    @tenant.create_main_collective!(created_by: @alice)
    @collective = create_collective(tenant: @tenant, created_by: @alice,
                                     handle: "rep419-col-#{SecureRandom.hex(4)}")
    @collective.add_user!(@alice)
    @collective.collective_members.find_by(user: @alice).add_role!("representative")
    host! "#{@tenant.subdomain}.#{ENV.fetch('HOSTNAME', nil)}"
  end

  def ensure_2fa!(user)
    identity = user.find_or_create_omni_auth_identity!
    unless identity.otp_enabled
      identity.generate_otp_secret!
      identity.enable_otp!
    end
    identity
  end

  def start_representing_collective
    identity = ensure_2fa!(@alice)
    post "/collectives/#{@collective.handle}/represent", params: { understand: "1" }
    if response.status == 302 && URI.parse(response.location).path == "/reverify"
      totp = ROTP::TOTP.new(identity.otp_secret)
      post "/reverify", params: { code: totp.now }
      post "/collectives/#{@collective.handle}/represent", params: { understand: "1" }
    end
    follow_redirect! if response.status == 302
    RepresentationSession.unscoped.find_by(collective: @collective, representative_user: @alice)
  end

  test "settings under a collective session reaches the collective's settings without crashing" do
    sign_in_as(@alice, tenant: @tenant)
    rep_session = start_representing_collective
    assert rep_session&.active?, "precondition: collective representation session is active"

    get "/settings"
    # Follow the redirect chain to wherever /settings lands. Previously (bug)
    # this redirected to the collective's settings and then raised
    # NoMethodError: undefined method `is_admin?' for nil — the collective's
    # identity_user has no collective_member, so the collective could not view
    # its own settings while being represented. Now the collective, acting as
    # itself, is authorized to reach its own settings.
    hops = 0
    while response.status.to_s.start_with?("3") && hops < 5
      begin
        follow_redirect!
      rescue => e
        flunk "#419: /settings during collective representation raised " \
              "#{e.class}: #{e.message.to_s.lines.first&.strip} — the collective " \
              "cannot reach its own settings while represented."
      end
      hops += 1
    end

    assert_response :success,
      "#419: a collective should be able to edit its public-facing profile via " \
      "/settings while represented, but got status #{response.status}."
  end

  # NOTE: /chat under a *collective* session currently renders 200 acting as the
  # collective's identity (the "route through the session" behavior the issue
  # leans toward), so it is intentionally NOT asserted here as a failing case.
  # It is captured for context when #419 is picked up.
end
