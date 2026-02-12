# typed: false

require "test_helper"

class CommitmentParticipantTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  test "requires user" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: nil,
      committed_at: Time.current
    )

    assert_not participant.valid?
    assert_includes participant.errors[:user], "must exist"
  end

  test "valid with user" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.valid?
  end

  test "authenticated? returns true" do
    commitment = create_commitment(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.authenticated?
  end
end
