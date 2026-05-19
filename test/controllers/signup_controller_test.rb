require "test_helper"

class SignupControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "signup-test-#{SecureRandom.hex(4)}", name: "Signup Test Tenant")
    @host_user = create_user(email: "host-#{SecureRandom.hex(4)}@example.com", name: "Host")
    @tenant.add_user!(@host_user)
    @tenant.create_main_collective!(created_by: @host_user)
    @collective = create_collective(
      tenant: @tenant,
      created_by: @host_user,
      handle: "signup-test-collective-#{SecureRandom.hex(4)}"
    )
    @collective.add_user!(@host_user)

    @uninvited_user = create_user(email: "uninvited-#{SecureRandom.hex(4)}@example.com", name: "Uninvited User")
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  def sign_in_without_membership(user, tenant: @tenant)
    derived_key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
      .generate_key("cross_subdomain_token", 32)
    crypt = ActiveSupport::MessageEncryptor.new(derived_key)
    timestamp = Time.current.to_i
    token = crypt.encrypt_and_sign("#{tenant.id}:#{user.id}:#{timestamp}")
    cookies[:token] = token
    get "/login/callback"
    # callback should set session and redirect to /needs-invite for uninvited users
  end

  def create_invite(collective: @collective, invited_user: nil, expires_at: 1.week.from_now)
    Invite.create!(
      tenant: @tenant,
      collective: collective,
      created_by: @host_user,
      invited_user: invited_user,
      code: SecureRandom.hex(8),
      expires_at: expires_at
    )
  end

  # === GET /needs-invite ===

  test "GET /needs-invite renders the explainer page for a signed-in non-member" do
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :success
    assert_select "h1", text: /invite/i
    assert_select "form[action='/needs-invite']"
    assert_select "input[name='code']"
    # Tenant name should appear so the user knows where they tried to join
    assert_match(/#{Regexp.escape(@tenant.name)}/, response.body)
  end

  test "GET /needs-invite hides the app header (non-members shouldn't see tenant chrome)" do
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :success
    assert_select "header.pulse-top-header", false,
                  "expected app header to be hidden for users without tenant access"
  end

  test "GET /needs-invite redirects to root when user is already a tenant member" do
    @tenant.add_user!(@uninvited_user)
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :redirect
    assert_match(%r{^/$|/$}, URI.parse(response.location).path)
  end

  test "GET /needs-invite redirects to /login when user is not authenticated" do
    get "/needs-invite"

    assert_response :redirect
    assert_match(/login/, response.location)
  end

  test "GET /needs-invite is not redirected to /billing when stripe_billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :success
    assert_no_match(%r{/billing}, response.body)
  end

  # === Pricing disclosure ===

  test "GET /needs-invite mentions the monthly cost when stripe_billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :success
    assert_match(/\$3/, response.body,
                 "expected price to be disclosed up front on landing page")
    assert_match(/month/i, response.body,
                 "expected billing cadence to be mentioned")
  end

  test "GET /needs-invite does NOT mention pricing when stripe_billing is disabled" do
    # stripe_billing flag not enabled — tenant is free
    sign_in_without_membership(@uninvited_user)

    get "/needs-invite"

    assert_response :success
    assert_no_match(/\$3/, response.body,
                    "free tenants must not show a billing disclosure")
  end

  test "POST /needs-invite confirmation page mentions the monthly cost when stripe_billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :success
    assert_match(/\$3/, response.body,
                 "expected price disclosed on confirmation page so the user can decide before committing")
    assert_match(/month/i, response.body)
  end

  test "POST /needs-invite confirmation page does NOT mention pricing when stripe_billing is disabled" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :success
    assert_no_match(/\$3/, response.body)
  end

  # === POST /needs-invite (validate code + render confirmation) ===

  test "POST /needs-invite with valid code renders confirmation page without joining anything yet" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :success
    # Confirmation page must name the collective and tenant the user is about to join
    assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                 "expected collective name on confirmation page")
    assert_match(/#{Regexp.escape(@tenant.name)}/, response.body,
                 "expected tenant name on confirmation page")
    # An Accept form posts to the accept endpoint with the code preserved
    assert_select "form[action='/needs-invite/accept']"
    assert_select "input[type='hidden'][name='code'][value='#{invite.code}']"
    # Crucially, no joins happened yet — the user is still consenting
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "confirmation step must not create TenantUser"
    assert_not @collective.user_is_member?(@uninvited_user),
               "confirmation step must not create CollectiveMember"
  end

  test "POST /needs-invite confirmation page hides the app header" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :success
    assert_select "header.pulse-top-header", false,
                  "expected app header to be hidden on confirmation page"
  end

  test "POST /needs-invite with invalid code re-renders form with alert and no membership" do
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: "bogus-code-#{SecureRandom.hex(4)}" }

    assert_response :unprocessable_entity
    assert_select "form[action='/needs-invite']"
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /needs-invite with expired code re-renders form with alert" do
    invite = create_invite(expires_at: 1.day.ago)
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :unprocessable_entity
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /needs-invite with blank code re-renders form with alert" do
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: "" }

    assert_response :unprocessable_entity
    assert_match(/not valid|expired/i, flash[:alert].to_s)
  end

  test "POST /needs-invite with code for a different tenant is rejected" do
    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    other_tenant.add_user!(@host_user)
    other_tenant.create_main_collective!(created_by: @host_user)
    other_collective = create_collective(
      tenant: other_tenant,
      created_by: @host_user,
      handle: "other-collective-#{SecureRandom.hex(4)}"
    )
    other_invite = Invite.create!(
      tenant: other_tenant,
      collective: other_collective,
      created_by: @host_user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: other_invite.code }

    assert_response :unprocessable_entity
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /needs-invite is not blocked by billing gate" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite", params: { code: invite.code }

    assert_response :success
    assert_no_match(%r{/billing}, response.body)
  end

  # === POST /needs-invite/accept (atomic tenant + collective join) ===

  test "POST /needs-invite/accept with valid code joins tenant AND collective atomically and redirects" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    assert_not @collective.user_is_member?(@uninvited_user)

    post "/needs-invite/accept", params: { code: invite.code }

    assert_response :redirect
    assert_match(%r{#{Regexp.escape(@collective.path)}/?$}, URI.parse(response.location).path,
                 "expected redirect to the collective homepage")
    assert @tenant.tenant_users.exists?(user: @uninvited_user),
           "expected TenantUser created on accept"
    assert @collective.user_is_member?(@uninvited_user),
           "expected CollectiveMember created on accept"
  end

  test "POST /needs-invite/accept with invalid code redirects back with alert and no state changes" do
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite/accept", params: { code: "bogus-#{SecureRandom.hex(4)}" }

    assert_response :redirect
    assert_match(%r{/needs-invite$}, response.location)
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    assert_not @collective.user_is_member?(@uninvited_user)
  end

  test "POST /needs-invite/accept with expired code rolls back any partial state" do
    invite = create_invite(expires_at: 1.day.ago)
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite/accept", params: { code: invite.code }

    assert_response :redirect
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "expected no TenantUser created for expired invite"
    assert_not @collective.user_is_member?(@uninvited_user),
               "expected no CollectiveMember created for expired invite"
  end

  test "POST /needs-invite/accept rejects code targeting a different tenant" do
    other_tenant = create_tenant(subdomain: "x-#{SecureRandom.hex(4)}", name: "X")
    other_tenant.add_user!(@host_user)
    other_tenant.create_main_collective!(created_by: @host_user)
    other_collective = create_collective(
      tenant: other_tenant,
      created_by: @host_user,
      handle: "x-collective-#{SecureRandom.hex(4)}"
    )
    other_invite = Invite.create!(
      tenant: other_tenant,
      collective: other_collective,
      created_by: @host_user,
      code: SecureRandom.hex(8),
      expires_at: 1.week.from_now
    )

    sign_in_without_membership(@uninvited_user)

    post "/needs-invite/accept", params: { code: other_invite.code }

    assert_response :redirect
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /needs-invite/accept is not blocked by billing gate" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite/accept", params: { code: invite.code }

    assert_response :redirect
    assert_no_match(%r{/billing}, response.location)
    assert @tenant.tenant_users.exists?(user: @uninvited_user)
    assert @collective.user_is_member?(@uninvited_user)
  end

  test "POST /needs-invite/accept still adds user to invite collective when they are already a tenant member" do
    # Race / edge case: user was added to the tenant between the confirm page
    # and the accept post (e.g., by an admin, or a concurrent request).
    # Previously we silently bounced them to root and never joined the
    # invite's collective.
    invite = create_invite
    @tenant.add_user!(@uninvited_user)
    sign_in_without_membership(@uninvited_user)

    post "/needs-invite/accept", params: { code: invite.code }

    assert_response :redirect
    assert @collective.user_is_member?(@uninvited_user),
           "expected invite collective membership even when tenant membership pre-existed"
  end

  test "POST /needs-invite/accept redirects to /login if not authenticated" do
    invite = create_invite

    post "/needs-invite/accept", params: { code: invite.code }

    assert_response :redirect
    assert_match(/login/, response.location)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end
end
