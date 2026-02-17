# typed: false

require "test_helper"

class CommitmentParticipantTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  test "requires user" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: nil,
      committed_at: Time.current
    )

    assert_not participant.valid?
    assert_includes participant.errors[:user], "must exist"
  end

  test "valid with user" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.new(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.valid?
  end

  test "authenticated? returns true" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)

    participant = CommitmentParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      commitment: commitment,
      user: @user,
      committed_at: Time.current
    )

    assert participant.authenticated?
  end
end
