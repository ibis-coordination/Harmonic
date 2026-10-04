# typed: false

# Agent-facing side of agent signup. An external agent with no account and no
# token uses these pages and actions to ask to join the tenant, naming the
# member who will be their human principal. See AgentSignup for the
# lifecycle; the principal's side lives in AgentSignupClaimsController.
#
# The surface follows the markdown UI pattern used everywhere else — a page,
# its actions index, and describe/execute per action:
#
#   /agent-signups                     the flow, and where an agent discovers
#                                      it (/help is not readable without a
#                                      session on every tenant)
#     start_agent_signup(principal_email, name, handle)
#   /agent-signups/:public_id          one signup
#     check_agent_signup(poll_secret)  reports where the signup stands and,
#                                      once the agent is claimed and active,
#                                      returns the MCP token exactly once
#
# MCP cannot serve this: /mcp requires an agent token, which is what the
# agent is here to get.
#
# Everything is unauthenticated by design. start_agent_signup responds the
# same way whether or not the email belongs to an eligible member, and a
# signup's page says nothing about the signup, so neither can be used to find
# out who is a member.
class AgentSignupsController < ApplicationController
  include RateLimits

  SIGNUPS_PER_EMAIL_PER_DAY = 3
  POLL_INTERVAL_SECONDS = 5

  STATUS_GUIDANCE = {
    "pending" => "Not claimed yet. Check again in #{POLL_INTERVAL_SECONDS} seconds.",
    "claimed_awaiting_billing" => "Claimed. Your human principal has billing to finish before you can collect your token. Check again later.",
    "redeemed" => "The token was already collected. If you do not have it, your human principal can issue one from your settings page.",
    "declined" => "Your human principal declined this signup.",
    "expired" => "The signup lapsed unclaimed. Start again with start_agent_signup at /agent-signups.",
    "pickup_window_closed" => "You were claimed but did not collect the token within 24 hours. Do not start again; you already have an " \
                              "account. Your human principal can issue a token from your settings page.",
  }.freeze

  EXECUTE_ACTIONS = [:execute_start_agent_signup, :execute_check_agent_signup].freeze

  # No authenticity token: the caller is an agent's HTTP client, not a browser
  # with a session cookie.
  skip_before_action :verify_authenticity_token, only: EXECUTE_ACTIONS

  before_action :require_agent_signup_enabled
  # There is no HTML form for these actions, so the HTML branch of the action
  # helpers (redirect with a flash) has nothing to return to. Answer in
  # markdown whatever the client asked for.
  before_action -> { request.format = :md }, only: EXECUTE_ACTIONS

  def index
    @page_title = "Agent signup"
    render_page("agent_signups/index")
  end

  # Static: no lookup, so the page is the same for a real signup, an expired
  # one, and an id that never existed.
  def show
    @page_title = "Agent signup"
    @public_id = params[:public_id].to_s
    render_page("agent_signups/show")
  end

  def actions_index
    @page_title = "Actions | Agent signup"
    render_actions_index(ActionsHelper.actions_for_route("/agent-signups"))
  end

  def actions_index_show
    @page_title = "Actions | Agent signup"
    render_actions_index(ActionsHelper.actions_for_route("/agent-signups/:public_id"))
  end

  def describe_start_agent_signup
    render_action_description(ActionsHelper.action_description("start_agent_signup"))
  end

  def describe_check_agent_signup
    render_action_description(ActionsHelper.action_description("check_agent_signup"))
  end

  def execute_start_agent_signup
    name = params[:name].to_s.strip
    email = params[:principal_email].to_s.strip.downcase
    handle = params[:handle].to_s.strip.presence

    error = start_param_error(name: name, email: email, handle: handle)
    return render_action_error({ action_name: "start_agent_signup", error: error }) if error

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

    render_action_success({ action_name: "start_agent_signup", result: start_result(signup) })
  rescue RateLimits::Exceeded
    render_action_error({
      action_name: "start_agent_signup",
      error: "Too many signups have named this principal_email today. Try again tomorrow.",
      status: :too_many_requests,
    })
  end

  def execute_check_agent_signup
    signup = AgentSignup.tenant_scoped_only(current_tenant.id).find_by(public_id: params[:public_id].to_s)
    # An unknown signup and a wrong secret get the same answer.
    unless signup&.poll_secret_matches?(params[:poll_secret].to_s)
      return render_action_error({
        action_name: "check_agent_signup",
        error: "No signup at this path matches that poll_secret.",
        status: :not_found,
      })
    end

    plaintext = signup.pick_up!
    if plaintext
      SecurityAuditLog.log_agent_signup_token_picked_up(signup: signup, ip: request.remote_ip)
      return render_action_success({ action_name: "check_agent_signup", result: ready_result(signup, plaintext) })
    end

    status = signup.agent_status
    render_action_success({ action_name: "check_agent_signup", result: "- status: #{status}\n\n#{STATUS_GUIDANCE.fetch(status)}" })
  end

  private

  # Public by design, on every tenant: an agent has no session and no token.
  def token_authenticated_action?
    true
  end

  def require_agent_signup_enabled
    return if current_tenant&.agent_signup_enabled?

    render status: :not_found, plain: "404 not found"
  end

  # HTML is the same markdown rendered, so the two cannot drift.
  def render_page(template)
    @sidebar_mode = "none"
    respond_to do |format|
      format.html do
        markdown_content = render_to_string(template: template, formats: [:md], layout: false)
        @instructions_html = MarkdownRenderer.render(markdown_content, shift_headers: false, display_references: false)
        render "agent_signups/page", layout: "application"
      end
      format.md { render template: template }
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

  def start_result(signup)
    <<~RESULT.strip
      - status: #{signup.agent_status}
      - claim_url: #{signup.claim_url}
      - pairing_code: #{signup.pairing_code}
      - signup_page: #{signup.path}
      - poll_secret: #{signup.poll_secret}
      - expires_at: #{signup.expires_at.iso8601}

      Give your human principal the claim_url and the pairing_code. They claim you while logged in as the member whose email you named. Keep the poll_secret to yourself.

      Then call `check_agent_signup(poll_secret)` at [#{signup.path}](#{signup.path}) every #{POLL_INTERVAL_SECONDS} seconds until status is `ready`. That result carries your MCP token, once.
    RESULT
  end

  def ready_result(signup, plaintext)
    <<~RESULT.strip
      - status: ready
      - mcp_token: #{plaintext}
      - mcp_endpoint: #{current_tenant.url}/mcp
      - handle: #{signup.ai_agent_user.tenant_users.find_by(tenant_id: current_tenant.id)&.handle}

      Save the mcp_token now; it is not shown again. Add mcp_endpoint to your MCP client with mcp_token as the bearer token. See [/help/mcp](/help/mcp).
    RESULT
  end
end
