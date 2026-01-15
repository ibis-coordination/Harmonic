require "test_helper"

class SuperagentMemberTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "superagent-member-#{SecureRandom.hex(4)}")
    @user = create_user(email: "superagent_member_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "test-superagent-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @superagent_member = @superagent.superagent_members.find_by(user: @user)
  end

  # === Basic Association Tests ===

  test "superagent_member belongs to tenant, superagent, and user" do
    assert_equal @tenant, @superagent_member.tenant
    assert_equal @superagent, @superagent_member.superagent
    assert_equal @user, @superagent_member.user
  end

  # === can_represent? Tests ===

  test "can_represent? returns false by default" do
    assert_not @superagent_member.can_represent?
  end

  test "can_represent? returns true with representative role" do
    @superagent_member.add_role!('representative')
    assert @superagent_member.can_represent?
  end

  test "can_represent? returns true when superagent.any_member_can_represent is enabled" do
    @superagent.settings['any_member_can_represent'] = true
    @superagent.save!
    assert @superagent_member.can_represent?
  end

  test "can_represent? returns false when archived even with representative role" do
    @superagent_member.add_role!('representative')
    @superagent_member.archive!
    assert_not @superagent_member.can_represent?
  end

  test "can_represent? returns false when archived even with any_member_can_represent" do
    @superagent.settings['any_member_can_represent'] = true
    @superagent.save!
    @superagent_member.archive!
    assert_not @superagent_member.can_represent?
  end

  # === can_invite? Tests ===

  test "can_invite? returns false by default when superagent is invite_only" do
    @superagent.settings['invite_only'] = true
    @superagent.save!
    assert_not @superagent_member.can_invite?
  end

  test "can_invite? returns true with admin role" do
    @superagent_member.add_role!('admin')
    assert @superagent_member.can_invite?
  end

  test "can_invite? returns true when superagent allows all member invites" do
    @superagent.settings['all_members_can_invite'] = true
    @superagent.save!
    assert @superagent_member.can_invite?
  end

  test "can_invite? returns false when archived" do
    @superagent_member.add_role!('admin')
    @superagent_member.archive!
    assert_not @superagent_member.can_invite?
  end

  # === can_edit_settings? Tests ===

  test "can_edit_settings? returns false by default" do
    assert_not @superagent_member.can_edit_settings?
  end

  test "can_edit_settings? returns true with admin role" do
    @superagent_member.add_role!('admin')
    assert @superagent_member.can_edit_settings?
  end

  test "can_edit_settings? returns false when archived" do
    @superagent_member.add_role!('admin')
    @superagent_member.archive!
    assert_not @superagent_member.can_edit_settings?
  end

  # === archive! and unarchive! Tests ===

  test "archive! sets archived_at timestamp" do
    assert_nil @superagent_member.archived_at
    @superagent_member.archive!
    assert @superagent_member.archived_at.present?
    assert @superagent_member.archived?
  end

  test "unarchive! clears archived_at timestamp" do
    @superagent_member.archive!
    assert @superagent_member.archived?
    @superagent_member.unarchive!
    assert_nil @superagent_member.archived_at
    assert_not @superagent_member.archived?
  end

  # === path Tests ===

  test "path returns superagent member path for person user" do
    expected_path = "#{@superagent.path}/u/#{@user.handle}"
    assert_equal expected_path, @superagent_member.path
  end

  test "path returns superagent path for trustee user" do
    trustee = @superagent.trustee_user
    @superagent.add_user!(trustee) rescue nil # May already be added
    trustee_superagent_member = SuperagentMember.unscoped.find_by(user: trustee, superagent: @superagent)
    # Trustee user's path should be the superagent path
    if trustee_superagent_member
      assert_equal @superagent.path, trustee_superagent_member.path
    end
  end

  # === Trustee Validation Tests ===

  test "trustee user cannot be member of main superagent" do
    @tenant.create_main_superagent!(created_by: @user)
    main_superagent = @tenant.main_superagent
    trustee = @superagent.trustee_user

    superagent_member = SuperagentMember.new(
      tenant: @tenant,
      superagent: main_superagent,
      user: trustee,
    )
    assert_not superagent_member.valid?
    assert_includes superagent_member.errors[:user], "Trustee users cannot be members of the main superagent"
  end

  test "trustee user can be member of non-main superagent" do
    trustee = @superagent.trustee_user
    other_superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")

    superagent_member = SuperagentMember.new(
      tenant: @tenant,
      superagent: other_superagent,
      user: trustee,
    )
    assert superagent_member.valid?
  end

  # === confirmed_read_note_events Tests ===

  test "confirmed_read_note_events returns read confirmation events for user" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    # Create a read confirmation event
    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: @superagent,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    events = @superagent_member.confirmed_read_note_events
    assert_equal 1, events.count
    assert_equal note, events.first.note
  end

  # === latest_note_reads Tests ===

  test "latest_note_reads returns recent note reads" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)

    NoteHistoryEvent.create!(
      tenant: @tenant,
      superagent: @superagent,
      note: note,
      user: @user,
      event_type: 'read_confirmation',
      happened_at: Time.current,
    )

    reads = @superagent_member.latest_note_reads
    assert_equal 1, reads.count
    assert_equal note, reads.first[:note]
    assert reads.first[:read_at].present?
  end
end
