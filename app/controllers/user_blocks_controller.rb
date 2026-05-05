# typed: false

class UserBlocksController < ApplicationController
  before_action :require_user

  def index
    @user_blocks = current_user.user_blocks_given.includes(:blocked)
    @page_title = "Blocked Users"

    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    blocked_user = User.find(params[:blocked_id])
    user_block = current_user.user_blocks_given.build(blocked: blocked_user)

    if user_block.save
      notify_chat_blocked(blocked_user)
      flash[:notice] = "#{blocked_user.display_name || blocked_user.name} has been blocked."
    else
      flash[:alert] = user_block.errors.full_messages.join(", ")
    end

    redirect_back fallback_location: "/user-blocks"
  end

  def destroy
    user_block = current_user.user_blocks_given.find_by(id: params[:id])

    if user_block.nil?
      head :not_found
      return
    end

    blocked_name = user_block.blocked.display_name || user_block.blocked.name
    user_block.destroy!
    flash[:notice] = "#{blocked_name} has been unblocked."
    redirect_to "/user-blocks"
  end

  private

  def notify_chat_blocked(blocked_user)
    one, two = [current_user.id, blocked_user.id].sort
    session = ChatSession.tenant_scoped_only(current_tenant.id).find_by(
      user_one_id: one,
      user_two_id: two,
    )
    return unless session

    ChatSessionChannel.broadcast_to(session, { type: "blocked" })
  end

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.md { render plain: "# Error\n\nYou must be logged in.", status: :unauthorized }
    end
  end
end
