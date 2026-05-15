# typed: true
# frozen_string_literal: true

# Creates (or refreshes) the Trio ai_agent User for a single collective.
#
# Trio is a system-seeded AI agent that opted-in collectives use as their
# in-app assistant. It is an ordinary ai_agent User in every respect except:
#   - system_role: "trio" (so parent_id may be nil and billing is exempt)
#   - parent_id: nil (no human owner)
#   - no StripeCustomer or ApiToken
#
# The main collective's trio claims the literal handle "trio" so its profile
# lives at /u/trio via the normal handle index. Non-main collective trios
# get hex-suffixed handles to avoid the tenant-wide (tenant_id, handle)
# uniqueness collision; mention resolution for "@trio" inside those
# collectives is handled by MentionParser via collective context.
#
# Idempotent. Safe to call multiple times — returns the existing trio_user
# without modification on the second call (other than clearing any stale
# cached identity_prompt in agent_configuration).
class TrioSeeder
  extend T::Sig

  HANDLE = "trio"
  NAME = "Trio"

  sig { params(collective: Collective).returns(User) }
  def self.ensure_for(collective)
    new(collective).ensure
  end

  sig { params(collective: Collective).void }
  def initialize(collective)
    @collective = collective
  end

  sig { returns(User) }
  def ensure
    ActiveRecord::Base.transaction do
      existing = @collective.trio_user
      existing ? refresh(existing) : create
    end
  end

  private

  sig { params(trio: User).returns(User) }
  def refresh(trio)
    cfg = (trio.agent_configuration || {}).except("identity_prompt")
    trio.update!(agent_configuration: cfg) if cfg != trio.agent_configuration
    trio
  end

  sig { returns(User) }
  def create
    tenant = T.must(@collective.tenant)
    trio = User.create!(
      name: NAME,
      email: "trio-#{tenant.subdomain}-#{SecureRandom.hex(4)}@system.harmonic.local",
      user_type: "ai_agent",
      system_role: "trio",
      parent_id: nil,
      agent_configuration: build_agent_configuration,
    )
    tenant.add_user!(trio, handle: pick_handle)
    @collective.add_user!(trio)
    @collective.update!(trio_user: trio)
    trio
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_agent_configuration
    # identity_prompt is intentionally omitted — system agents resolve their
    # prompt dynamically via User#effective_identity_prompt.
    { "mode" => "internal", "capabilities" => [] }
  end

  sig { returns(String) }
  def pick_handle
    @collective.is_main_collective? ? HANDLE : "#{HANDLE}-#{SecureRandom.hex(4)}"
  end
end
