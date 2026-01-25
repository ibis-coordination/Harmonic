# typed: false

class RepresentationSessionsController < ApplicationController
  layout 'pulse', only: [:index, :show, :representing]
  before_action :set_sidebar_mode, only: [:index, :show, :representing]

  def index
    @representatives = current_superagent.representatives
    @page_title = 'Representation'
    @representation_sessions = current_tenant.representation_sessions.where.not(ended_at: nil).order(ended_at: :desc).limit(100)
    @active_sessions = current_tenant.representation_sessions.where(ended_at: nil).order(began_at: :desc).limit(100)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def index_partial
    index
    render '_index_partial', layout: false
  end

  def show
    @page_title = 'Representation Session'
    column = params[:id].length == 8 ? 'truncated_id' : 'id'
    @representation_session = current_superagent.representation_sessions.find_by!(column => params[:id])
    respond_to do |format|
      format.html
      format.md
    end
  end

  def represent
    if @current_user.superagent_member.can_represent?
      @page_title = "Represent #{current_superagent.name}"
    else
      # TODO - design a better solution for this
      return render layout: 'application', html: 'You do not have permission to access this page.'
    end
  end

  def start_representing
    if current_representation_session
      flash[:alert] = 'You have already started a representation session. You must end it before starting a new one.'
      return redirect_to request.referrer
    end
    return render status: 403, plain: '403 Unauthorized' unless current_user.superagent_member.can_represent?
    confirmed_understanding = params[:understand] == 'true' || params[:understand] == '1'
    unless confirmed_understanding
      flash[:alert] = 'You must check the box to confirm you understand.'
      return redirect_to request.referrer
    end
    trustee = current_superagent.trustee_user
    rep_session = RepresentationSession.create!(
      tenant: current_tenant,
      superagent: current_superagent,
      representative_user: current_user,
      trustee_user: trustee,
      confirmed_understanding: confirmed_understanding,
      began_at: Time.current,
    )
    rep_session.begin!
    # NOTE - both cookies need to be set for ApplicationController#current_user
    # to find the current RepresentationSession outside the scope of current_superagent
    session[:trustee_user_id] = trustee.id
    session[:representation_session_id] = rep_session.id
    redirect_to '/representing'
  end

  def representing
    @page_title = 'Representing'
    @representation_session = current_representation_session
    return redirect_to root_path unless @representation_session
    @studio = @representation_session.superagent
    @other_studios = current_user.superagents.where.not(id: @current_tenant.main_superagent_id)
  end

  def stop_representing
    if params[:representation_session_id]
      column = params[:representation_session_id].length == 8 ? 'truncated_id' : 'id'
      rs = RepresentationSession.unscoped.find_by(column => params[:representation_session_id])
    else
      rs = nil
    end
    @current_representation_session = current_representation_session || rs
    exists_and_active = @current_representation_session && @current_representation_session.active?
    acting_user_is_rep = exists_and_active && [@current_person_user, @current_subagent_user].include?(@current_representation_session.representative_user)
    # raise "#{exists_and_active} - #{acting_user_is_rep} - #{rs} #{@current_person_user.name} - #{@current_subagent_user.name}" unless exists_and_active && acting_user_is_rep
    if exists_and_active && acting_user_is_rep
      session_url = @current_representation_session.url
      @current_representation_session.end!
      session.delete(:trustee_user_id)
      session.delete(:representation_session_id)
      flash[:notice] = "Your representation session has ended. A record of this session can be found [here](#{session_url})."
    else
      flash[:alert] = 'Could not find representation session.'
    end
    redirect_to current_superagent.path
  end

  private

  def set_sidebar_mode
    @sidebar_mode = 'settings'
    @team = @current_superagent.team
  end

  def current_resource_model
    RepresentationSession
  end

  def current_resource
    return @current_resource if defined?(@current_resource)
    if params[:representation_session_id]
      column = params[:representation_session_id].length == 8 ? 'truncated_id' : 'id'
      @current_resource = current_superagent.representation_sessions.find_by!(column => params[:representation_session_id])
    else
      super
    end
    @current_resource
  end

end