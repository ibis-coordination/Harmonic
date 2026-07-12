require "test_helper"

class InviteTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "invite-test-#{SecureRandom.hex(4)}")
    @user = create_user
    @tenant.add_user!(@user)
    @tenant.create_main_collective!(created_by: @user)
    @standard = create_collective(
      tenant: @tenant,
      created_by: @user,
      handle: "std-#{SecureRandom.hex(4)}"
    )
  end

  def build_invite(collective:, invited_user: nil, expires_at: 1.week.from_now)
    Invite.new(
      tenant: @tenant,
      collective: collective,
      created_by: @user,
      invited_user: invited_user,
      code: SecureRandom.hex(8),
      expires_at: expires_at
    )
  end

  test "invite is valid for a non-main standard collective" do
    invite = build_invite(collective: @standard)
    assert invite.valid?, "expected invite to be valid: #{invite.errors.full_messages.join(', ')}"
  end

  test "invite is invalid for the main collective" do
    invite = build_invite(collective: @tenant.main_collective)
    assert_not invite.valid?
    assert_includes invite.errors[:collective].join(" "),
                    "main collective",
                    "expected error mentioning main collective"
  end

  test "invite is invalid for a private workspace collective" do
    workspace = @user.private_workspace
    assert workspace.private_workspace?, "fixture sanity check"
    invite = build_invite(collective: workspace)
    assert_not invite.valid?
    assert_includes invite.errors[:collective].join(" "),
                    "private workspace",
                    "expected error mentioning private workspace"
  end

  test "invite is invalid for a chat collective" do
    chat = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat"
    )
    invite = build_invite(collective: chat)
    assert_not invite.valid?
    assert_includes invite.errors[:collective].join(" "),
                    "chat",
                    "expected error mentioning chat collective"
  end

  test "save! raises ActiveRecord::RecordInvalid for forbidden collective types" do
    invite = build_invite(collective: @tenant.main_collective)
    assert_raises(ActiveRecord::RecordInvalid) do
      invite.save!
    end
  end

  test "is_acceptable_by_user? rejects legacy invites on the main collective" do
    # Simulates legacy data: an invite that existed before the validation was
    # added. Bypass validation to construct it.
    invite = build_invite(collective: @tenant.main_collective)
    invite.save!(validate: false)

    invitee = create_user(name: "Invitee #{SecureRandom.hex(4)}")
    @tenant.add_user!(invitee)

    assert_not invite.is_acceptable_by_user?(invitee),
               "expected is_acceptable_by_user? to refuse invites on the main collective"
  end

  test "is_acceptable_by_user? rejects legacy invites on a private workspace" do
    workspace = @user.private_workspace
    invite = build_invite(collective: workspace)
    invite.save!(validate: false)

    invitee = create_user(name: "Invitee #{SecureRandom.hex(4)}")
    @tenant.add_user!(invitee)

    assert_not invite.is_acceptable_by_user?(invitee)
  end

  test "is_acceptable_by_user? rejects legacy invites on a chat collective" do
    chat = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      handle: "chat-#{SecureRandom.hex(4)}",
      collective_type: "chat"
    )
    invite = build_invite(collective: chat)
    invite.save!(validate: false)

    invitee = create_user(name: "Invitee #{SecureRandom.hex(4)}")
    @tenant.add_user!(invitee)

    assert_not invite.is_acceptable_by_user?(invitee)
  end
end
