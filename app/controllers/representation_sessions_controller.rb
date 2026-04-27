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
    # User representation is initiated from the trustee grants settings page instead.
    @can_represent_collective = @current_user.collective_member&.can_represent?

    if @can_represent_collective
      @page_title = "Represent"
    else
      # TODO: - design a better solution for this
      @sidebar_mode = "minimal"
      render layout: "application", html: "You do not have permission to access this page."
    end
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

  # Start a user representation session via trustee grant
  def start_representing_user
    # Block nested representation sessions - a user can only represent one entity at a time
    if current_representation_session
      flash[:alert] = "Nested representation sessions are not allowed. End your current session before starting a new one."
      return redirect_to "/representing"
    end

    # Find the trustee grant
    grant_id = params[:trustee_grant_id]
    return render status: :bad_request, plain: "400 Bad Request - trustee_grant_id required" unless grant_id

    # Find grant where current user is the trustee (they can act on behalf of the granting user)
    grant = TrusteeGrant.find_by(id: grant_id, trustee_user: current_user)
    unless grant&.active?
      flash[:alert] = "Trustee grant not found or not active."
      return redirect_to request.referer || root_path
    end

    # Verify the grant allows the current collective context
    unless grant.allows_collective?(current_collective)
      flash[:alert] = "This trustee grant does not include this collective."
      return redirect_to request.referer || root_path
    end

    confirmed_understanding = ["true", "1"].include?(params[:understand])
    unless confirmed_understanding
      flash[:alert] = "You must confirm you understand."
      return redirect_to request.referer || root_path
    end

    rep_session = api_helper.start_user_representation_session(grant: grant)

    # Set session cookies (matches API headers: X-Representation-Session-ID, X-Representing-User)
    session[:representation_session_id] = rep_session.id
    session[:representing_user] = grant.granting_user.handle
    redirect_to "/representing"
  end

  def representing
    @page_title = "Representing"
    @sidebar_mode = "none"
    @representation_session = current_representation_session
    return redirect_to root_path unless @representation_session

    @collective = @representation_session.collective
    # For user representation, use the represented user's (granting_user/ai_agent) collectives, not the parent's
    collectives_user = @representation_session.user_representation? ? @representation_session.represented_user : current_user
    @other_collectives = collectives_user.collectives.not_private_workspace.where.not(id: @current_tenant.main_collective_id)
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
            redirect_to "/u/#{@current_human_user.handle}/settings/trustee-grants/#{grant.truncated_id}"
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
