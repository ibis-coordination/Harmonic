# typed: false

class NotificationsController < ApplicationController
  before_action :require_user

  def index
    @notification_recipients = NotificationRecipient
      .where(user: current_user)
      .in_app
      .where.not(status: "dismissed")
      .includes(notification: :event)
      .order(created_at: :desc)
      .limit(50)
    @unread_count = NotificationService.unread_count_for(current_user)
    @page_title = @unread_count > 0 ? "(#{@unread_count}) Notifications" : "Notifications"
  end

  def unread_count
    count = NotificationService.unread_count_for(current_user)
    render json: { count: count }
  end

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route('/notifications'))
  end

  def describe_mark_read
    render_action_description(ActionsHelper.action_description("mark_read", resource: nil))
  end

  def execute_mark_read
    recipient = NotificationRecipient.find_by(id: params[:id], user: current_user)

    respond_to do |format|
      if recipient
        recipient.read!
        format.json { render json: { success: true, id: recipient.id, action: "mark_read" } }
        format.html { render json: { success: true, id: recipient.id, action: "mark_read" } }
        format.md do
          render_action_success({
            action_name: "mark_read",
            resource: nil,
            result: "Notification marked as read.",
          })
        end
      else
        format.json { render json: { success: false, error: "Notification not found." }, status: :not_found }
        format.html { render json: { success: false, error: "Notification not found." }, status: :not_found }
        format.md do
          render_action_error({
            action_name: "mark_read",
            resource: nil,
            error: "Notification not found.",
          })
        end
      end
    end
  end

  def describe_dismiss
    render_action_description(ActionsHelper.action_description("dismiss", resource: nil))
  end

  def execute_dismiss
    recipient = NotificationRecipient.find_by(id: params[:id], user: current_user)

    respond_to do |format|
      if recipient
        recipient.dismiss!
        format.json { render json: { success: true, id: recipient.id, action: "dismiss" } }
        format.html { render json: { success: true, id: recipient.id, action: "dismiss" } }
        format.md do
          render_action_success({
            action_name: "dismiss",
            resource: nil,
            result: "Notification dismissed.",
          })
        end
      else
        format.json { render json: { success: false, error: "Notification not found." }, status: :not_found }
        format.html { render json: { success: false, error: "Notification not found." }, status: :not_found }
        format.md do
          render_action_error({
            action_name: "dismiss",
            resource: nil,
            error: "Notification not found.",
          })
        end
      end
    end
  end

  def describe_mark_all_read
    render_action_description(ActionsHelper.action_description("mark_all_read", resource: nil))
  end

  def execute_mark_all_read
    NotificationService.mark_all_read_for(current_user)

    respond_to do |format|
      format.json { render json: { success: true, action: "mark_all_read" } }
      format.html { render json: { success: true, action: "mark_all_read" } }
      format.md do
        render_action_success({
          action_name: "mark_all_read",
          resource: nil,
          result: "All notifications marked as read.",
        })
      end
    end
  end

  private

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to view notifications.", status: :unauthorized }
    end
  end
end
