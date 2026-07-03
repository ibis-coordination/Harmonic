# typed: false

# TODO: Bug - representatives can perform actions within the collective they are representing AS the collective
# (identity user), which doesn't make sense. Representatives should only be able to act on behalf of
# the collective in OTHER collectives, not within the collective itself. Need to investigate what changed.

class RepresentationSessionsController < ApplicationController
  include RequiresReverification

  before_action :set_sidebar_mode, only: [:index, :show, :represent, :representing]
  before_action -> { require_reverification(scope: "representation") }, only: [:represent, :start_representing, :start_representing_user]

  def index
    @representatives = current_collective.representatives
    @page_title = "Representation"
    @representation_sessions = current_collective.representation_sessions.where.not(ended_at: nil).order(ended_at: :desc).limit(100)
    @active_sessions = current_collective.representation_sessions.where(ended_at: nil).order(began_at: :desc).limit(100)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def index_partial
    index
    render "_index_partial", layout: false
  end

  def show
    @page_title = "Representation Session"
    column = params[:id].length == 8 ? "truncated_id" : "id"
    @representation_session = current_collective.representation_sessions.find_by!(column => params[:id])
    respond_to do |format|
      format.html
      format.md
    end
  end

  def represent
    # Collective representation page - only shows option to represent the collective itself.
    # User representation is initiated from the trustee authorizations settings page instead.
    @can_represent_collective = @current_user.collective_member&.can_represent?

    unless @can_represent_collective
      # TODO: - design a better solution for this
      @sidebar_mode = "minimal"
      return respond_to do |format|
        format.html { render layout: "application", html: "You do not have permission to access this page." }
        format.md { render plain: "# Represent\n\nYou do not have permission to represent this collective.", status: :forbidden }
      end
    end

    @page_title = "Represent"
    respond_to do |format|
      format.html
      format.md
    end
  end

  # Markdown/MCP actions index for the collective represent page.
  # Mirrors TrusteeGrantsController#actions_index_show — evaluates the same
  # conditional-action lambdas the markdown frontmatter uses, so discovery
  # over /actions agrees with what fetch_page advertises.
  def actions_index_represent
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/represent")
    static = (route_info && route_info[:actions]) || []
    context = { collective: current_collective, user: @current_user }
    conditional = (route_info && route_info[:conditional_actions] || []).select do |action|
      action[:condition].call(context)
    rescue StandardError
      false
    end
    render_actions_index({ actions: static + conditional })
  end

  # =========================================================================
  # START REPRESENTATION (Markdown/MCP action) — collective representation
  # Mirrors TrusteeGrantsController#{describe,execute}_start_representation.
  # =========================================================================

  def describe_start_representation
    render_action_description(ActionsHelper.action_description("start_representation", resource: current_collective))
  end

  def execute_start_representation
    if current_representation_session
      return render_action_error({
                                   action_name: "start_representation",
                                   resource: current_collective,
                                   error: "Nested representation sessions are not allowed. End your current session before starting a new one.",
                                   status: :conflict,
                                 })
    end

    unless @current_user.can_represent?(current_collective)
      return render_action_error({
                                   action_name: "start_representation",
                                   resource: current_collective,
                                   error: "You do not have permission to represent this collective.",
                                   status: :forbidden,
                                 })
    end

    if current_collective.archived?
      return render_action_error({
                                   action_name: "start_representation",
                                   resource: current_collective,
                                   error: "This collective is deactivated and cannot be represented.",
                                   status: :conflict,
                                 })
    end

    rep_session = RepresentationSession.create!(
      tenant: current_tenant,
      collective: current_collective,
      representative_user: current_user,
      confirmed_understanding: true,
      began_at: Time.current
    )
    rep_session.begin!

    render_action_success({
                            action_name: "start_representation",
                            resource: rep_session,
                            result: "Representation session started. You are now acting on behalf of #{current_collective.name}.\n\n" \
                                    "Session ID: `#{rep_session.id}`\n" \
                                    "Short ID: `#{rep_session.truncated_id}`\n\n" \
                                    "Use the session ID in the `X-Representation-Session-ID` header for subsequent API requests.",
                            redirect_to: "/representing",
                          })
  end

  # =========================================================================
  # END REPRESENTATION (Markdown/MCP action) — collective representation
  # =========================================================================

  def describe_end_representation
    render_action_description(ActionsHelper.action_description("end_representation", resource: current_collective))
  end

  def execute_end_representation
    # Resolve the active session by (collective, representative) rather than the
    # request's representation context: the caller may or may not send the
    # X-Representation-Session-ID header when ending, and this mirrors how the
    # trustee path finds its session by grant.
    caller_user = @api_token_user || @current_human_user || @current_user
    rep_session = RepresentationSession.find_by(
      collective: current_collective,
      representative_user: caller_user,
      ended_at: nil
    )

    unless rep_session&.active?
      return render_action_error({
                                   action_name: "end_representation",
                                   resource: current_collective,
                                   error: "No active representation session found for this collective.",
                                   status: :not_found,
                                 })
    end

    session_url = rep_session.url
    rep_session.end!
    session.delete(:representation_session_id)
    session.delete(:representing_user)
    session.delete(:representing_collective)

    render_action_success({
                            action_name: "end_representation",
                            resource: current_collective,
                            result: "Representation session ended. You are no longer acting on behalf of #{current_collective.name}.\n\n" \
                                    "Session record: #{session_url}",
                            redirect_to: current_collective.path,
                          })
  end

  # Start a collective representation session
  def start_representing
    # Block nested representation sessions - a user can only represent one entity at a time
    if current_representation_session
      flash[:alert] = "Nested representation sessions are not allowed. End your current session before starting a new one."
      return redirect_to "/representing"
    end
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.collective_member.can_represent?

    if current_collective.archived?
      flash[:alert] = "This collective is deactivated and cannot be represented."
      return redirect_to "#{current_collective.path}/settings"
    end

    confirmed_understanding = ["true", "1"].include?(params[:understand])
    unless confirmed_understanding
      flash[:alert] = "You must check the box to confirm you understand."
      return redirect_to request.referer
    end
    rep_session = RepresentationSession.create!(
      tenant: current_tenant,
      collective: current_collective,
      representative_user: current_user,
      confirmed_understanding: confirmed_understanding,
      began_at: Time.current
    )
    rep_session.begin!
    # Set session cookies (matches API headers: X-Representation-Session-ID, X-Representing-Collective)
    session[:representation_session_id] = rep_session.id
    session[:representing_collective] = current_collective.handle
    redirect_to "/representing"
  end

  # Start a user representation session via trustee authorization
  def start_representing_user
    # Block nested representation sessions - a user can only represent one entity at a time
    if current_representation_session
      flash[:alert] = "Nested representation sessions are not allowed. End your current session before starting a new one."
      return redirect_to "/representing"
    end

    # Find the trustee authorization
    grant_id = params[:trustee_grant_id]
    return render status: :bad_request, plain: "400 Bad Request - trustee_grant_id required" unless grant_id

    # Find grant where current user is the trustee (they can act on behalf of the granting user)
    grant = TrusteeGrant.find_by(id: grant_id, trustee_user: current_user)
    unless grant&.active?
      flash[:alert] = "Trustee authorization not found or not active."
      return redirect_to request.referer || root_path
    end

    # Verify the grant allows the current collective context
    unless grant.allows_collective?(current_collective)
      flash[:alert] = "This trustee authorization does not include this collective."
      return redirect_to request.referer || root_path
    end

    confirmed_understanding = ["true", "1"].include?(params[:understand])
    unless confirmed_understanding
      flash[:alert] = "You must confirm you understand."
      return redirect_to request.referer || root_path
    end

    begin
      rep_session = api_helper.start_user_representation_session(grant: grant)
    rescue ArgumentError => e
      flash[:alert] = e.message
      return redirect_to request.referer || root_path
    end

    # Set session cookies (matches API headers: X-Representation-Session-ID, X-Representing-User)
    session[:representation_session_id] = rep_session.id
    session[:representing_user] = grant.granting_user.handle
    redirect_to "/representing"
  end

  def representing
    @page_title = "Representing"
    @sidebar_mode = "none"
    @representation_session = current_representation_session

    unless @representation_session
      return respond_to do |format|
        format.html { redirect_to root_path }
        format.md { render plain: "# Not representing\n\nYou have no active representation session.", status: :ok }
      end
    end

    @collective = @representation_session.collective
    # For user representation, use the represented user's (granting_user/ai_agent) collectives, not the parent's
    collectives_user = @representation_session.user_representation? ? @representation_session.represented_user : current_user
    @other_collectives = collectives_user.collectives.listable.where.not(id: @current_tenant.main_collective_id)

    respond_to do |format|
      format.html
      format.md
    end
  end

  def stop_representing
    if params[:representation_session_id]
      column = params[:representation_session_id].length == 8 ? "truncated_id" : "id"
      rs = RepresentationSession.tenant_scoped_only.find_by(column => params[:representation_session_id])
    else
      rs = nil
    end
    @current_representation_session = current_representation_session || rs
    exists_and_active = @current_representation_session && @current_representation_session.active?
    # Check if acting user is representative: browser users via session, API users via token
    acting_user_is_rep = exists_and_active && (
      @current_human_user == @current_representation_session.representative_user ||
      @api_token_user == @current_representation_session.representative_user
    )
    if exists_and_active && acting_user_is_rep
      session_url = @current_representation_session.url
      @current_representation_session.end!
      session.delete(:representation_session_id)
      session.delete(:representing_user)
      session.delete(:representing_collective)

      respond_to do |format|
        format.html do
          flash[:notice] = "Your representation session has ended. A record of this session can be found [here](#{session_url})."
          redirect_to current_collective.path
        end
        format.md { render plain: "# Session Ended\n\nYour representation session has ended.\n\nSession record: #{session_url}" }
        format.json { render json: { message: "Representation session ended", session_url: session_url } }
      end
    else
      respond_to do |format|
        format.html do
          flash[:alert] = "Could not find representation session."
          redirect_to current_collective.path
        end
        format.md { render plain: "# Error\n\nCould not find representation session.", status: :not_found }
        format.json { render json: { error: "Could not find representation session" }, status: :not_found }
      end
    end
  end

  def stop_representing_user
    @current_representation_session = current_representation_session
    exists_and_active = @current_representation_session && @current_representation_session.active?
    # Check if acting user is representative: browser users via session, API users via token
    acting_user_is_rep = exists_and_active && (
      @current_human_user == @current_representation_session.representative_user ||
      @api_token_user == @current_representation_session.representative_user
    )
    if exists_and_active && acting_user_is_rep
      grant = @current_representation_session.trustee_grant
      session_url = @current_representation_session.url
      @current_representation_session.end!
      session.delete(:representation_session_id)
      session.delete(:representing_user)
      session.delete(:representing_collective)

      respond_to do |format|
        format.html do
          flash[:notice] = "Your representation session has ended."
          if grant && @current_human_user
            redirect_to "/u/#{@current_human_user.handle}/settings/trustee-authorizations/#{grant.truncated_id}"
          else
            redirect_to root_path
          end
        end
        format.md { render plain: "# Session Ended\n\nYour representation session has ended.\n\nSession record: #{session_url}" }
        format.json { render json: { message: "Representation session ended", session_url: session_url } }
      end
    else
      respond_to do |format|
        format.html do
          flash[:alert] = "Could not find representation session."
          redirect_to root_path
        end
        format.md { render plain: "# Error\n\nCould not find representation session.", status: :not_found }
        format.json { render json: { error: "Could not find representation session" }, status: :not_found }
      end
    end
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "settings"
    @team = @current_collective.team
  end

  def current_resource_model
    RepresentationSession
  end

  def current_resource
    return @current_resource if defined?(@current_resource)

    if params[:representation_session_id]
      column = params[:representation_session_id].length == 8 ? "truncated_id" : "id"
      @current_resource = current_collective.representation_sessions.find_by!(column => params[:representation_session_id])
    else
      super
    end
    @current_resource
  end
end
