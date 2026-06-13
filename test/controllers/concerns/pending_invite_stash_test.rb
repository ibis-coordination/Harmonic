require "test_helper"

# The session cookie is shared across tenant subdomains in production, so the
# stash must be keyed per tenant. Integration tests can't exercise this (the
# test env session cookie is host-only), so the cross-tenant semantics are
# pinned down here against a bare harness.
class PendingInviteStashTest < ActiveSupport::TestCase
  class Harness
    include PendingInviteStash

    attr_reader :session

    def initialize
      @session = {}
    end

    public :stash_pending_invite!, :pending_invite_code, :resolve_pending_invite, :clear_pending_invite!
  end

  def setup
    @harness = Harness.new
    @tenant_a, @collective_a, @user = build_tenant_with_collective("psa")
    @tenant_b, @collective_b, _other = build_tenant_with_collective("psb")
    @invite_a = create_invite(tenant: @tenant_a, collective: @collective_a)
    @invite_b = create_invite(tenant: @tenant_b, collective: @collective_b)
  end

  def build_tenant_with_collective(prefix)
    tenant = create_tenant(subdomain: "#{prefix}-#{SecureRandom.hex(4)}")
    owner = create_user(email: "#{prefix}-owner-#{SecureRandom.hex(4)}@example.com", name: "Owner")
    tenant.add_user!(owner)
    collective = create_collective(tenant: tenant, created_by: owner, handle: "#{prefix}-coll-#{SecureRandom.hex(4)}")
    [tenant, collective, owner]
  end

  def create_invite(tenant:, collective:, expires_at: 1.week.from_now)
    Invite.create!(
      tenant: tenant,
      collective: collective,
      created_by: collective.created_by,
      code: SecureRandom.hex(8),
      expires_at: expires_at
    )
  end

  def invitee
    @invitee ||= create_user(email: "invitee-#{SecureRandom.hex(4)}@example.com", name: "Invitee")
  end

  test "stashes for two tenants coexist instead of clobbering each other" do
    @harness.stash_pending_invite!(@invite_a)
    @harness.stash_pending_invite!(@invite_b)

    assert_equal @invite_a.code, @harness.pending_invite_code(@tenant_a)
    assert_equal @invite_b.code, @harness.pending_invite_code(@tenant_b)
  end

  test "clearing one tenant's stash leaves the other tenant's entry intact" do
    @harness.stash_pending_invite!(@invite_a)
    @harness.stash_pending_invite!(@invite_b)

    @harness.clear_pending_invite!(@tenant_a)

    assert_nil @harness.pending_invite_code(@tenant_a)
    assert_equal @invite_b.code, @harness.pending_invite_code(@tenant_b)
  end

  test "resolving on a tenant with no stash entry does not disturb another tenant's pending invite" do
    @harness.stash_pending_invite!(@invite_a)

    assert_nil @harness.resolve_pending_invite(tenant: @tenant_b, user: invitee)
    assert_equal @invite_a.code, @harness.pending_invite_code(@tenant_a),
                 "tenant A's in-flight invite must survive activity on tenant B"
  end

  test "resolving a dead code clears only the owning tenant's entry" do
    @harness.stash_pending_invite!(@invite_a)
    @harness.stash_pending_invite!(@invite_b)
    @invite_a.update!(expires_at: 1.day.ago)

    assert_nil @harness.resolve_pending_invite(tenant: @tenant_a, user: invitee)
    assert_nil @harness.pending_invite_code(@tenant_a), "dead codes are dropped by the owning tenant"
    assert_equal @invite_b.code, @harness.pending_invite_code(@tenant_b)
  end

  test "resolving a live code returns the invite and keeps the stash" do
    @harness.stash_pending_invite!(@invite_a)

    assert_equal @invite_a, @harness.resolve_pending_invite(tenant: @tenant_a, user: invitee)
    assert_equal @invite_a.code, @harness.pending_invite_code(@tenant_a)
  end
end
