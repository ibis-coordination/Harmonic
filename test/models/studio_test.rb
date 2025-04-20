require "test_helper"

class StudioTest < ActiveSupport::TestCase
  # Helper methods to create common test objects
  def create_tenant(subdomain: "test", name: "Test Tenant")
    Tenant.create!(subdomain: subdomain, name: name)
  end

  def create_user(email: "#{SecureRandom.hex(8)}@example.com", name: "Test Person", user_type: "person")
    User.create!(email: email, name: name, user_type: user_type)
  end

  test "Studio.create works" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: 'Test Studio',
      handle: 'test',
    )
    assert studio.persisted?
    assert_equal 'Test Tenant', studio.tenant.name
    assert_equal 'Test Person', studio.created_by.name
    assert_equal 'Test Studio', studio.name
    assert_equal 'test', studio.handle
  end

  test "Studio.handle_is_valid validation" do
    tenant = create_tenant
    user = create_user
    begin
      studio = Studio.create!(
        tenant: tenant,
        created_by: user,
        name: "Invalid Handle Studio",
        handle: "invalid handle!" # Invalid handle
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /handle must be alphanumeric with dashes/, e.message.downcase
    end
  end

  test "Studio.creator_is_not_trustee validation" do
    tenant = create_tenant
    trustee_user = create_user(user_type: "trustee")
    begin
      studio = Studio.create!(
        tenant: tenant,
        created_by: trustee_user,
        name: "Trustee Studio",
        handle: "trustee-studio"
      )
    rescue ActiveRecord::RecordInvalid => e
      assert_match /created by cannot be a trustee/, e.message.downcase
    end
  end

  test "Studio.set_defaults sets default settings" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Default Settings Studio",
      handle: "default-settings"
    )
    assert studio.settings["unlisted"]
    assert studio.settings["invite_only"]
    assert_equal "UTC", studio.settings["timezone"]
    assert_equal "daily", studio.settings["tempo"]
  end

  test "Studio.handle_available? returns true for available handle" do
    assert Studio.handle_available?("unique-handle")
  end

  test "Studio.handle_available? returns false for taken handle" do
    tenant = create_tenant
    user = create_user
    Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Existing Studio",
      handle: "existing-handle"
    )
    assert_not Studio.handle_available?("existing-handle")
  end

  test "Studio.create_trustee! creates a trustee user" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Trustee Studio",
      handle: "trustee-studio"
    )
    assert studio.trustee_user.present?
    assert_equal "trustee", studio.trustee_user.user_type
  end

  test "Studio.within_file_upload_limit? returns true when usage is below limit" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "File Upload Studio",
      handle: "file-upload"
    )
    assert studio.within_file_upload_limit?
  end

  test "Studio.add_user! adds a user to the studio" do
    tenant = create_tenant
    user = create_user
    new_user = create_user(name: "New User")
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Team Studio",
      handle: "team-studio"
    )
    assert_not studio.user_is_member?(new_user)
    studio.add_user!(new_user)
    assert studio.user_is_member?(new_user)
  end

  test "Studio.is_main_studio? returns true for main studio" do
    tenant = create_tenant
    user = create_user
    tenant.create_main_studio!(created_by: user)
    studio = tenant.main_studio
    assert studio.is_main_studio?
  end

  test "Studio.is_main_studio? returns false for non-main studio" do
    tenant = create_tenant
    user = create_user
    studio = Studio.create!(
      tenant: tenant,
      created_by: user,
      name: "Non-Main Studio",
      handle: "non-main-studio"
    )
    assert_not studio.is_main_studio?
  end
end
