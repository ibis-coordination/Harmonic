# typed: true
# frozen_string_literal: true

# Creates (or refreshes) the per-tenant Trio ai_agent User.
#
# Trio is a system-seeded AI agent that exists in every tenant as the in-app
# assistant. It is an ordinary ai_agent User in every respect except:
#   - system_role: "trio" (so parent_id may be nil and billing is exempt)
#   - parent_id: nil (no human owner)
#   - no StripeCustomer or ApiToken
#
# Idempotent. Safe to call on every request, from migrations, and from a
# rake task. On a second call it refreshes the agent_configuration so prompt
# edits roll out without manual cleanup.
class TrioSeeder
  extend T::Sig

  HANDLE = "trio"
  NAME = "Trio"

  sig { params(tenant: Tenant).returns(User) }
  def self.ensure_for(tenant)
    new(tenant).ensure
  end

  sig { params(tenant: Tenant).void }
  def initialize(tenant)
    @tenant = tenant
  end

  sig { returns(User) }
  def ensure
    with_tenant_scope do
      ActiveRecord::Base.transaction do
        existing = find_existing
        existing ? refresh(existing) : create
      end
    end
  end

  private

  sig { params(blk: T.proc.returns(User)).returns(User) }
  def with_tenant_scope(&blk)
    previous_id = Tenant.current_id
    Tenant.set_thread_context(@tenant)
    blk.call
  ensure
    if previous_id
      Tenant.set_thread_context(Tenant.find(previous_id))
    else
      Tenant.clear_thread_scope
    end
  end

  sig { returns(T.nilable(User)) }
  def find_existing
    User.joins(:tenant_users)
      .where(tenant_users: { tenant_id: @tenant.id }, system_role: "trio")
      .first
  end

  sig { params(trio: User).returns(User) }
  def refresh(trio)
    trio.update!(agent_configuration: build_agent_configuration)
    trio
  end

  sig { returns(User) }
  def create
    trio = User.create!(
      name: NAME,
      email: "trio-#{@tenant.subdomain}-#{SecureRandom.hex(4)}@system.harmonic.local",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
      agent_configuration: build_agent_configuration,
    )
    @tenant.add_user!(trio, handle: pick_handle)
    T.must(@tenant.main_collective).add_user!(trio)
    trio
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_agent_configuration
    # identity_prompt is intentionally omitted — system agents resolve their
    # prompt dynamically via User#effective_identity_prompt, which reads from
    # the static source on every call. Storing a snapshot here would just
    # invite drift.
    {
      "mode" => "internal",
      "capabilities" => [],
    }
  end

  # "trio" if free in this tenant; otherwise "trio-<hex>" until free.
  sig { returns(String) }
  def pick_handle
    return HANDLE unless handle_taken?(HANDLE)

    loop do
      candidate = "#{HANDLE}-#{SecureRandom.hex(2)}"
      return candidate unless handle_taken?(candidate)
    end
  end

  sig { params(handle: String).returns(T::Boolean) }
  def handle_taken?(handle)
    TenantUser.exists?(tenant_id: @tenant.id, handle: handle)
  end
end
