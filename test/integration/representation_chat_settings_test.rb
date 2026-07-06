# typed: false

require "test_helper"

# FAILING-TEST REPRO for Harmonic#419.
#
# While a representation session is active, navigating directly to /chat or
# /settings drops out of the represented context but leaves the session
# *silently still active*. The representative ends up looking at a personal
# surface (or a dead-end 403 / a crash) while the collective's
# representation-sessions list still shows the session running — the confusing
# "in-between" the issue flags.
#
# PR #417 hid the /chat and /settings *nav affordances* during representation so
# users are far less likely to stumble into this, but intentionally did NOT
# change controller behavior. #419 tracks the controller-level fix. Dan asked for
# a draft PR with failing tests only, as a starting point for whenever we return
# to it — so these tests are EXPECTED TO FAIL against current `main`.
#
# What they assert is the *existing* representation contract, stated in
# ApplicationController#current_representation_session (application_controller.rb):
#
#     "Representation session should always be scoped to a collective or the
#      /representing page."
#
# i.e. an active session should confine navigation to /collectives/* and
# /representing; any other top-level route should bounce to /representing rather
# than quietly render a personal surface. That guard is a lazily-evaluated helper
# and never fires in the browser flow, which is the root of #419.
#
# NOTE ON THE EVENTUAL FIX: the issue leans toward routing /chat and /settings
# *through* a COLLECTIVE session (act as the collective) rather than simply
# bouncing to /representing. When that decision lands, the collective-side
# expectations below should be revisited. The USER-representation cases
# (chat/settings should stay blocked) are unambiguous.

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

    # Actual on main: 200 — the chat surface renders while the session stays
    # silently active (Repro steps 3-4). Expected: representation keeps you
    # scoped, bouncing to /representing.
    assert_redirected_to "/representing",
      "#419: /chat should not render during user representation; it left the " \
      "session silently active (active?=#{rep_session.reload.active?}) while " \
      "showing a chat surface (status #{response.status})."
  end

  test "settings during user representation is scoped away instead of rendering a personal surface" do
    sign_in_as(@parent, tenant: @tenant)
    rep_session = start_representing

    get "/settings"

    # Actual on main: 302 -> /u/<represented>/settings (a personal settings
    # surface), and the redirect chain dead-ends at 403 with the session still
    # active. Expected: scoped to /representing.
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
    # Follow the redirect chain to wherever /settings lands. On main this
    # redirects to the collective's settings and then raises
    # NoMethodError: undefined method `is_admin?' for nil — the collective's
    # identity_user has no collective_member, so the collective can't actually
    # view its own settings while being represented.
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
