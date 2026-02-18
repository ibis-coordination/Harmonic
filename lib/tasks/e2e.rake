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

    # Create/update OmniAuthIdentity
    identity = OmniAuthIdentity.find_or_initialize_by(email: e2e_email)
    identity.name = e2e_name
    identity.password = e2e_password
    identity.password_confirmation = e2e_password
    identity.save!
    puts "OmniAuthIdentity ready: #{e2e_email}"

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

    # Add to main studio
    if tenant.main_collective
      unless tenant.main_collective.collective_members.exists?(user: user)
        tenant.main_collective.add_user!(user)
        puts "Added user to main studio: #{tenant.main_collective.name}"
      end
    end

    puts "E2E test user ready: #{e2e_email}"
  end
end
