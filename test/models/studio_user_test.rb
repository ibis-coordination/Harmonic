require "test_helper"

class StudioUserTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "studio-user-#{SecureRandom.hex(4)}")
    @user = create_user(email: "studio_user_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @studio = create_studio(tenant: @tenant, created_by: @user, handle: "test-studio-#{SecureRandom.hex(4)}")
    @studio.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @studio_user = @studio.studio_users.find_by(user: @user)
  end

  # === Basic Association Tests ===

  test "studio_user belongs to tenant, studio, and user" do
    assert_equal @tenant, @studio_user.tenant
    assert_equal @studio, @studio_user.studio
    assert_equal @user, @studio_user.user
  end

  # === can_represent? Tests ===

  test "can_represent? returns false by default" do
    assert_not @studio_user.can_represent?
  end

  test "can_represent? returns true with representative role" do
    @studio_user.add_role!('representative')
    assert @studio_user.can_represent?
  end

  test "can_represent? returns true when studio.any_member_can_represent is enabled" do
    @studio.settings['any_member_can_represent'] = true
    @studio.save!
    assert @studio_user.can_represent?
  end

  test "can_represent? returns false when archived even with representative role" do
    @studio_user.add_role!('representative')
    @studio_user.archive!
    assert_not @studio_user.can_represent?
  end

  test "can_represent? returns false when archived even with any_member_can_represent" do
    @studio.settings['any_member_can_represent'] = true
    @studio.save!
    @studio_user.archive!
    assert_not @studio_user.can_represent?
  end

  # === can_invite? Tests ===

  test "can_invite? returns false by default when studio is invite_only" do
    @studio.settings['invite_only'] = true
    @studio.save!
    assert_not @studio_user.can_invite?
  end

  test "can_invite? returns true with admin role" do
    @studio_user.add_role!('admin')
    assert @studio_user.can_invite?
  end

  test "can_invite? returns true when studio allows all member invites" do
    @studio.settings['all_members_can_invite'] = true
    @studio.save!
    assert @studio_user.can_invite?
  end

  test "can_invite? returns false when archived" do
    @studio_user.add_role!('admin')
    @studio_user.archive!
    assert_not @studio_user.can_invite?
  end

  # === can_edit_settings? Tests ===

  test "can_edit_settings? returns false by default" do
    assert_not @studio_user.can_edit_settings?
  end

  test "can_edit_settings? returns true with admin role" do
    @studio_user.add_role!('admin')
    assert @studio_user.can_edit_settings?
  end

  test "can_edit_settings? returns false when archived" do
    @studio_user.add_role!('admin')
    @studio_user.archive!
    assert_not @studio_user.can_edit_settings?
  end

  # === archive! and unarchive! Tests ===

  test "archive! sets archived_at timestamp" do
    assert_nil @studio_user.archived_at
    @studio_user.archive!
    assert @studio_user.archived_at.present?
    assert @studio_user.archived?
  end

  test "unarchive! clears archived_at timestamp" do
    @studio_user.archive!
    assert @studio_user.archived?
    @studio_user.unarchive!
    assert_nil @studio_user.archived_at
    assert_not @studio_user.archived?
  end

  # === path Tests ===

  test "path returns studio user path for person user" do
    expected_path = "#{@studio.path}/u/#{@user.handle}"
    assert_equal expected_path, @studio_user.path
  end

  test "path returns studio path for trustee user" do
    trustee = @studio.trustee_user
    @studio.add_user!(trustee) rescue nil # May already be added
    trustee_studio_user = StudioUser.unscoped.find_by(user: trustee, studio: @studio)
    # Trustee user's path should be the studio path
    if trustee_studio_user
      assert_equal @studio.path, trustee_studio_user.path
    end
  end

  # === Trustee Validation Tests ===

  test "trustee user cannot be member of main studio" do
    @tenant.create_main_studio!(created_by: @user)
    main_studio = @tenant.main_studio
    trustee = @studio.trustee_user

    studio_user = StudioUser.new(
      tenant: @tenant,
      studio: main_studio,
      user: trustee,
    )
    assert_not studio_user.valid?
    assert_includes studio_user.errors[:user], "Trustee users cannot be members of the main studio"
  end

  test "trustee user can be member of non-main studio" do
    trustee = @studio.trustee_user
    other_studio = create_studio(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")

    studio_user = StudioUser.new(
      tenant: @tenant,
      studio: other_studio,
      user: trustee,
    )
    assert studio_user.valid?
  end

  # === confirmed_read_note_events Tests ===

  test "confirmed_read_note_events returns read confirmation events for user" do
    note = create_note(tenant: @tenant, studio: @studio, created_by: @user)

    # Create a read confirmation event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      studio: @studio,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    events = @studio_user.confirmed_read_note_events
    assert_equal 1, events.count
    assert_equal note, events.first.note
  end

  # === latest_note_reads Tests ===

  test "latest_note_reads returns recent note reads" do
    note = create_note(tenant: @tenant, studio: @studio, created_by: @user)

    NoteHistoryEvent.create!(
      tenant: @tenant,
      studio: @studio,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    reads = @studio_user.latest_note_reads
    assert_equal 1, reads.count
    assert_equal note, reads.first[:note]
    assert reads.first[:read_at].present?
  end
end
