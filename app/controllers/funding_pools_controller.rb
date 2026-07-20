# typed: false

# The collective funding pool: the pool page plus every pool operation —
# lifecycle, ceiling, enrollment, and the funded-agent roster. The pool page
# is the single surface for members and admins alike; everything routes
# under the collective's /pool prefix.
class FundingPoolsController < ApplicationController
  before_action :set_sidebar_mode, only: [:show]

  # The pool page, for everyone: state, roster, and self-serve
  # enroll/withdraw for members; lifecycle, ceiling, and the funded-agent
  # roster for admins. Non-members never reach it — the
  # collective-membership boundary bounces them to /join.
  def show
    @funding_pool = @current_collective.funding_pool
    @funding_pools_enabled = @current_collective.funding_pools_available?
    @is_pool_admin = @current_user&.collective_member&.is_admin? || false
    if @funding_pool.nil? && !@funding_pools_enabled
      flash[:alert] = "This collective has no funding pool."
      return redirect_to @current_collective.path
    end

    @page_title = "Funding Pool"
    if @funding_pool
      @pool_enrollments = @funding_pool.enrollments.active.includes(:user).to_a
      @current_user_enrollment = @current_user && @pool_enrollments.find { |e| e.user_id == @current_user.id }
      @current_user_enrolled = @current_user_enrollment.present?
      @funded_agents = @funding_pool.funded_agents.order(:name)
      @usage_report = LLMGateway::UsageReport.pool_report(@funding_pool)
      # Agents an admin could attach: this tenant's agents whose principal is
      # actively enrolled. Attachment is gated on the operator-managed flag.
      if @is_pool_admin && !@funding_pool.archived? && @current_collective.feature_enabled?("funding_pools")
        enrolled_ids = @pool_enrollments.map(&:user_id)
        @attachable_agents = User.where(user_type: "ai_agent", parent_id: enrolled_ids)
          .includes(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
          .where.not(id: @funded_agents.pluck(:id))
          .order(:name)
      end
    end
    respond_to do |format|
      format.html
      format.md
    end
  end

  # The index is the complete pool surface: every pool action lives here, so
  # the conditional actions are evaluated for this viewer instead of being
  # left to the page footer.
  def actions_index
    @page_title = "Actions | Funding Pool"
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/pool") || {}
    context = { user: @current_user, collective: @current_collective, tenant: @current_tenant }
    conditional = (route_info[:conditional_actions] || []).select do |conditional_action|
      conditional_action[:condition].call(context)
    rescue StandardError
      false
    end
    conditional = conditional.map do |conditional_action|
      definition = ActionsHelper.action_definition(conditional_action[:name]) || {}
      { name: conditional_action[:name], params_string: definition[:params_string], description: definition[:description] }
    end
    render_actions_index({ actions: (route_info[:actions] || []) + conditional })
  end

  # Open a funding pool for this collective (or reopen a closed one): the
  # instrument through which enrolled members fund the collective's agents.
  def create_funding_pool
    unless @current_tenant.feature_enabled?("stripe_billing")
      return render_funded_agent_error(403, "Funding pools require billing to be enabled for this account")
    end
    return render_funded_agent_error(403, "Only standard collectives can have a funding pool") unless @current_collective.standard?
    unless @current_collective.funding_pools_available?
      return render_funded_agent_error(403, "Funding pools require the paid plan for this collective")
    end
    return render_funded_agent_error(403, "Unauthorized") unless @current_user.collective_member&.is_admin?

    # The ceiling is part of opening a pool, never an implicit default:
    # required when creating, optional when reopening (the closed pool
    # already carries one).
    begin
      cap_cents = MoneyParam.dollars_to_cents(params[:member_daily_draw_cap])
    rescue ArgumentError
      return render_funded_agent_error(422, "The pool draw ceiling must be a dollar amount, e.g. 5.00")
    end
    period = params[:member_draw_cap_period].presence
    if period && FundingPool::DRAW_CAP_PERIODS.exclude?(period)
      return render_funded_agent_error(422, "The pool ceiling window must be day, week, or month")
    end

    pool = @current_collective.funding_pool
    if pool
      pool.member_draw_cap_cents = cap_cents if cap_cents
      pool.member_draw_cap_period = period if period
      pool.archived_at = nil
      return render_funded_agent_error(422, pool.errors.full_messages.to_sentence) unless pool.save
    else
      if cap_cents.nil?
        message = "A pool draw ceiling is required to open a funding pool — the most it may bill any one enrolled member within its window"
        return render_funded_agent_error(422, message)
      end
      FundingPool.create!(collective: @current_collective, created_by: @current_user,
                          member_draw_cap_cents: cap_cents, member_draw_cap_period: period || "day")
    end
    @current_collective.reload.ensure_personas_funded!

    flash[:notice] = "Funding pool is open. Members can now enroll."
    redirect_to pool_page_path
  end

  # The ceiling is the pool's own setting, changed from the pool page. Paused
  # (like enrollment and attachment) while pools are unavailable — wind-down
  # mode only allows exits.
  def update_ceiling
    return render_funded_agent_error(403, "Unauthorized") unless @current_user&.collective_member&.is_admin?

    pool = @current_collective.funding_pool
    return render_funded_agent_error(404, "This collective has no funding pool") if pool.nil?
    unless @current_collective.funding_pools_available?
      return render_funded_agent_error(403, "Funding pools are paused for this collective, so the draw ceiling cannot be changed")
    end

    period = params[:member_draw_cap_period].presence
    if period && FundingPool::DRAW_CAP_PERIODS.exclude?(period)
      return render_funded_agent_error(422, "The pool ceiling window must be day, week, or month")
    end

    begin
      cap_cents = MoneyParam.dollars_to_cents(params[:member_daily_draw_cap])
      raise ArgumentError, "ceiling required" if cap_cents.nil?

      pool.member_draw_cap_cents = cap_cents
      pool.member_draw_cap_period = period if period
      pool.save!
    rescue ArgumentError
      return render_funded_agent_error(422, "The pool draw ceiling must be a dollar amount, e.g. 5.00 — every pool must have one")
    rescue ActiveRecord::RecordInvalid => e
      return render_funded_agent_error(422, e.record.errors.full_messages.to_sentence)
    end

    flash[:notice] = "Pool draw ceiling is now #{format("$%.2f", pool.member_draw_cap_cents / 100.0)} per #{pool.member_draw_cap_period}."
    redirect_to pool_page_path
  end

  # Closing the pool stops all of its spending: attached agents' calls are
  # refused from the next one on (1-to-1 — there is no fallback payer; no
  # status flips, so reopening resumes them automatically). Enrollments
  # survive as consent records for draws already made.
  def close_funding_pool
    return render_funded_agent_error(403, "Unauthorized") unless @current_user.collective_member&.is_admin?

    pool = @current_collective.funding_pool
    return render_funded_agent_error(404, "This collective has no open funding pool") if pool.nil? || pool.archived?

    pool.archive!
    flash[:notice] = "Funding pool closed. Its agents stop running until it reopens, or until they are detached and given their own billing."
    redirect_to pool_page_path
  end

  # Enrollment is the member's own consent to be drawn on — always self-serve,
  # never done by an admin on someone's behalf. Redirects land on the pool
  # page: unlike settings, every member can see it.
  def enroll_in_funding_pool
    unless @current_collective.funding_pools_available?
      return render_funded_agent_error(403, "Funding pools are not available for this collective", redirect_path: pool_page_path)
    end

    pool = @current_collective.funding_pool
    return render_funded_agent_error(404, "This collective has no open funding pool", redirect_path: pool_page_path) if pool.nil? || pool.archived?

    # Consent states a number: the enrollee's own daily draw ceiling comes
    # with the enrollment, never from an assumed default. The "pool" choice
    # snapshots the pool's current ceiling as the member's own — matching
    # everyone is the norm, opting DOWN is the individual move — so a later
    # pool-ceiling raise never silently raises this member's exposure.
    # Re-posting while enrolled updates the ceiling.
    if params[:ceiling_choice] == "pool"
      cap_cents = pool.member_draw_cap_cents
      period = pool.member_draw_cap_period
    else
      begin
        cap_cents = MoneyParam.dollars_to_cents(params[:daily_draw_cap])
      rescue ArgumentError
        cap_cents = nil
      end
      period = params[:draw_cap_period].presence || "day"
    end
    if cap_cents.nil?
      message = if params[:ceiling_choice] == "custom"
                  "Enter a dollar amount for your own ceiling, e.g. 5.00"
                else
                  "Enrolling requires your own draw ceiling — the most this pool may bill you, as a dollar amount, e.g. 5.00"
                end
      return render_funded_agent_error(422, message, redirect_path: pool_page_path)
    end
    unless FundingPool::DRAW_CAP_PERIODS.include?(period)
      return render_funded_agent_error(422, "Choose a ceiling window: day, week, or month.", redirect_path: pool_page_path)
    end

    already_enrolled = pool.enrollments.active.exists?(user_id: @current_user.id)
    begin
      pool.enroll!(@current_user, draw_cap_cents: cap_cents, draw_cap_period: period)
    rescue ActiveRecord::RecordInvalid => e
      return render_funded_agent_error(422, e.record.errors.full_messages.to_sentence, redirect_path: pool_page_path)
    end

    stated = format("$%.2f", cap_cents / 100.0)
    pool_cap = format("$%.2f", pool.member_draw_cap_cents / 100.0)
    # Ceilings over different windows can't be compared — both simply apply.
    effective_note = if period != pool.member_draw_cap_period
                       " (the pool's #{pool_cap} per #{pool.member_draw_cap_period} ceiling also applies)"
                     elsif pool.member_draw_cap_cents < cap_cents
                       " (the pool's #{pool_cap} ceiling applies while it is lower)"
                     else
                       ""
                     end
    flash[:notice] = if already_enrolled
                       "Your draw ceiling is now #{stated} per #{period}#{effective_note}."
                     else
                       "You are enrolled: this collective's funded agents can now draw from your prepaid balance, " \
                         "up to #{stated} per #{period}#{effective_note}."
                     end
    redirect_to pool_page_path
  end

  def withdraw_from_funding_pool
    pool = @current_collective.funding_pool
    enrollment = pool && pool.enrollments.find_by(user_id: @current_user.id)
    if enrollment.nil? || enrollment.archived?
      return render_funded_agent_error(404, "You are not enrolled in this funding pool", redirect_path: pool_page_path)
    end

    enrollment.withdraw!
    flash[:notice] = "You have withdrawn from the funding pool. You drop out of draws immediately."
    if pool.funded_agents.where(parent_id: @current_user.id).exists?
      flash[:notice] += " Your agents funded by this pool stay attached but their calls are refused until you re-enroll or they are detached."
    end
    redirect_to pool_page_path
  end

  # Attach an agent to the pool's payroll: its LLM usage draws from enrolled
  # members' balances from the next call on. Admitting an agent spends
  # everyone's money, so it is admin-only; the model validation additionally
  # requires the agent's principal to be actively enrolled. Deliberately
  # gated on the operator-managed collective flag, NOT on self-serve pool
  # availability: a self-serve (paid tier) pool funds only the collective's
  # own built-in personas, never arbitrary agents.
  def add_funded_agent
    unless @current_collective.feature_enabled?("funding_pools")
      return render_funded_agent_error(403, "Attaching agents to the funding pool requires operator enablement for this collective")
    end

    pool = @current_collective.funding_pool
    return render_funded_agent_error(403, "This collective has no open funding pool") if pool.nil? || pool.archived?
    return render_funded_agent_error(403, "Unauthorized") unless @current_user.collective_member&.is_admin?

    # Scoped to this tenant's agents: funding only operates where the
    # collective lives (per-call enrollment lookups are tenant-scoped), so an
    # agent from another tenant would attach and then be suspended forever.
    ai_agent = User.where(user_type: "ai_agent")
      .joins(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
      .find_by(id: params[:ai_agent_id])
    return render_funded_agent_error(404, "AI Agent not found") if ai_agent.nil?

    ai_agent.funding_pool = pool
    return render_funded_agent_error(422, ai_agent.errors.full_messages.to_sentence) unless ai_agent.save

    respond_to do |format|
      format.json do
        render json: {
          ai_agent_id: ai_agent.id,
          ai_agent_name: ai_agent.display_name,
          ai_agent_path: ai_agent.path,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} is now funded by #{@current_collective.name}"
        redirect_to pool_page_path
      end
    end
  end

  def remove_funded_agent
    return render_funded_agent_error(403, "Unauthorized") unless @current_user.collective_member&.is_admin?

    pool = @current_collective.funding_pool
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if pool.nil? || ai_agent.nil? || ai_agent.funding_pool_id != pool.id
      return render_funded_agent_error(404, "AI Agent is not funded by this collective")
    end

    # Persona attachment is automatic while the pool is open — detaching one
    # would leave a phantom state (persona active, pool open, every run
    # failing) that the next reconcile would silently undo.
    if @current_collective.persona_users.map(&:id).include?(ai_agent.id)
      return render_funded_agent_error(422,
                                       "#{ai_agent.display_name} is funded automatically while the pool is open — disable it in collective settings or close the pool instead")
    end

    ai_agent.update!(funding_pool_id: nil)

    respond_to do |format|
      format.json do
        render json: { ai_agent_id: ai_agent.id, ai_agent_name: ai_agent.display_name }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} is no longer funded by #{@current_collective.name}"
        redirect_to pool_page_path
      end
    end
  end

  def describe_enroll_in_funding_pool
    render_action_description(ActionsHelper.action_description("enroll_in_funding_pool", resource: @current_collective))
  end

  def execute_enroll_in_funding_pool
    unless current_user
      return render_action_error({ action_name: "enroll_in_funding_pool", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end

    unless @current_collective.funding_pools_available?
      return render_action_error({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        error: "Funding pools are not available for this collective.",
        status: :not_found,
      })
    end

    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_action_error({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        error: "This collective has no open funding pool.",
        status: :not_found,
      })
    end

    begin
      cap_cents = MoneyParam.dollars_to_cents(params[:daily_draw_cap])
    rescue ArgumentError
      cap_cents = nil
    end
    if cap_cents.nil?
      return render_action_error({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        error: 'Enrolling requires daily_draw_cap — your own ceiling on what this pool may bill you, as a dollar amount, e.g. "5.00".',
      })
    end

    period = params[:draw_cap_period].presence || "day"
    unless FundingPool::DRAW_CAP_PERIODS.include?(period)
      return render_action_error({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        error: 'draw_cap_period must be one of "day", "week", or "month".',
      })
    end

    begin
      pool.enroll!(current_user, draw_cap_cents: cap_cents, draw_cap_period: period)
      render_action_success({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        result: "You are enrolled: #{@current_collective.name}'s funded agents can now draw from your prepaid balance, " \
                "up to #{format("$%.2f", cap_cents / 100.0)} per #{period}.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: "enroll_in_funding_pool",
        resource: @current_collective,
        error: e.record.errors.full_messages.to_sentence,
      })
    end
  end

  def describe_withdraw_from_funding_pool
    render_action_description(ActionsHelper.action_description("withdraw_from_funding_pool", resource: @current_collective))
  end

  def execute_withdraw_from_funding_pool
    unless current_user
      return render_action_error({ action_name: "withdraw_from_funding_pool", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end

    pool = @current_collective.funding_pool
    enrollment = pool && pool.enrollments.find_by(user_id: current_user.id)
    if enrollment.nil? || enrollment.archived?
      return render_action_error({
        action_name: "withdraw_from_funding_pool",
        resource: @current_collective,
        error: "You are not enrolled in this funding pool.",
        status: :not_found,
      })
    end

    enrollment.withdraw!
    result = "You have withdrawn from the funding pool. You drop out of draws immediately."
    # No confirm step on this surface, so the result message is the only place
    # the caller learns their attached agents stopped.
    if pool.funded_agents.where(parent_id: current_user.id).exists?
      result += " Your agents funded by this pool stay attached but their calls are refused until you re-enroll or they are detached."
    end
    render_action_success({
      action_name: "withdraw_from_funding_pool",
      resource: @current_collective,
      result: result,
    })
  end

  def describe_attach_funded_agent
    render_action_description(ActionsHelper.action_description("attach_funded_agent", resource: @current_collective))
  end

  def execute_attach_funded_agent
    unless current_user
      return render_action_error({ action_name: "attach_funded_agent", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end
    unless current_user.collective_member&.is_admin?
      return render_action_error({ action_name: "attach_funded_agent", resource: @current_collective,
                                   error: "Only collective admins can attach funded agents.", status: :forbidden, })
    end

    # Operator flag, not self-serve availability: a self-serve pool funds
    # only the collective's own built-in personas, never arbitrary agents.
    unless @current_collective.feature_enabled?("funding_pools")
      return render_action_error({
        action_name: "attach_funded_agent",
        resource: @current_collective,
        error: "Attaching agents to the funding pool requires operator enablement for this collective.",
        status: :not_found,
      })
    end

    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_action_error({
        action_name: "attach_funded_agent",
        resource: @current_collective,
        error: "This collective has no open funding pool.",
        status: :not_found,
      })
    end

    # Same tenant-scoped lookup as the HTML endpoint: an agent from another
    # tenant would attach and then be suspended forever.
    ai_agent = User.where(user_type: "ai_agent")
      .joins(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
      .find_by(id: params[:ai_agent_id])
    if ai_agent.nil?
      return render_action_error({
        action_name: "attach_funded_agent",
        resource: @current_collective,
        error: "AI Agent not found.",
        status: :not_found,
      })
    end

    ai_agent.funding_pool = pool
    if ai_agent.save
      render_action_success({
        action_name: "attach_funded_agent",
        resource: @current_collective,
        result: "#{ai_agent.display_name} is now funded by #{@current_collective.name}.",
      })
    else
      render_action_error({
        action_name: "attach_funded_agent",
        resource: @current_collective,
        error: ai_agent.errors.full_messages.to_sentence,
      })
    end
  end

  def describe_set_pool_ceiling
    render_action_description(ActionsHelper.action_description("set_pool_ceiling", resource: @current_collective))
  end

  def execute_set_pool_ceiling
    unless current_user
      return render_action_error({ action_name: "set_pool_ceiling", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end
    unless current_user.collective_member&.is_admin?
      return render_action_error({ action_name: "set_pool_ceiling", resource: @current_collective,
                                   error: "Only collective admins can set the pool ceiling.", status: :forbidden, })
    end

    pool = @current_collective.funding_pool
    if pool.nil?
      return render_action_error({
        action_name: "set_pool_ceiling",
        resource: @current_collective,
        error: "This collective has no funding pool, so it has no draw ceiling to set.",
        status: :not_found,
      })
    end
    unless @current_collective.funding_pools_available?
      return render_action_error({
        action_name: "set_pool_ceiling",
        resource: @current_collective,
        error: "Funding pools are paused for this collective, so the draw ceiling cannot be changed.",
        status: :forbidden,
      })
    end

    period = params[:member_draw_cap_period].presence
    if period && FundingPool::DRAW_CAP_PERIODS.exclude?(period)
      return render_action_error({
        action_name: "set_pool_ceiling",
        resource: @current_collective,
        error: 'member_draw_cap_period must be one of "day", "week", or "month".',
      })
    end

    begin
      cap_cents = MoneyParam.dollars_to_cents(params[:member_daily_draw_cap])
      raise ArgumentError, "ceiling required" if cap_cents.nil?

      pool.member_draw_cap_cents = cap_cents
      pool.member_draw_cap_period = period if period
      pool.save!
    rescue ArgumentError
      return render_action_error({
        action_name: "set_pool_ceiling",
        resource: @current_collective,
        error: 'The pool draw ceiling must be a dollar amount, e.g. "5.00" — every pool must have one, so it cannot be cleared.',
      })
    rescue ActiveRecord::RecordInvalid => e
      return render_action_error({
        action_name: "set_pool_ceiling",
        resource: @current_collective,
        error: e.record.errors.full_messages.to_sentence,
      })
    end

    render_action_success({
      action_name: "set_pool_ceiling",
      resource: @current_collective,
      result: "Pool draw ceiling is now #{format("$%.2f", pool.member_draw_cap_cents / 100.0)} per #{pool.member_draw_cap_period}.",
    })
  end

  def describe_detach_funded_agent
    render_action_description(ActionsHelper.action_description("detach_funded_agent", resource: @current_collective))
  end

  def execute_detach_funded_agent
    unless current_user
      return render_action_error({ action_name: "detach_funded_agent", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end
    unless current_user.collective_member&.is_admin?
      return render_action_error({ action_name: "detach_funded_agent", resource: @current_collective,
                                   error: "Only collective admins can detach funded agents.", status: :forbidden, })
    end

    pool = @current_collective.funding_pool
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if pool.nil? || ai_agent.nil? || ai_agent.funding_pool_id != pool.id
      return render_action_error({
        action_name: "detach_funded_agent",
        resource: @current_collective,
        error: "AI Agent is not funded by this collective.",
        status: :not_found,
      })
    end
    # Same guard as the HTML endpoint: persona attachment is automatic.
    if @current_collective.persona_users.map(&:id).include?(ai_agent.id)
      return render_action_error({
        action_name: "detach_funded_agent",
        resource: @current_collective,
        error: "#{ai_agent.display_name} is funded automatically while the pool is open — disable it in collective settings or close the pool instead.",
        status: :unprocessable_entity,
      })
    end

    ai_agent.update!(funding_pool_id: nil)
    render_action_success({
      action_name: "detach_funded_agent",
      resource: @current_collective,
      result: "#{ai_agent.display_name} is no longer funded by #{@current_collective.name}.",
    })
  end

  private

  # The funded-agent actions are called from both plain HTML forms and JSON
  # clients; errors must come back in the caller's format.
  def render_funded_agent_error(status, message, redirect_path: nil)
    respond_to do |format|
      format.json { render status: status, json: { error: message } }
      format.html do
        flash[:alert] = message
        redirect_to(redirect_path || pool_page_path)
      end
    end
  end

  def pool_page_path
    "#{@current_collective.path}/pool"
  end

  def set_sidebar_mode
    @sidebar_mode = "settings"
    @team = @current_collective.team
  end
end
