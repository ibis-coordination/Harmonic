require "test_helper"

class CollectiveMemberTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "collective-member-#{SecureRandom.hex(4)}")
    @user = create_user(email: "collective_member_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "test-collective-#{SecureRandom.hex(4)}")
    @collective.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @collective_member = @collective.collective_members.find_by(user: @user)
  end

  # === Basic Association Tests ===

  test "collective_member belongs to tenant, collective, and user" do
    assert_equal @tenant, @collective_member.tenant
    assert_equal @collective, @collective_member.collective
    assert_equal @user, @collective_member.user
  end

  # === can_represent? Tests ===

  test "can_represent? returns false by default" do
    assert_not @collective_member.can_represent?
  end

  test "can_represent? returns true with representative role" do
    @collective_member.add_role!('representative')
    assert @collective_member.can_represent?
  end

  test "can_represent? returns true when collective.any_member_can_represent is enabled" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    assert @collective_member.can_represent?
  end

  test "can_represent? returns false when archived even with representative role" do
    @collective_member.add_role!('representative')
    @collective_member.archive!
    assert_not @collective_member.can_represent?
  end

  test "can_represent? returns false when archived even with any_member_can_represent" do
    @collective.settings['any_member_can_represent'] = true
    @collective.save!
    @collective_member.archive!
    assert_not @collective_member.can_represent?
  end

  # === can_invite? Tests ===

  test "can_invite? returns false by default when collective is invite_only" do
    @collective.settings['invite_only'] = true
    @collective.save!
    assert_not @collective_member.can_invite?
  end

  test "can_invite? returns true with admin role" do
    @collective_member.add_role!('admin')
    assert @collective_member.can_invite?
  end

  test "can_invite? returns true when collective allows all member invites" do
    @collective.settings['all_members_can_invite'] = true
    @collective.save!
    assert @collective_member.can_invite?
  end

  test "can_invite? returns false when archived" do
    @collective_member.add_role!('admin')
    @collective_member.archive!
    assert_not @collective_member.can_invite?
  end

  # === can_edit_settings? Tests ===

  test "can_edit_settings? returns false by default" do
    assert_not @collective_member.can_edit_settings?
  end

  test "can_edit_settings? returns true with admin role" do
    @collective_member.add_role!('admin')
    assert @collective_member.can_edit_settings?
  end

  test "can_edit_settings? returns false when archived" do
    @collective_member.add_role!('admin')
    @collective_member.archive!
    assert_not @collective_member.can_edit_settings?
  end

  # === archive! and unarchive! Tests ===

  test "archive! sets archived_at timestamp" do
    assert_nil @collective_member.archived_at
    @collective_member.archive!
    assert @collective_member.archived_at.present?
    assert @collective_member.archived?
  end

  test "unarchive! clears archived_at timestamp" do
    @collective_member.archive!
    assert @collective_member.archived?
    @collective_member.unarchive!
    assert_nil @collective_member.archived_at
    assert_not @collective_member.archived?
  end

  # === path Tests ===

  test "path returns collective member path for person user" do
    expected_path = "#{@collective.path}/u/#{@user.handle}"
    assert_equal expected_path, @collective_member.path
  end

  test "path returns collective path for proxy user" do
    proxy = @collective.proxy_user
    @collective.add_user!(proxy) rescue nil # May already be added
    proxy_collective_member = CollectiveMember.unscoped.find_by(user: proxy, collective: @collective)
    # Proxy user's path should be the collective path
    if proxy_collective_member
      assert_equal @collective.path, proxy_collective_member.path
    end
  end

  # === Proxy User Validation Tests ===

  test "proxy user cannot be member of main collective" do
    @tenant.create_main_collective!(created_by: @user)
    main_collective = @tenant.main_collective
    proxy = @collective.proxy_user

    collective_member = CollectiveMember.new(
      tenant: @tenant,
      collective: main_collective,
      user: proxy,
    )
    assert_not collective_member.valid?
    assert_includes collective_member.errors[:user], "Collective proxy users cannot be members of the main collective"
  end

  test "proxy user can be member of non-main collective" do
    proxy = @collective.proxy_user
    other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")

    collective_member = CollectiveMember.new(
      tenant: @tenant,
      collective: other_collective,
      user: proxy,
    )
    assert collective_member.valid?
  end

  # === confirmed_read_note_events Tests ===

  test "confirmed_read_note_events returns read confirmation events for user" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Create a read confirmation event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    events = @collective_member.confirmed_read_note_events
    assert_equal 1, events.count
    assert_equal note, events.first.note
  end

  # === latest_note_reads Tests ===

  test "latest_note_reads returns recent note reads" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    NoteHistoryEvent.create!(
      tenant: @tenant,
      collective: @collective,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    reads = @collective_member.latest_note_reads
    assert_equal 1, reads.count
    assert_equal note, reads.first[:note]
    assert reads.first[:read_at].present?
  end
end
