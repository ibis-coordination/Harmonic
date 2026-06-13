require "test_helper"

class SignupControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

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
    # callback should set session and redirect to /invite-required for uninvited users
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

  # === GET /invite-required ===

  test "GET /invite-required renders the explainer page for a signed-in non-member" do
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :success
    assert_select "h1", text: /invite/i
    assert_select "form[action='/invite-required']"
    assert_select "input[name='code']"
    # Tenant name should appear so the user knows where they tried to join
    assert_match(/#{Regexp.escape(@tenant.name)}/, response.body)
  end

  test "GET /invite-required hides the app header (non-members shouldn't see tenant chrome)" do
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :success
    assert_select "header.pulse-top-header", false,
                  "expected app header to be hidden for users without tenant access"
  end

  test "GET /invite-required redirects to root when user is already a tenant member" do
    @tenant.add_user!(@uninvited_user)
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :redirect
    assert_match(%r{^/$|/$}, URI.parse(response.location).path)
  end

  test "GET /invite-required redirects to /login when user is not authenticated" do
    get "/invite-required"

    assert_response :redirect
    assert_match(/login/, response.location)
  end

  test "GET /invite-required is not redirected to /billing when stripe_billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :success
    assert_no_match(%r{/billing}, response.body)
  end

  # === GET /invite-required with a code (confirmation entry point) ===
  # The login callback and invite links route here with ?code= so the user
  # reviews what they're joining without re-typing the code.

  test "GET /invite-required?code=valid renders the confirmation page directly" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    get "/invite-required", params: { code: invite.code }

    assert_response :success
    assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                 "expected confirmation page naming the collective")
    assert_select ".inline-avatar", { minimum: 1 },
                  "expected the collective's avatar so the user can see what they're joining"
    assert_select "form[action='/invite-required/accept']"
    assert_select "input[type='hidden'][name='code'][value='#{invite.code}']"
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "rendering the confirmation page must not create memberships"
  end

  test "GET /invite-required renders the confirmation page from a pending invite in the session" do
    invite = create_invite
    # The callback consumes the invite cookie into the per-tenant session stash.
    cookies[:collective_invite_code] = invite.code
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :success
    assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                 "expected the pending session invite to surface the confirmation page")
    assert_select "form[action='/invite-required/accept']"
  end

  test "GET /invite-required?code=invalid falls back to the landing form" do
    sign_in_without_membership(@uninvited_user)

    get "/invite-required", params: { code: "bogus-#{SecureRandom.hex(4)}" }

    assert_response :success
    assert_select "form[action='/invite-required']",
                  true, "expected the code-entry landing form for an unusable code"
  end

  test "GET /invite-required with expired pending session invite falls back to the landing form" do
    invite = create_invite(expires_at: 1.week.from_now)
    cookies[:collective_invite_code] = invite.code
    sign_in_without_membership(@uninvited_user)
    invite.update!(expires_at: 1.day.ago) # expires after login, before confirmation

    get "/invite-required"

    assert_response :success
    assert_select "form[action='/invite-required']"
  end

  # === Markdown variants (dual interface) ===
  # The invite-link path used to render collectives/join.md.erb for markdown
  # clients; the explicit-acceptance flow routes them here instead, so these
  # pages must not be HTML-only dead ends.

  test "GET /invite-required renders markdown for markdown clients" do
    sign_in_without_membership(@uninvited_user)

    get "/invite-required", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert response.content_type.start_with?("text/markdown"),
           "expected a markdown response, got #{response.content_type}"
    assert_match(/invite code/i, response.body)
  end

  test "GET /invite-required?code=valid renders the markdown confirmation for markdown clients" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    get "/invite-required", params: { code: invite.code }, headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert response.content_type.start_with?("text/markdown")
    assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                 "expected the markdown confirmation to name the collective")
  end

  # === Handle selection on the confirmation page ===

  test "confirmation page shows a handle input prefilled with the name-derived default" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    get "/invite-required", params: { code: invite.code }

    assert_response :success
    assert_select "input[name='handle'][value='uninvited-user']",
                  true, "expected an editable handle field prefilled from the user's name"
  end

  test "POST /invite-required/accept with a custom handle uses it for the TenantUser" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code, handle: "captain-custom" }

    assert_response :redirect
    tu = @tenant.tenant_users.find_by(user: @uninvited_user)
    assert_equal "captain-custom", tu.handle
  end

  test "POST /invite-required/accept normalizes a free-text handle" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code, handle: "Captain Custom" }

    tu = @tenant.tenant_users.find_by(user: @uninvited_user)
    assert_equal "captain-custom", tu.handle
  end

  test "POST /invite-required/accept with a taken handle re-renders the confirmation page with an error and no memberships" do
    invite = create_invite
    taken = create_user(email: "taken-#{SecureRandom.hex(4)}@example.com", name: "Already Here")
    @tenant.add_user!(taken, handle: "taken-handle")
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code, handle: "taken-handle" }

    assert_response :unprocessable_entity
    assert_match(/taken|already/i, flash[:alert].to_s)
    assert_select "form[action='/invite-required/accept']",
                  true, "expected the confirmation page re-rendered for another attempt"
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "expected the tenant join rolled back"
    assert_not @collective.user_is_member?(@uninvited_user),
               "expected the collective join rolled back"
  end

  test "POST /invite-required/accept with a reserved handle is rejected with a friendly error" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code, handle: "trio" }

    assert_response :unprocessable_entity
    assert_match(/reserved/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /invite-required/accept clears the pending invite code from the session" do
    invite = create_invite
    cookies[:collective_invite_code] = invite.code
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert_nil session[:pending_invite_codes],
               "expected the pending invite session stash consumed on acceptance"
  end

  # === Pricing disclosure (humans are free; no per-user cost to disclose) ===

  test "GET /invite-required does NOT mention pricing even when stripe_billing is enabled" do
    # Humans are free under the current pricing model. The invite landing
    # page should not show a per-account cost — only AI agents and additional
    # collectives carry a charge, surfaced at point of creation.
    @tenant.set_feature_flag!("stripe_billing", true)
    sign_in_without_membership(@uninvited_user)

    get "/invite-required"

    assert_response :success
    assert_no_match(/\$3/, response.body,
                    "joining is free; no price should be quoted on the invite-required page")
  end

  test "POST /invite-required confirmation page does NOT mention pricing even when stripe_billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: invite.code }

    assert_response :success
    assert_no_match(/\$3/, response.body,
                    "joining is free; no price should be quoted on the confirmation page")
  end

  # === POST /invite-required (validate code + render confirmation) ===

  test "POST /invite-required with valid code renders confirmation page without joining anything yet" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)

    post "/invite-required", params: { code: invite.code }

    assert_response :success
    # Confirmation page must name the collective and tenant the user is about to join
    assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                 "expected collective name on confirmation page")
    assert_match(/#{Regexp.escape(@tenant.name)}/, response.body,
                 "expected tenant name on confirmation page")
    # An Accept form posts to the accept endpoint with the code preserved
    assert_select "form[action='/invite-required/accept']"
    assert_select "input[type='hidden'][name='code'][value='#{invite.code}']"
    # Crucially, no joins happened yet — the user is still consenting
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "confirmation step must not create TenantUser"
    assert_not @collective.user_is_member?(@uninvited_user),
               "confirmation step must not create CollectiveMember"
  end

  test "POST /invite-required confirmation page hides the app header" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: invite.code }

    assert_response :success
    assert_select "header.pulse-top-header", false,
                  "expected app header to be hidden on confirmation page"
  end

  test "POST /invite-required with invalid code re-renders form with alert and no membership" do
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: "bogus-code-#{SecureRandom.hex(4)}" }

    assert_response :unprocessable_entity
    assert_select "form[action='/invite-required']"
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /invite-required with expired code re-renders form with alert" do
    invite = create_invite(expires_at: 1.day.ago)
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: invite.code }

    assert_response :unprocessable_entity
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /invite-required with blank code re-renders form with alert" do
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: "" }

    assert_response :unprocessable_entity
    assert_match(/not valid|expired/i, flash[:alert].to_s)
  end

  test "POST /invite-required with code for a different tenant is rejected" do
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

    post "/invite-required", params: { code: other_invite.code }

    assert_response :unprocessable_entity
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /invite-required is not blocked by billing gate" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required", params: { code: invite.code }

    assert_response :success
    assert_no_match(%r{/billing}, response.body)
  end

  # === POST /invite-required/accept (atomic tenant + collective join) ===

  test "POST /invite-required/accept with valid code joins tenant AND collective atomically and redirects" do
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    assert_not @collective.user_is_member?(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert_match(%r{#{Regexp.escape(@collective.path)}/?$}, URI.parse(response.location).path,
                 "expected redirect to the collective homepage")
    assert @tenant.tenant_users.exists?(user: @uninvited_user),
           "expected TenantUser created on accept"
    assert @collective.user_is_member?(@uninvited_user),
           "expected CollectiveMember created on accept"
  end

  test "POST /invite-required/accept with invalid code redirects back with alert and no state changes" do
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: "bogus-#{SecureRandom.hex(4)}" }

    assert_response :redirect
    assert_match(%r{/invite-required$}, response.location)
    assert_match(/not valid|expired/i, flash[:alert].to_s)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    assert_not @collective.user_is_member?(@uninvited_user)
  end

  test "POST /invite-required/accept with expired code rolls back any partial state" do
    invite = create_invite(expires_at: 1.day.ago)
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user),
               "expected no TenantUser created for expired invite"
    assert_not @collective.user_is_member?(@uninvited_user),
               "expected no CollectiveMember created for expired invite"
  end

  test "POST /invite-required/accept rejects code targeting a different tenant" do
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

    post "/invite-required/accept", params: { code: other_invite.code }

    assert_response :redirect
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  test "POST /invite-required/accept is not blocked by billing gate" do
    @tenant.set_feature_flag!("stripe_billing", true)
    invite = create_invite
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert_no_match(%r{/billing}, response.location)
    assert @tenant.tenant_users.exists?(user: @uninvited_user)
    assert @collective.user_is_member?(@uninvited_user)
  end

  test "POST /invite-required/accept still adds user to invite collective when they are already a tenant member" do
    # Race / edge case: user was added to the tenant between the confirm page
    # and the accept post (e.g., by an admin, or a concurrent request).
    # Previously we silently bounced them to root and never joined the
    # invite's collective.
    invite = create_invite
    @tenant.add_user!(@uninvited_user)
    sign_in_without_membership(@uninvited_user)

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert @collective.user_is_member?(@uninvited_user),
           "expected invite collective membership even when tenant membership pre-existed"
  end

  test "POST /invite-required/accept redirects to /login if not authenticated" do
    invite = create_invite

    post "/invite-required/accept", params: { code: invite.code }

    assert_response :redirect
    assert_match(/login/, response.location)
    assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
  end

  # === Bot protection (honeypot + min-time) ===
  # These set FORCE_BOT_PROTECTION_IN_TEST so the BotProtection concern is
  # active. Without the env, the concern is a no-op in test so every other
  # test in this file keeps working without filling the honeypot.

  test "POST /invite-required with filled honeypot redirects without looking up the invite" do
    with_bot_protection do
      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      assert_not @tenant.tenant_users.exists?(user: @uninvited_user)

      post "/invite-required", params: { code: invite.code, company_website: "https://spam.example" }

      assert_response :redirect
      # No "confirm" page rendered, no membership granted, no flash leaking the reason.
      assert_no_match(/#{Regexp.escape(@collective.name)}/, response.body)
      assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    end
  end

  test "POST /invite-required with filled honeypot writes a bot_signal_detected entry to security_audit.log" do
    with_bot_protection do
      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      log_file = Rails.root.join("log/security_audit.log")
      offset = File.exist?(log_file) ? File.readlines(log_file).size : 0

      post "/invite-required", params: { code: invite.code, company_website: "spam" }

      entries = File.readlines(log_file).drop(offset).filter_map do |line|
        JSON.parse(line) rescue nil
      end
      bot_entry = entries.find { |e| e["event"] == "bot_signal_detected" && e["path"] == "/invite-required" }
      refute_nil bot_entry, "expected a bot_signal_detected audit-log entry for the honeypot trip"
      assert_equal "honeypot", bot_entry["reason"]
      assert_equal "warn", bot_entry["severity"]
    end
  end

  test "POST /invite-required submitted faster than MIN_FORM_TIME_SECONDS after render is rejected" do
    with_bot_protection do
      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      freeze_time do
        post "/invite-required", params: {
          code: invite.code,
          form_render_ts: Time.current.to_i.to_s, # rendered "just now" — too fast
        }
      end

      assert_response :redirect
      assert_no_match(/#{Regexp.escape(@collective.name)}/, response.body)
      assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
    end
  end

  test "POST /invite-required with no honeypot fields at all still works (missing timestamp does not penalize)" do
    with_bot_protection do
      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      post "/invite-required", params: { code: invite.code } # no company_website, no form_render_ts

      assert_response :success
      assert_match(/#{Regexp.escape(@collective.name)}/, response.body)
    end
  end

  test "POST /invite-required does NOT call Turnstile even when enabled (post-auth flow uses honeypot only)" do
    with_bot_protection do
      ENV["TURNSTILE_SECRET_KEY"] = "test-secret"
      # If the controller were checking Turnstile, this WebMock would fail the
      # request (always returns success:false). Instead we expect the request
      # to succeed without any Cloudflare call at all.
      WebMock.stub_request(:post, "https://challenges.cloudflare.com/turnstile/v0/siteverify")
        .to_return(status: 200, body: '{"success":false}')

      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      post "/invite-required", params: { code: invite.code }

      assert_response :success
      assert_match(/#{Regexp.escape(@collective.name)}/, response.body,
                   "confirm page should render — Turnstile must not gate this action")
      assert_not_requested(:post, "https://challenges.cloudflare.com/turnstile/v0/siteverify")
    ensure
      ENV.delete("TURNSTILE_SECRET_KEY")
    end
  end

  test "POST /invite-required/accept with filled honeypot does not join tenant" do
    with_bot_protection do
      invite = create_invite
      sign_in_without_membership(@uninvited_user)

      post "/invite-required/accept", params: { code: invite.code, company_website: "spam" }

      assert_response :redirect
      assert_not @tenant.tenant_users.exists?(user: @uninvited_user)
      assert_not @collective.user_is_member?(@uninvited_user)
    end
  end

  private

  def with_bot_protection
    original_force = ENV["FORCE_BOT_PROTECTION_IN_TEST"]
    original_turnstile = ENV["TURNSTILE_SECRET_KEY"]
    ENV["FORCE_BOT_PROTECTION_IN_TEST"] = "1"
    # Isolate from the dev container's ambient TURNSTILE_SECRET_KEY so the
    # base honeypot tests don't accidentally try to call Cloudflare.
    ENV.delete("TURNSTILE_SECRET_KEY")
    yield
  ensure
    if original_force.nil?
      ENV.delete("FORCE_BOT_PROTECTION_IN_TEST")
    else
      ENV["FORCE_BOT_PROTECTION_IN_TEST"] = original_force
    end
    if original_turnstile.nil?
      ENV.delete("TURNSTILE_SECRET_KEY")
    else
      ENV["TURNSTILE_SECRET_KEY"] = original_turnstile
    end
  end
end
