require "test_helper"

class EmailChangeTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = create_user(email: "email-change-#{SecureRandom.hex(4)}@example.com", name: "Email Change User")
    @tenant.add_user!(@user)
    @collective.add_user!(@user)
    @identity = @user.find_or_create_omni_auth_identity!
    @handle = @tenant.tenant_users.find_by(user: @user).handle
    @new_email = "new-email-#{SecureRandom.hex(4)}@example.com"
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # ====================
  # Initiation
  # ====================

  test "initiating email change stores pending_email and hashed token" do
    sign_in_and_reverify!

    patch "/u/#{@handle}/settings/email", params: { email: @new_email }

    @user.reload
    assert_equal @new_email, @user.pending_email
    assert @user.email_confirmation_token.present?, "Should store hashed token"
    assert @user.email_confirmation_sent_at.present?
    # Token should be hashed (64 hex chars = SHA256)
    assert_equal 64, @user.email_confirmation_token.length
  end

  test "initiating email change sends confirmation and security notice emails" do
    sign_in_and_reverify!

    assert_emails 2 do
      patch "/u/#{@handle}/settings/email", params: { email: @new_email }
    end
  end

  test "initiating email change rejects already-taken email" do
    other_user = create_user(email: "taken-#{SecureRandom.hex(4)}@example.com", name: "Other User")
    sign_in_and_reverify!

    patch "/u/#{@handle}/settings/email", params: { email: other_user.email }

    @user.reload
    assert_nil @user.pending_email, "Should not store pending_email for taken address"
  end

  test "initiating email change requires reverification" do
    sign_in_as(@user, tenant: @tenant)

    patch "/u/#{@handle}/settings/email", params: { email: @new_email }

    # Should redirect to reverification, not process the change
    assert_response :redirect
    @user.reload
    assert_nil @user.pending_email
  end

  # ====================
  # Confirmation
  # ====================

  test "confirming with valid token swaps email on User and OmniAuthIdentity" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!

    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    @user.reload
    @identity.reload
    assert_equal @new_email, @user.email
    assert_equal @new_email, @identity.email
    assert_nil @user.pending_email
    assert_nil @user.email_confirmation_token
    assert_nil @user.email_confirmation_sent_at
  end

  test "confirming with expired token is rejected" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!
    @user.update!(email_confirmation_sent_at: 25.hours.ago)

    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    @user.reload
    assert_not_equal @new_email, @user.email, "Email should not change with expired token"
  end

  test "confirming when email was claimed by another user is rejected" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!

    # Another user grabs the email in the meantime
    create_user(email: @new_email, name: "Snatcher")

    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    @user.reload
    assert_not_equal @new_email, @user.email, "Email should not change when already claimed"
  end

  test "confirming twice does not corrupt user email" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!
    old_email = @user.email

    # First click succeeds
    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"
    @user.reload
    assert_equal @new_email, @user.email

    # Second click is harmless
    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"
    @user.reload
    assert_equal @new_email, @user.email, "Email should not be corrupted by double-click"
    assert_nil @user.pending_email
  end

  test "confirming with invalid token is rejected" do
    sign_in_as(@user, tenant: @tenant)
    initiate_email_change!

    get "/u/#{@handle}/settings/email/confirm/bogus-token"

    @user.reload
    assert_not_equal @new_email, @user.email
  end

  test "email change is logged to SecurityAuditLog" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!

    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching = entries.find { |e| e["event"] == "email_changed" && e["email"] == @new_email }
      assert matching, "Expected email_changed event in security audit log"
    end
  end

  # ====================
  # Rate limiting
  # ====================

  test "reverification replay submits successfully without CSRF error" do
    # Set up 2FA before signing in
    identity = @user.find_or_create_omni_auth_identity!
    identity.generate_otp_secret! unless identity.otp_secret.present?
    identity.enable_otp! unless identity.otp_enabled
    totp = ROTP::TOTP.new(identity.otp_secret)

    sign_in_as(@user, tenant: @tenant)

    # PATCH triggers reverification (no fresh timestamp)
    patch "/u/#{@handle}/settings/email", params: { email: @new_email }
    assert_redirected_to "/reverify"
    post "/reverify", params: { code: totp.now }

    # Should redirect to replay page
    assert_redirected_to "/reverify/replay"
    follow_redirect!
    assert_response :success

    # The replay page auto-submits — simulate by submitting the form
    # Extract the form and submit it
    assert_match(/patch/i, response.body)
    assert_match(@new_email, response.body)

    # Actually submit the replayed request (what the auto-submit JS does)
    patch "/u/#{@handle}/settings/email", params: { email: @new_email }

    # Should succeed (redirect to settings), not raise CSRF error
    assert_response :redirect
    @user.reload
    assert_equal @new_email, @user.pending_email
  end

  test "cancel clears pending email" do
    sign_in_as(@user, tenant: @tenant)
    initiate_email_change!

    delete "/u/#{@handle}/settings/email"

    @user.reload
    assert_nil @user.pending_email
    assert_nil @user.email_confirmation_token
    assert_nil @user.email_confirmation_sent_at
  end

  test "cancel without pending email is harmless" do
    sign_in_as(@user, tenant: @tenant)

    delete "/u/#{@handle}/settings/email"

    assert_response :redirect
    @user.reload
    assert_nil @user.pending_email
  end

  test "unauthenticated user can confirm email change via token" do
    raw_token = initiate_email_change!

    # Don't sign in — just click the link (like opening from a different browser)
    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    @user.reload
    assert_equal @new_email, @user.email, "Email should change without login — token is the proof"
    assert_nil @user.pending_email
  end

  # ====================
  # Authorization
  # ====================

  test "another user cannot initiate email change for someone else" do
    other_user = create_user(email: "other-#{SecureRandom.hex(4)}@example.com", name: "Other")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    sign_in_with_reverification(other_user, tenant: @tenant, path: "/u/#{@handle}/settings/email", method: :patch)

    patch "/u/#{@handle}/settings/email", params: { email: "hacked@example.com" }

    assert_response :forbidden
    @user.reload
    assert_nil @user.pending_email
  end

  test "another user cannot cancel someone else's pending email change" do
    initiate_email_change!
    other_user = create_user(email: "other2-#{SecureRandom.hex(4)}@example.com", name: "Other2")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    sign_in_as(other_user, tenant: @tenant)

    delete "/u/#{@handle}/settings/email"

    assert_response :forbidden
    @user.reload
    assert_equal @new_email, @user.pending_email, "Pending email should not be cleared by another user"
  end

  # ====================
  # Validation
  # ====================

  test "invalid email format is rejected" do
    sign_in_and_reverify!

    patch "/u/#{@handle}/settings/email", params: { email: "not-an-email" }

    @user.reload
    assert_nil @user.pending_email
  end

  test "same-as-current email is rejected" do
    sign_in_and_reverify!

    patch "/u/#{@handle}/settings/email", params: { email: @user.email }

    @user.reload
    assert_nil @user.pending_email
  end

  test "confirming race condition clears stale pending state" do
    sign_in_as(@user, tenant: @tenant)
    raw_token = initiate_email_change!

    create_user(email: @new_email, name: "Snatcher")

    get "/u/#{@handle}/settings/email/confirm/#{raw_token}"

    @user.reload
    assert_not_equal @new_email, @user.email
    assert_nil @user.pending_email, "Stale pending email should be cleared"
    assert_nil @user.email_confirmation_token, "Stale token should be cleared"
  end

  # ====================
  # Overwrite
  # ====================

  test "second email change overwrites the first pending email" do
    sign_in_and_reverify!

    first_email = "first-#{SecureRandom.hex(4)}@example.com"
    second_email = "second-#{SecureRandom.hex(4)}@example.com"

    patch "/u/#{@handle}/settings/email", params: { email: first_email }
    @user.reload
    assert_equal first_email, @user.pending_email

    patch "/u/#{@handle}/settings/email", params: { email: second_email }
    @user.reload
    assert_equal second_email, @user.pending_email, "Second request should overwrite the first pending email"
  end

  private

  # Sign in and complete reverification for the email change scope
  def sign_in_and_reverify!
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@handle}/settings/email", method: :patch)
  end

  # Helper: initiate an email change bypassing reverification, return the raw token
  def initiate_email_change!
    raw_token = SecureRandom.urlsafe_base64(32)
    @user.update!(
      pending_email: @new_email,
      email_confirmation_token: Digest::SHA256.hexdigest(raw_token),
      email_confirmation_sent_at: Time.current,
    )
    raw_token
  end
end
