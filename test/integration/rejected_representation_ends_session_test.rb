require "test_helper"

# Regression for #485.
#
# When the browser representation resolver REJECTS a session (expired, bad
# representing credential, etc.) it calls clear_representation!, which drops the
# cookies ("kicks the representative out") and reverts current_user to the human.
# But clear_representation!'s `@current_representation_session&.end!` is a no-op
# on the rejection path: that ivar is only assigned on the SUCCESS path
# (apply_representation_session!). So a rejected session's DB row was left
# perpetually `active?` — "kicks the representative out ... but does not actually
# end the representation session" — while the request silently proceeded as the
# human (so anything they posted was attributed to them, not the collective).
#
# resolve_browser_representation now ends the rejected session (when this human
# owns it) before clearing the cookie.
class RejectedRepresentationEndsSessionTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "rep485-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @tenant.add_user!(@alice)
    mark_activated!(@alice)
    @tenant.create_main_collective!(created_by: @alice)
    @collective = create_collective(tenant: @tenant, created_by: @alice,
                                     handle: "rep485-col-#{SecureRandom.hex(4)}")
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

  test "a rejected browser representation session is ended in the DB, not left active" do
    sign_in_as(@alice, tenant: @tenant)
    rep_session = start_representing_collective
    assert rep_session&.active?, "precondition: collective representation session is active"

    # Force a rejection on the next request without ending the session ourselves:
    # push began_at past SESSION_LIFETIME so the resolver's `expired?` check fires.
    rep_session.update_columns(began_at: 2.hours.ago)

    get "/"
    assert_response :success

    rep_session.reload
    assert_nil session[:representation_session_id],
      "representation cookie should be cleared on rejection"
    assert rep_session.ended?,
      "a rejected browser representation must be ended in the DB (issue #485), " \
      "so it stops showing as an active session"
  end
end
