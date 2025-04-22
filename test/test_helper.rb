ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  setup do
    Studio.clear_thread_scope
    Tenant.clear_thread_scope
    @global_tenant = Tenant.create!(subdomain: "global", name: "Global Tenant")
    @global_user = User.create!(email: "global_user@example.com", name: "Global User", user_type: "person")
    @global_tenant.add_user!(@global_user)
    @global_studio = Studio.create!(tenant: @global_tenant, created_by: @global_user, name: "Global Studio", handle: "global-studio")
    @global_studio.add_user!(@global_user)
  end

  teardown do
    Studio.clear_thread_scope
    Tenant.clear_thread_scope
    Tenant.update_all(main_studio_id: nil) # Needed to avoid foreign key violation when deleting studios
    [
      # Note: order matters in this array. "Dependent destroy" doesn't always work for some reason (TODO debug),
      # so it's necessary to manually delete association records first, before the referenced records, to avoid foreign key violations.
      RepresentationSessionAssociation, RepresentationSession,
      Link, NoteHistoryEvent, Note,
      Approval, Option, DecisionParticipant, Decision,
      CommitmentParticipant, Commitment,
      StudioInvite, StudioUser, Studio,
      ApiToken, TenantUser, Tenant,
      TrusteePermission, OauthIdentity, User
    ].each do |model|
      model.unscoped { model.delete_all }
    end
  end

  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test User", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  def create_studio(tenant:, created_by:, name: "Test Studio", handle: "test-studio")
    Studio.create!(tenant: tenant, created_by: created_by, name: name, handle: handle)
  end

  def create_note(tenant: @tenant, studio: @studio, created_by: @user, title: "Test Note", text: "This is a test note.")
    Note.create!(tenant: tenant, studio: studio, created_by: created_by, title: title, text: text)
  end

  def create_tenant_studio_user
    tenant = create_tenant
    user = create_user
    tenant.add_user!(user)
    studio = create_studio(tenant: tenant, created_by: user)
    studio.add_user!(user)
    [tenant, studio, user]
  end

end
