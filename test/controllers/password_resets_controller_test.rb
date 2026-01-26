require "test_helper"

class PasswordResetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Use the auth subdomain
    host! "#{ENV.fetch("AUTH_SUBDOMAIN", nil)}.#{ENV.fetch("HOSTNAME", nil)}"

    @identity = OmniAuthIdentity.create!(
      email: "test@example.com",
      name: "Test User",
      password: "verylongpassword123",
      password_confirmation: "verylongpassword123"
    )
  end

  test "should get new password reset form" do
    get new_password_reset_path
    assert_response :success
    assert_select "input[type=email]"
  end

  test "should create password reset token and send email" do
    assert_emails 1 do
      post password_resets_path, params: { email: @identity.email }
    end

    @identity.reload
    assert_not_nil @identity.reset_password_token
    assert_not_nil @identity.reset_password_sent_at
    assert_redirected_to new_password_reset_path
    assert_match(/password reset instructions/i, flash[:notice])
  end

  test "should not reveal if email doesn't exist" do
    assert_emails 0 do
      post password_resets_path, params: { email: "nonexistent@example.com" }
    end

    assert_redirected_to new_password_reset_path
    assert_match(/if an account with that email exists/i, flash[:notice])
  end

  test "should show password reset form with valid token" do
    @identity.generate_reset_password_token!

    get password_reset_path(@identity.reset_password_token)
    assert_response :success
    assert_select "input[type=password]", count: 2
  end

  test "should redirect expired token to new password reset" do
    @identity.generate_reset_password_token!
    @identity.update!(reset_password_sent_at: 3.hours.ago)

    get password_reset_path(@identity.reset_password_token)
    assert_redirected_to new_password_reset_path
    assert_match(/expired or is invalid/i, flash[:alert])
  end

  test "should update password with valid token and password" do
    @identity.generate_reset_password_token!

    patch password_reset_path(@identity.reset_password_token), params: {
      password: "newverylongpassword123",
      password_confirmation: "newverylongpassword123",
    }

    @identity.reload
    assert_nil @identity.reset_password_token
    assert_nil @identity.reset_password_sent_at
    assert_redirected_to "/login"
    assert_match(/password has been updated/i, flash[:notice])
  end

  test "should not update password if passwords don't match" do
    @identity.generate_reset_password_token!

    patch password_reset_path(@identity.reset_password_token), params: {
      password: "newverylongpassword123",
      password_confirmation: "differentpassword",
    }

    assert_response :success
    assert_match(/must match/i, flash[:alert])
  end

  test "should not update password if too short" do
    @identity.generate_reset_password_token!

    patch password_reset_path(@identity.reset_password_token), params: {
      password: "short",
      password_confirmation: "short",
    }

    assert_response :success
    assert_match(/at least 14 characters/i, flash[:alert])
  end

  # === Security Audit Logging Tests ===
  #
  # Note: These tests verify that security events are logged by checking the log file.
  # Since tests may run in parallel, we parse individual JSON entries and look for
  # entries matching our specific test data, rather than truncating and checking the whole file.

  test "password reset request logs security audit event" do
    test_email = @identity.email

    post password_resets_path, params: { email: test_email }

    assert_redirected_to new_password_reset_path

    # Verify password reset request was logged by parsing JSON entries
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "password_reset_requested" && e["email"] == test_email
      end
      assert matching_entry, "Expected to find password_reset_requested event for #{test_email}"
    end
  end

  test "password reset request logs audit event even for non-existent email" do
    test_email = "nonexistent-#{SecureRandom.hex(4)}@example.com"

    post password_resets_path, params: { email: test_email }

    assert_redirected_to new_password_reset_path

    # Should still log the attempt for security monitoring
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "password_reset_requested" && e["email"] == test_email
      end
      assert matching_entry, "Expected to find password_reset_requested event for #{test_email}"
    end
  end

  test "successful password update logs security audit event" do
    # Create a user with the same email as the identity
    # The controller looks up the user by email to log the password change
    @tenant = Tenant.create!(subdomain: "pwreset", name: "Password Reset Tenant")
    @user = User.create!(email: @identity.email, name: "Test User", user_type: "person")
    @tenant.add_user!(@user)

    @identity.generate_reset_password_token!
    test_email = @identity.email

    patch password_reset_path(@identity.reset_password_token), params: {
      password: "newverylongpassword123",
      password_confirmation: "newverylongpassword123",
    }

    assert_redirected_to "/login"

    # Verify password change was logged
    log_file = Rails.root.join("log/security_audit.log")
    if File.exist?(log_file)
      entries = File.readlines(log_file).map { |line| JSON.parse(line) rescue nil }.compact
      matching_entry = entries.find do |e|
        e["event"] == "password_changed" && e["email"] == test_email
      end
      assert matching_entry, "Expected to find password_changed event for #{test_email}"
    end
  end
end
