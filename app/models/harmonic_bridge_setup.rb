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
#   * `#mark_redeemed!` — called by `GET /bridge-setups/:public_id`. Marks
#     the setup as redeemed and returns metadata only (no credentials).
#     An abandoned redemption leaks nothing.
#   * `#complete!(webhook_url:, events:)` — called by
#     `POST /bridge-setups/:public_id/webhook`. Atomically mints the MCP
#     token, creates the AutomationRule notification-webhook subscription,
#     and returns both credentials together.
#   * `#revert_completion!` — controller calls this if the post-completion
#     verification delivery fails. Destroys the token and the AutomationRule
#     and returns the setup to retryable state.
class HarmonicBridgeSetup < ApplicationRecord
  extend T::Sig

  class Redeemed < StandardError; end
  class Expired < StandardError; end
  class NotYetRedeemed < StandardError; end
  class WebhookAlreadyRegistered < StandardError; end

  belongs_to :tenant
  belongs_to :ai_agent_user, class_name: "User"
  belongs_to :created_by_user, class_name: "User"
  belongs_to :api_token, optional: true
  belongs_to :automation_rule, optional: true

  DEFAULT_LIFETIME = T.let(15.minutes, ActiveSupport::Duration)
  DEFAULT_EVENTS = T.let(["notifications.delivered", "reminders.delivered"].freeze, T::Array[String])

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
    redeemed_at.present? && webhook_registered_at.nil? && !expired?
  end

  # Marks the setup as redeemed. No credentials are minted at this stage;
  # the GET response only carries metadata so an abandoned redemption
  # leaves nothing to clean up. `with_lock` + post-lock re-check makes
  # this safe against two concurrent GETs.
  sig { void }
  def mark_redeemed!
    with_lock do
      raise Expired if expired?
      raise Redeemed unless redeemed_at.nil?

      update!(redeemed_at: Time.current)
    end
  end

  # Atomic completion: mints the ApiToken, creates the AutomationRule
  # notification-webhook subscription, and marks the setup completed —
  # all in one transaction. Returns the plaintext token + signing secret;
  # both are revealed exactly once. Caller is responsible for putting
  # them into the HTTP response.
  #
  # Verification of the webhook URL happens AFTER this returns; if that
  # fails, the caller invokes `revert_completion!` to undo everything.
  sig do
    params(webhook_url: String, events: T::Array[String])
      .returns({ harmonic_token: String, signing_secret: String })
  end
  def complete!(webhook_url:, events:)
    result = T.let(nil, T.nilable({ harmonic_token: String, signing_secret: String }))
    with_lock do
      raise Expired if expired?
      raise NotYetRedeemed if redeemed_at.nil?
      raise WebhookAlreadyRegistered unless webhook_registered_at.nil?

      token = T.must(ai_agent_user).api_tokens.new(
        tenant: tenant,
        name: "harmonic-bridge connection",
        client_name: "harmonic-bridge",
        scopes: ApiToken.read_scopes + ApiToken.write_scopes,
        expires_at: 1.year.from_now,
        mcp_only: true
      )
      token.save!

      secret = generate_signing_secret
      rule = AutomationRule.create!(
        tenant: tenant,
        ai_agent: ai_agent_user,
        created_by: created_by_user,
        name: webhook_name_for(webhook_url),
        trigger_type: "event",
        trigger_config: { "event_types" => events },
        actions: {
          "webhook_url" => webhook_url,
          "payload_template" => PAYLOAD_TEMPLATE,
        },
        webhook_secret: secret,
        enabled: true
      )

      update!(api_token: token, automation_rule: rule, webhook_registered_at: Time.current)
      result = { harmonic_token: T.must(token.plaintext_token), signing_secret: secret }
    end
    T.must(result)
  end

  # Tears down a completed setup as a single atomic step. Used by the
  # controller when the synchronous verification delivery fails — neither
  # the token nor the webhook subscription should outlive a failed setup.
  # The setup itself is returned to the redeemed-but-not-completed state
  # so the caller can retry the POST (no fresh URL needed).
  sig { void }
  def revert_completion!
    transaction do
      rule = automation_rule
      token = api_token
      update!(api_token: nil, automation_rule: nil, webhook_registered_at: nil)
      rule&.destroy!
      token&.destroy!
    end
  end

  private

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
end
