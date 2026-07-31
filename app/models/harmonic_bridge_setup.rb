# typed: true

# One-time-use credential bundle for `harmonic-bridge add --from <url>`.
# The setup is created by an authenticated human on the agent's settings
# page; the redemption endpoints are public — possession of the high-
# entropy `public_id` is the credential.
#
# Lifecycle:
#   * `HarmonicBridgeSetup.create!(...)` — initiated by a human clicking
#     "Connect harmonic-bridge" on an agent's settings page. No credentials
#     minted yet.
#   * `#redeem!` — called by `GET /bridge-setups/:public_id`. Mints the
#     MCP token, creates the AutomationRule (with no URL, disabled), and
#     returns both the token plaintext and the rule's webhook_secret. The
#     rule has to exist before POST so the bridge daemon can load the
#     secret from disk before Harmonic's verification POST arrives.
#   * `#stage_webhook!(webhook_url:, events:)` — called by
#     `POST /bridge-setups/:public_id/webhook`. Updates the AutomationRule
#     with the URL and event list, leaving it disabled. The rule won't
#     fire — it's a parked subscription waiting for verification to pass.
#   * `#finalize_webhook!` — called after the synchronous verification
#     delivery returns 2xx. Enables the rule and stamps
#     webhook_registered_at in one transaction. If we crash between
#     stage_webhook! and this call, the rule stays disabled and no
#     unverified webhook ever fires.
#   * `#revert_completion!` — destroys both the token and the
#     AutomationRule so a failed verification leaves no half-finished
#     state for the user to clean up.
class HarmonicBridgeSetup < ApplicationRecord
  extend T::Sig

  class Redeemed < StandardError; end
  class Expired < StandardError; end
  class NotYetRedeemed < StandardError; end
  class WebhookAlreadyRegistered < StandardError; end
  class WebhookNotStaged < StandardError; end
  class ConflictingSetup < StandardError; end

  belongs_to :tenant
  belongs_to :ai_agent_user, class_name: "User"
  belongs_to :created_by_user, class_name: "User"
  belongs_to :api_token, optional: true
  # Second credential, minted by redeem! only when the human opted in at
  # setup creation (include_llm_token) and the agent had a structural payer.
  belongs_to :llm_api_token, class_name: "ApiToken", optional: true
  belongs_to :automation_rule, optional: true

  # redeem!'s return shape. harmonic_llm_endpoint + harmonic_llm_token are
  # set together when the LLM token was minted; harmonic_llm_status carries
  # the reason it wasn't (only when the setup opted in). The model is not
  # part of the handshake — it's chosen bridge-side (the `--model` flag, or
  # the "default" sentinel the gateway resolves per call). Callers rendering
  # JSON should compact out the nils.
  RedeemResult = T.type_alias do
    {
      harmonic_token: String,
      signing_secret: String,
      harmonic_llm_endpoint: T.nilable(String),
      harmonic_llm_token: T.nilable(String),
      harmonic_llm_status: T.nilable(String),
    }
  end

  DEFAULT_LIFETIME = T.let(15.minutes, ActiveSupport::Duration)

  # Harnesses `harmonic-bridge setup-sprite --harness <slug>` can preconfigure.
  # The slugs are duplicated from the CLI's own registry across a language
  # boundary; a test asserts the two lists still agree.
  #
  # Omitting --harness is always valid and assumes nothing, so this list is
  # what the page offers, not what it requires.
  SPRITE_HARNESSES = T.let(
    [
      {
        slug: "claude-code",
        note: "Finishes with a one-time login inside the sprite.",
      },
      {
        slug: "codex",
        note: "Finishes with a one-time device-code login inside the sprite " \
              "(a ChatGPT workspace admin must have device-code login enabled).",
      },
      {
        slug: "goose",
        note: "No login. With an LLM gateway token from this setup, no provider " \
              "configuration at all — the agent wakes ready. Otherwise reads provider " \
              "credentials (GOOSE_PROVIDER, GOOSE_MODEL, and the provider's own API key " \
              "variable) from the sprite's environment, which you set. Installed during setup.",
      },
    ].freeze,
    T::Array[T::Hash[Symbol, String]]
  )
  DEFAULT_EVENTS = T.let(["notifications.delivered", "reminders.delivered"].freeze, T::Array[String])
  # Display name for a freshly-minted (URL-less) bridge rule until
  # stage_webhook! names it after its destination host. Purely cosmetic —
  # pending-ness is carried by the rule being a notification_webhook rule
  # with no URL, never by this string.
  PENDING_RULE_NAME = "harmonic-bridge (pending setup)".freeze

  # Mirrors NotificationWebhooksController#default_payload_template. Kept as
  # a separate copy so the model doesn't reach into a controller; the cost is
  # one small duplicated literal.
  PAYLOAD_TEMPLATE = T.let({
    "event" => "{{event.type}}",
    "recipient" => { "id" => "{{recipient.id}}", "handle" => "{{recipient.handle}}" },
    "notification" => {
      "type" => "{{notification.type}}",
      "title" => "{{notification.title}}",
      "body" => "{{notification.body}}",
      "url" => "{{notification.url}}",
      "created_at" => "{{notification.created_at}}",
    },
    "actor" => { "id" => "{{actor.id}}", "handle" => "{{actor.handle}}" },
    "collective" => { "handle" => "{{collective.handle}}" },
  }.freeze, T::Hash[String, T.untyped])

  validates :public_id, presence: true, uniqueness: { scope: :tenant_id }
  validates :expires_at, presence: true
  validate :no_existing_notification_webhook_for_agent, on: :create

  before_validation :assign_public_id, on: :create
  before_validation :assign_expires_at, on: :create
  before_validation :assign_default_events, on: :create

  sig { returns(T::Boolean) }
  def expired?
    expires_at < Time.current
  end

  sig { returns(T::Boolean) }
  def redeemable?
    redeemed_at.nil? && !expired?
  end

  sig { returns(T::Boolean) }
  def webhook_registerable?
    redeemed_at.present? && webhook_registered_at.nil? && !expired? && automation_rule.present?
  end

  # Mints the MCP token and creates the AutomationRule (disabled, no URL),
  # marks the setup redeemed, and returns the token plaintext + the rule's
  # auto-generated webhook_secret. The rule has to exist by now (not
  # created lazily on POST) so the bridge daemon can load the secret from
  # disk before Harmonic's verification POST arrives.
  #
  # `with_lock` + post-lock re-check makes this safe against two concurrent
  # GETs both passing redeemable? before either commits.
  sig { returns(RedeemResult) }
  def redeem!
    result = T.let(nil, T.nilable(RedeemResult))
    with_lock do
      raise Expired if expired?
      raise Redeemed unless redeemed_at.nil?

      # `no_existing_notification_webhook_for_agent` runs at create time and
      # is TOCTOU — two setups racing through create both see an empty
      # world. Re-check here inside the lock, against the current state of
      # AutomationRule. rule_type covers both (a) any registered
      # notification webhook and (b) another pending bridge setup's
      # freshly-minted rule that hasn't been staged yet. Other rules
      # (scheduled tasks, collective-wide rules) are unrelated.
      conflicting = AutomationRule.tenant_scoped_only(tenant_id)
        .not_deleted
        .where(ai_agent_id: ai_agent_user_id, rule_type: "notification_webhook")
      raise ConflictingSetup if conflicting.exists?

      token = mint_bridge_token!
      begin
        rule = mint_bridge_rule!
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        # The pre-mint check above is read-then-write; the one-webhook
        # validation and its backing unique index (which counts pending
        # rules) close the race. Surface it as the same conflict.
        raise ConflictingSetup
      end
      llm_token, llm_status = mint_llm_token_if_requested
      update!(api_token: token, llm_api_token: llm_token, automation_rule: rule, redeemed_at: Time.current)
      result = {
        harmonic_token: T.must(token.plaintext_token),
        signing_secret: T.must(rule.webhook_secret),
        harmonic_llm_endpoint: llm_token && llm_gateway_endpoint,
        harmonic_llm_token: llm_token&.plaintext_token,
        harmonic_llm_status: llm_status,
      }
    end
    T.must(result)
  end

  # Writes the caller-supplied webhook URL and event list onto the existing
  # AutomationRule but leaves it `enabled: false`. The rule won't fire until
  # `finalize_webhook!` is called after the verification delivery returns
  # 2xx. Crashing between stage and finalize is safe: no unverified webhook
  # ever fires, and a retry of POST overwrites the staged URL cleanly.
  #
  # Raises ActiveRecord::RecordInvalid if AutomationRule's
  # one_notification_webhook_per_user validation fires (another setup
  # finalized for the same agent while this one was pending). The caller
  # should rescue and call `revert_completion!` to clean up.
  sig { params(webhook_url: String, events: T::Array[String]).void }
  def stage_webhook!(webhook_url:, events:)
    with_lock do
      raise Expired if expired?
      raise NotYetRedeemed if redeemed_at.nil?
      raise WebhookAlreadyRegistered unless webhook_registered_at.nil?

      # Rule can be nil if a concurrent flow ran `revert_completion!` after
      # the controller's `webhook_registerable?` check passed but before we
      # took the lock. Treat that the same as the setup being consumed.
      rule = automation_rule
      raise NotYetRedeemed if rule.nil?

      rule.update!(
        name: webhook_name_for(webhook_url),
        trigger_config: { "event_types" => events },
        actions: { "webhook_url" => webhook_url, "payload_template" => PAYLOAD_TEMPLATE },
        enabled: false
      )
    end
  end

  # Enables the staged rule and stamps webhook_registered_at. Called only
  # after `WebhookTestDelivery.deliver` returns 2xx — the rule firing for
  # real notifications is gated on verification having passed.
  #
  # Raises ActiveRecord::RecordInvalid if another setup snuck a
  # finalize_webhook! in for the same agent between this setup's
  # verification and finalize. The caller should rescue and call
  # `revert_completion!`.
  sig { void }
  def finalize_webhook!
    with_lock do
      raise Expired if expired?
      raise WebhookAlreadyRegistered unless webhook_registered_at.nil?

      rule = automation_rule
      raise WebhookNotStaged if rule.nil? || !rule.webhook_registered?

      rule.update!(enabled: true)
      update!(webhook_registered_at: Time.current)
    end
  end

  # Tears down a failed setup as a single atomic step. Used by the
  # controller when the synchronous verification delivery fails — neither
  # the token nor the webhook subscription should outlive a failed setup.
  # After revert, `webhook_registerable?` returns false (no automation_rule
  # left), so the bridge gets a clean "start over with a fresh URL"
  # failure rather than a confusing "your token is gone but the URL still
  # works" half-state.
  sig { void }
  def revert_completion!
    transaction do
      rule = automation_rule
      token = api_token
      llm_token = llm_api_token
      update!(api_token: nil, llm_api_token: nil, automation_rule: nil, webhook_registered_at: nil)
      # Hard destroy is sanctioned here: the rule was minted moments ago by
      # this setup's redeem! and never registered, so it has no history.
      rule&.allow_hard_destroy = true
      rule&.destroy!
      token&.destroy!
      llm_token&.destroy!
    end
  end

  private

  sig { returns(ApiToken) }
  def mint_bridge_token!
    token = T.must(ai_agent_user).api_tokens.new(
      tenant: tenant,
      name: "harmonic-bridge connection",
      client_name: "harmonic-bridge",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now,
      token_type: "mcp"
    )
    token.save!
    token
  end

  # The opt-in third credential. Gated on structure, never balance: the
  # tenant must offer the gateway and the agent must have some payer
  # arrangement (funding pool, or a billing customer with a prepaid-credit
  # subscription). A dry balance doesn't block minting — credits can be
  # added after setup. Returns [token, nil] on mint, [nil, reason] on an
  # opted-in omission, [nil, nil] when the setup didn't opt in.
  sig { returns([T.nilable(ApiToken), T.nilable(String)]) }
  def mint_llm_token_if_requested
    return [nil, nil] unless include_llm_token?

    return [nil, "The LLM gateway is not enabled for this Harmonic tenant."] unless T.must(tenant).feature_enabled?("llm_gateway")

    unless LLMGateway::PayerResolver.structurally_fundable?(T.must(ai_agent_user))
      return [nil, "The agent has no funding source. " \
                   "Attach a funding pool or set up prepaid billing, then connect again.",]
    end

    token = T.must(ai_agent_user).api_tokens.new(
      tenant: tenant,
      name: "harmonic-bridge LLM gateway",
      client_name: "harmonic-bridge",
      # Scopes are presence-validated but not consulted on the gateway auth
      # path, and the llm_gateway type carries no content access anyway.
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      token_type: "llm_gateway"
    )
    token.save!
    [token, nil]
  end

  sig { returns(String) }
  def llm_gateway_endpoint
    "https://llm.#{ENV.fetch("HOSTNAME", "harmonic.local")}/v1"
  end

  # AutomationRule's before_validation :generate_webhook_secret populates
  # rule.webhook_secret. The rule starts disabled and with no URL — stage_webhook!
  # fills in the URL on POST; finalize_webhook! enables the rule after the
  # synchronous verification delivery returns 2xx.
  sig { returns(AutomationRule) }
  def mint_bridge_rule!
    AutomationRule.create!(
      tenant: tenant,
      ai_agent: ai_agent_user,
      created_by: created_by_user,
      name: PENDING_RULE_NAME,
      rule_type: "notification_webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => events_recommended },
      actions: { "payload_template" => PAYLOAD_TEMPLATE },
      enabled: false
    )
  end

  sig { void }
  def assign_public_id
    # self[:public_id] is T.untyped so Sorbet doesn't infer the assignment
    # as unreachable (the tapioca-generated public_id accessor is typed
    # non-nilable because the column is NOT NULL, but on an unsaved record
    # the in-memory value still starts nil).
    self.public_id = SecureRandom.urlsafe_base64(24) if self[:public_id].nil?
  end

  sig { void }
  def assign_expires_at
    self.expires_at = DEFAULT_LIFETIME.from_now if self[:expires_at].nil?
  end

  sig { void }
  def assign_default_events
    self.events_recommended = DEFAULT_EVENTS if events_recommended.blank?
  end

  sig { returns(String) }
  def generate_signing_secret
    "whsec_#{SecureRandom.hex(32)}"
  end

  sig { params(url: String).returns(String) }
  def webhook_name_for(url)
    host = URI.parse(url).host.to_s.presence || "Webhook"
    "harmonic-bridge — #{host}"
  rescue URI::InvalidURIError
    "harmonic-bridge webhook"
  end

  # An agent can have at most one notification webhook subscription at a
  # time (enforced by AutomationRule#one_notification_webhook_per_user).
  # Catching the conflict here — at setup creation — gives the user a
  # clean "delete your existing webhook first" error before any bootstrap
  # URL is generated, instead of letting them get all the way to
  # `harmonic-bridge add` and failing on `complete!`.
  #
  # Pending bridge setups (their rule has no webhook_url yet) don't count;
  # only fully-registered subscriptions block a new setup.
  sig { void }
  def no_existing_notification_webhook_for_agent
    return if ai_agent_user_id.blank? || tenant_id.blank?

    existing = AutomationRule.tenant_scoped_only(tenant_id).not_deleted
      .where(ai_agent_id: ai_agent_user_id, rule_type: "notification_webhook")
    return unless existing.any?(&:webhook_registered?)

    errors.add(:base, "Agent already has a notification webhook subscription. Remove it before generating a bridge setup URL.")
  end
end
