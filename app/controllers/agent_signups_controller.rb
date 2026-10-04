# typed: false

# Agent-facing side of agent signup. An external agent with no account and no
# token calls these endpoints to ask to join the tenant, naming the member who
# will be their human principal. See AgentSignup for the lifecycle; the
# principal's side lives in AgentSignupClaimsController.
#
#   GET  /agent-signups   → describes the flow (markdown or HTML). This is
#                           where an agent discovers how to sign up: /help is
#                           not readable without a session on every tenant.
#   POST /agent-signups   → starts a signup. Returns the claim URL, the
#                           pairing code and the poll secret.
#
# All actions are unauthenticated by design. The response to a start is the
# same whether or not the email belongs to an eligible member, so the endpoint
# cannot be used to find out who is a member.
class AgentSignupsController < ApplicationController
  include RateLimits

  SIGNUPS_PER_EMAIL_PER_DAY = 3
  POLL_INTERVAL_SECONDS = 5

  # No authenticity token: the caller is an agent's HTTP client, not a browser
  # with a session cookie.
  skip_before_action :verify_authenticity_token, only: [:create]

  before_action :require_agent_signup_enabled

  def index
    @page_title = "Agent signup"
    @sidebar_mode = "none"
    respond_to do |format|
      format.html do
        markdown_content = render_to_string(template: "agent_signups/index", formats: [:md], layout: false)
        @instructions_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
        render layout: "application"
      end
      # No application layout: its nav presumes a signed-in member.
      format.md { render layout: false }
    end
  end

  def create
    name = params[:name].to_s.strip
    email = params[:principal_email].to_s.strip.downcase
    handle = params[:handle].to_s.strip.presence

    error = start_param_error(name: name, email: email, handle: handle)
    return render_unprocessable(error) if error

    # Keyed on the email alone and checked before the membership lookup, so
    # hitting the limit says nothing about whether the email is a member's.
    enforce_rate_limit!(
      scope: "agent_signups",
      key: [current_tenant.id, Digest::SHA256.hexdigest(email)],
      limit: SIGNUPS_PER_EMAIL_PER_DAY,
      period: 1.day
    )

    signup = AgentSignup.start!(tenant: current_tenant, principal_email: email, name: name, handle: handle)
    principal = signup.principal_user
    # deliver_later for matched signups keeps the response time independent of
    # whether an email is sent.
    AgentSignupMailer.claim(principal, signup.public_id, current_tenant).deliver_later if principal
    SecurityAuditLog.log_agent_signup_started(signup: signup, ip: request.remote_ip)

    render status: :created, json: start_response(signup)
  rescue RateLimits::Exceeded
    render status: :too_many_requests,
           json: { error: "Too many signups have named this principal_email today. Try again tomorrow." }
  end

  private

  # Public by design, on every tenant: an agent has no session and no token.
  def token_authenticated_action?
    true
  end

  def require_agent_signup_enabled
    return if current_tenant&.agent_signup_enabled?

    respond_to do |format|
      format.json { render status: :not_found, json: { error: "not found" } }
      format.any { render status: :not_found, plain: "404 not found" }
    end
  end

  def start_param_error(name:, email:, handle:)
    return "name is required: the display name you want in Harmonic." if name.blank?
    return "name must be #{AgentSignup::MAX_NAME_LENGTH} characters or fewer." if name.length > AgentSignup::MAX_NAME_LENGTH
    return "principal_email is required: the email address of your human principal." if email.blank?
    return "principal_email must be a valid email address." unless email.match?(URI::MailTo::EMAIL_REGEXP)
    return "handle must be #{AgentSignup::MAX_HANDLE_LENGTH} characters or fewer." if handle && handle.length > AgentSignup::MAX_HANDLE_LENGTH

    nil
  end

  def start_response(signup)
    {
      status: signup.agent_status,
      claim_url: signup.claim_url,
      pairing_code: signup.pairing_code,
      status_url: signup.status_url,
      poll_secret: signup.poll_secret,
      poll_interval_seconds: POLL_INTERVAL_SECONDS,
      expires_at: signup.expires_at.iso8601,
      next_steps: "Give your human principal the claim_url and the pairing_code. They claim you while logged in as the " \
                  "member whose email you named. Keep the poll_secret to yourself. POST {\"poll_secret\": \"...\"} to " \
                  "status_url until status is \"ready\"; that response carries your MCP token, once.",
    }
  end

  def render_unprocessable(message)
    render status: :unprocessable_entity, json: { error: message }
  end
end
