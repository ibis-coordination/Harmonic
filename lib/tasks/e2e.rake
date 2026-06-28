namespace :e2e do
  desc "Setup test user for E2E tests (idempotent)"
  task setup: :environment do
    e2e_email = ENV.fetch("E2E_TEST_EMAIL", "e2e-test@example.com")
    e2e_password = ENV.fetch("E2E_TEST_PASSWORD", "e2e-test-password-14chars")
    e2e_name = ENV.fetch("E2E_TEST_NAME", "E2E Test User")
    tenant_subdomain = ENV.fetch("PRIMARY_SUBDOMAIN", "app")

    tenant = Tenant.find_by!(subdomain: tenant_subdomain)

    # Enable identity provider
    unless tenant.auth_providers.include?("identity")
      tenant.add_auth_provider!("identity")
      puts "Enabled identity provider for tenant: #{tenant_subdomain}"
    end

    # Create/update OmniAuthIdentity. 2FA must be ENABLED: tenants require
    # 2FA for account activation by default, so a non-OTP user gets stuck on
    # the activation interstitial. The Playwright auth helper passes the
    # verify step with DEV_2FA_BYPASS_CODE (dev-only, see OmniAuthIdentity).
    identity = OmniAuthIdentity.find_or_initialize_by(email: e2e_email)
    identity.name = e2e_name
    identity.password = e2e_password
    identity.password_confirmation = e2e_password
    unless identity.otp_enabled?
      identity.otp_secret = ROTP::Base32.random
      identity.otp_enabled = true
      identity.otp_enabled_at = Time.current
    end
    identity.save!
    puts "OmniAuthIdentity ready: #{e2e_email} (otp_enabled: #{identity.otp_enabled?})"

    # Create/find User
    user = User.find_or_create_by!(email: e2e_email) do |u|
      u.name = e2e_name
      u.user_type = "person"
    end
    puts "User ready: #{user.email} (id: #{user.id})"

    # Add to tenant
    unless tenant.tenant_users.exists?(user: user)
      tenant.add_user!(user)
      puts "Added user to tenant: #{tenant_subdomain}"
    end

    # Add to main collective
    if tenant.main_collective
      unless tenant.main_collective.collective_members.exists?(user: user)
        tenant.main_collective.add_user!(user)
        puts "Added user to main collective: #{tenant.main_collective.name}"
      end
    end

    # Seed a fresh unread notification so the notifications spec has data.
    # Prior seeds are removed first so repeated setup runs stay idempotent.
    if tenant.main_collective
      Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: tenant.main_collective.handle)

      NotificationRecipient
        .where(user: user, tenant: tenant)
        .joins(:notification)
        .where(notifications: { title: "[E2E] You were mentioned" })
        .destroy_all
      Notification
        .where(title: "[E2E] You were mentioned")
        .where.missing(:notification_recipients)
        .destroy_all

      event = Event.create!(tenant: tenant, collective: tenant.main_collective, event_type: "note.created")
      notification = Notification.create!(
        tenant: tenant,
        event: event,
        notification_type: "mention",
        title: "[E2E] You were mentioned",
        body: "Hello from E2E test",
        url: "/help",
      )
      NotificationRecipient.create!(
        notification: notification,
        user: user,
        channel: "in_app",
        status: "delivered",
      )
      Collective.clear_thread_scope
      puts "Seeded unread notification for #{user.email}"
    end

    # Seed a collective + non-expiring open invite for the signup
    # happy-path spec (e2e/tests/auth/signup.spec.ts). The spec registers a
    # brand-new user each run, so the invite must be reusable.
    signup_handle = "e2e-signup"
    signup_collective = Collective.tenant_scoped_only(tenant.id).find_by(handle: signup_handle)
    unless signup_collective
      signup_collective = Collective.create!(
        tenant: tenant,
        created_by: user,
        name: "E2E Signup Collective",
        handle: signup_handle
      )
      signup_collective.add_user!(user)
      puts "Created signup collective: #{signup_handle}"
    end

    invite_code = ENV.fetch("E2E_SIGNUP_INVITE_CODE", "e2e-signup-invite-code")
    invite = Invite.tenant_scoped_only(tenant.id).find_or_initialize_by(
      collective_id: signup_collective.id,
      code: invite_code
    )
    invite.tenant = tenant
    invite.created_by ||= user
    invite.expires_at = 1.year.from_now
    invite.save!
    puts "Signup invite ready: #{invite_code}"

    puts "E2E test user ready: #{e2e_email}"
  end
end
