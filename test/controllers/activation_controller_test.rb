require "test_helper"

class ActivationControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @tenant = create_tenant(subdomain: "act-test-#{SecureRandom.hex(4)}", name: "Activate Test")
    @host = create_user(email: "act-host-#{SecureRandom.hex(4)}@example.com", name: "Activate Host")
    @tenant.add_user!(@host)
    @tenant.create_main_collective!(created_by: @host)
    @collective = create_collective(tenant: @tenant, created_by: @host,
                                    handle: "act-coll-#{SecureRandom.hex(4)}")
    @collective.add_user!(@host)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def sign_in_session(user, tenant: @tenant)
    derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
      .generate_key("cross_subdomain_token", 32)
    crypt = ActiveSupport::MessageEncryptor.new(derived_key)
    token = crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{Time.current.to_i}")
    cookies[:token] = token
    get "/login/callback"
  end

  def with_verified_email_and_2fa(user)
    identity = user.find_or_create_omni_auth_identity!
    identity.update!(email_confirmed_at: Time.current)
    identity.generate_otp_secret!
    identity.enable_otp!
    user
  end

  test "GET /activate redirects unauthenticated visitors to /login" do
    get "/activate"
    assert_response :redirect
    assert_match(%r{/login\b}, response.location)
  end

  test "GET /activate renders the checklist for a logged-in human user" do
    get_user = create_user(email: "act-#{SecureRandom.hex(4)}@example.com", name: "Activatee")
    @tenant.add_user!(get_user)
    @collective.add_user!(get_user)
    sign_in_session(get_user)

    get "/activate"

    assert_response :success
    assert_match(/Activate your account/i, response.body)
    assert_match(/email/i, response.body, "checklist should mention email verification")
    assert_match(/two[- ]?factor/i, response.body, "checklist should mention 2FA")
  end

  test "GET /activate redirects a fully activated user to root (no parking page)" do
    fully = create_user(email: "fully-#{SecureRandom.hex(4)}@example.com", name: "Fully Activated")
    @tenant.add_user!(fully)
    @collective.add_user!(fully)
    with_verified_email_and_2fa(fully)
    sign_in_session(fully)

    get "/activate"

    assert_response :redirect
    assert_match(%r{//[^/]+/?\z}, response.location, "expected redirect to root after activation complete")
  end

  test "GET /activate renders verified email as complete and unenabled 2FA as pending" do
    half = create_user(email: "half-#{SecureRandom.hex(4)}@example.com", name: "Half Activated")
    @tenant.add_user!(half)
    @collective.add_user!(half)
    half.find_or_create_omni_auth_identity!.update!(email_confirmed_at: Time.current)
    # 2FA NOT enabled — so the page still has at least one pending item and will render.
    sign_in_session(half)

    get "/activate"

    assert_response :success
    assert_includes response.body, 'data-activation-state="complete"',
                    "expected the verified email item to be marked complete"
    assert_includes response.body, 'data-activation-state="pending"',
                    "expected the 2FA item to be marked pending"
  end

  test "GET /activate hides email item when require_verified_email is off for tenant" do
    user = create_user(email: "noemail-#{SecureRandom.hex(4)}@example.com", name: "No Email Req")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    @tenant.settings["require_verified_email"] = false
    @tenant.save!
    sign_in_session(user)

    get "/activate"

    assert_response :success
    assert_no_match(/verify your email/i, response.body,
                    "email item should be hidden when the tenant doesn't require verification")
  end

  test "GET /activate hides 2FA item when require_2fa is off for tenant" do
    user = create_user(email: "no2fa-#{SecureRandom.hex(4)}@example.com", name: "No 2FA Req")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    @tenant.settings["require_2fa"] = false
    @tenant.save!
    sign_in_session(user)

    get "/activate"

    assert_response :success
    assert_no_match(/two[- ]?factor/i, response.body,
                    "2FA item should be hidden when the tenant doesn't require 2FA")
  end

  test "POST /activate/send-confirmation enqueues a confirmation email and flashes a notice" do
    user = create_user(email: "resend-#{SecureRandom.hex(4)}@example.com", name: "Resend User")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    sign_in_session(user)

    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      post "/activate/send-confirmation"
    end
    assert_redirected_to activation_path
    follow_redirect!
    assert_match(/confirmation email sent/i, flash[:notice] || response.body)
  end

  test "POST /activate/send-confirmation says already-verified when applicable" do
    user = create_user(email: "ver-#{SecureRandom.hex(4)}@example.com", name: "Already Verified")
    @tenant.add_user!(user)
    @collective.add_user!(user)
    user.find_or_create_omni_auth_identity!.update!(email_confirmed_at: Time.current)
    sign_in_session(user)

    assert_enqueued_jobs 0, only: ActionMailer::MailDeliveryJob do
      post "/activate/send-confirmation"
    end
    assert_match(/already verified/i, flash[:notice].to_s)
  end

  test "GET /activate skips the checklist for sys_admin users" do
    admin = create_user(email: "sysadm-#{SecureRandom.hex(4)}@example.com", name: "Sys Admin")
    @tenant.add_user!(admin)
    @collective.add_user!(admin)
    admin.update!(sys_admin: true)
    sign_in_session(admin)

    get "/activate"

    # Admins are exempt — they shouldn't see the checklist; redirect them out.
    assert_response :redirect
  end
end
