# typed: false

require "test_helper"
require "zip"

class UserDataExportServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @tenant.update!(main_collective: @collective) if @tenant.main_collective_id.nil?

    @other_user = create_user(name: "Other User")
    @tenant.add_user!(@other_user)
    @collective.add_user!(@other_user)

    @data_export = DataExport.create!(
      tenant: @tenant,
      collective: @collective,
      user: @user,
      status: "pending",
      export_type: "user",
    )
  end

  test "marks the export completed and attaches a file" do
    UserDataExportService.new(data_export: @data_export).perform!

    @data_export.reload
    assert_equal "completed", @data_export.status
    assert @data_export.file.attached?
    assert @data_export.completed_at.present?
    assert @data_export.expires_at.present?
  end

  test "notes.json includes the subject user's notes and excludes others" do
    my_note = create_note(
      tenant: @tenant, collective: @collective, created_by: @user,
      title: "Mine", text: "by me",
    )
    create_note(
      tenant: @tenant, collective: @collective, created_by: @other_user,
      title: "Theirs", text: "by them",
    )

    UserDataExportService.new(data_export: @data_export).perform!

    notes = read_json_from_zip("notes.json")
    source_ids = notes.map { |n| n["source_id"] }
    assert_includes source_ids, my_note.id
    refute notes.any? { |n| n["title"] == "Theirs" }, "exports another user's note: #{notes.inspect}"
  end

  test "manifest declares export_type as 'user' and identifies the subject" do
    UserDataExportService.new(data_export: @data_export).perform!

    manifest = read_json_from_zip("manifest.json")
    assert_equal "user", manifest["export_type"]
    assert_equal @user.id, manifest["subject"]["user_id"]
    assert_equal @collective.id, manifest["subject"]["collective_id"]
  end

  test "produces a valid ZIP with empty arrays when the user has no activity" do
    # No content created by @user; the only seeded record is the user themself.
    UserDataExportService.new(data_export: @data_export).perform!

    @data_export.reload
    assert_equal "completed", @data_export.status

    notes = read_json_from_zip("notes.json")
    assert_equal [], notes
  end

  test "refuses to run when DataExport.export_type is not 'user'" do
    @data_export.update_columns(export_type: "collective")
    assert_raises(ArgumentError) do
      UserDataExportService.new(data_export: @data_export)
    end
  end

  test "refuses to run when the collective is not the tenant's main collective" do
    other_collective = create_collective(tenant: @tenant, created_by: @user, name: "Other", handle: "other-#{SecureRandom.hex(4)}")
    other_collective.add_user!(@user)
    export = DataExport.create!(
      tenant: @tenant, collective: other_collective, user: @user,
      status: "pending", export_type: "user",
    )
    assert_raises(ArgumentError, /main collective/i) do
      UserDataExportService.new(data_export: export)
    end
  end

  test "refuses to run when the subject user is not a human" do
    ai_agent = create_ai_agent(parent: @user)
    export = DataExport.create!(
      tenant: @tenant, collective: @collective, user: ai_agent,
      status: "pending", export_type: "user",
    )
    assert_raises(ArgumentError, /human/i) do
      UserDataExportService.new(data_export: export)
    end
  end

  private

  def read_json_from_zip(filename)
    assert @data_export.file.attached?, "No file attached to data_export"
    zip_data = @data_export.file.download
    Zip::InputStream.open(StringIO.new(zip_data)) do |io|
      while (entry = io.get_next_entry)
        if entry.name.end_with?("/#{filename}") || entry.name == filename
          return JSON.parse(io.read)
        end
      end
    end
    raise "#{filename} not found in ZIP"
  end
end
