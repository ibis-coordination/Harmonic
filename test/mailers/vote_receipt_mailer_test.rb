# typed: false

require "test_helper"

class VoteReceiptMailerTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
  end

  test "sends email with receipt hash and verify link" do
    mail = VoteReceiptMailer.receipt_email(
      user: @user,
      decision: @decision,
      receipt: "abc123def456",
    )

    assert_equal [@user.email], mail.to
    assert_match(/vote.*recorded/i, mail.subject)
    assert_match(@decision.question, mail.subject)
    assert_match(/abc123def456/, mail.body.encoded)
    assert_match(/verify/, mail.body.encoded)
  end

  test "api_helper sends one email with last receipt from batch" do
    option_a = create_option(decision: @decision, created_by: @user, title: "Option A")
    option_b = create_option(decision: @decision, created_by: @user, title: "Option B")

    helper = ApiHelper.new(
      current_tenant: @tenant,
      current_collective: @collective,
      current_user: @user,
      current_decision: @decision,
      params: {
        votes: [
          { option_title: "Option A", accept: true, prefer: true },
          { option_title: "Option B", accept: true, prefer: false },
        ],
      },
    )

    assert_enqueued_emails 1 do
      helper.create_votes
    end
  end

  test "receipt is the voter's last audit entry, not another user's" do
    option_a = create_option(decision: @decision, created_by: @user, title: "Option A")

    # Alice votes
    alice = @user
    alice_participant = DecisionParticipantManager.new(decision: @decision, user: alice).find_or_create_participant
    alice_vote = Vote.new(tenant: @tenant, collective: @collective, decision: @decision, option: option_a, decision_participant: alice_participant, accepted: 1, preferred: 0)
    DecisionActionService.cast_vote!(decision: @decision, vote: alice_vote, actor: alice)

    alice_receipt = DecisionAuditEntry.receipt_for_user(@decision, alice)

    # Bob votes after Alice
    bob = create_user(email: "bob-#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(bob)
    @collective.add_user!(bob)
    bob_participant = DecisionParticipantManager.new(decision: @decision, user: bob).find_or_create_participant
    bob_vote = Vote.new(tenant: @tenant, collective: @collective, decision: @decision, option: option_a, decision_participant: bob_participant, accepted: 1, preferred: 1)
    DecisionActionService.cast_vote!(decision: @decision, vote: bob_vote, actor: bob)

    # Alice's receipt should still be her own entry, not Bob's
    assert_equal alice_receipt.entry_hash, DecisionAuditEntry.receipt_for_user(@decision, alice)&.entry_hash

    # Bob's receipt should be different from Alice's
    bob_receipt = DecisionAuditEntry.receipt_for_user(@decision, bob)
    assert_not_equal alice_receipt.entry_hash, bob_receipt.entry_hash
  end
end
