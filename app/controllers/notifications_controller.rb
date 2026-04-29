# typed: false

class NotificationsController < ApplicationController
  before_action :require_user

  def index
    @sidebar_mode = 'minimal'
    # Set only tenant scope (not collective scope) to allow loading events from all collectives
    # This is needed because notifications span all collectives, not just the current one
    Tenant.scope_thread_to_tenant(subdomain: request.subdomain)

    # Show immediate notifications and due reminders (not future scheduled)
    @notification_recipients = NotificationRecipient
      .where(user: current_user)
      .in_app
      .not_scheduled
      .where.not(status: "dismissed")
      .includes(:notification)
      .order(created_at: :desc)
      .limit(50)

    # Manually load collectives to bypass association scoping
    # Events and Collectives are scoped to tenant and collective, but we need to load
    # collectives from all collectives for the current tenant.
    # We avoid using nr.notification.event because the Event default_scope interferes.
    # Instead, we query event_id directly from the notifications table.
    notification_ids = @notification_recipients.map(&:notification_id)
    notification_event_map = Notification.tenant_scoped_only.where(id: notification_ids).pluck(:id, :event_id).to_h

    event_ids = notification_event_map.values.compact
    event_collective_map = Event.tenant_scoped_only.where(id: event_ids).pluck(:id, :collective_id).to_h

    collective_ids = event_collective_map.values.compact.uniq
    collectives = Collective.tenant_scoped_only.where(id: collective_ids).index_by(&:id)

    # Build a lookup for notification recipient -> collective
    @collective_for_nr = {}
    @notification_recipients.each do |nr|
      event_id = notification_event_map[nr.notification_id]
      collective_id = event_id ? event_collective_map[event_id] : nil
      @collective_for_nr[nr.id] = collective_id ? collectives[collective_id] : nil
    end

    # Group notifications by collective
    # Notifications without an event (reminders) go into a nil key
    @notifications_by_collective = @notification_recipients.group_by do |nr|
      @collective_for_nr[nr.id]
    end

    # Now set the full scope for other controller methods
    @current_tenant = Tenant.find_by(id: Tenant.current_id)

    @unread_count = NotificationService.unread_count_for(current_user, tenant: current_tenant)
    @page_title = @unread_count > 0 ? "(#{@unread_count}) Notifications" : "Notifications"
  end

  def unread_count
    count = NotificationService.unread_count_for(current_user, tenant: current_tenant)
    render json: { count: count }
  end

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route('/notifications'))
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

  def describe_dismiss_all
    render_action_description(ActionsHelper.action_description("dismiss_all", resource: nil))
  end

  def execute_dismiss_all
    NotificationService.dismiss_all_for(current_user, tenant: current_tenant)

    respond_to do |format|
      format.json { render json: { success: true, action: "dismiss_all" } }
      format.html { render json: { success: true, action: "dismiss_all" } }
      format.md do
        render_action_success({
          action_name: "dismiss_all",
          resource: nil,
          result: "All notifications dismissed.",
        })
      end
    end
  end

  def describe_dismiss_for_collective
    render_action_description(ActionsHelper.action_description("dismiss_for_collective", resource: nil))
  end

  def execute_dismiss_for_collective
    collective_id = params[:collective_id]

    # Special case: "reminders" dismisses notifications without an event
    if collective_id == "reminders"
      count = NotificationService.dismiss_all_reminders(current_user, tenant: current_tenant)
      collective_name = "Reminders"
    else
      collective = Collective.find_by(id: collective_id)
      if collective.nil?
        return respond_to do |format|
          format.json { render json: { success: false, error: "Collective not found." }, status: :not_found }
          format.html { render json: { success: false, error: "Collective not found." }, status: :not_found }
          format.md do
            render_action_error({
              action_name: "dismiss_for_collective",
              resource: nil,
              error: "Collective not found.",
            })
          end
        end
      end

      count = NotificationService.dismiss_all_for_collective(current_user, tenant: current_tenant, collective_id: collective.id)
      collective_name = collective.name
    end

    respond_to do |format|
      format.json { render json: { success: true, action: "dismiss_for_collective", collective_id: collective_id, count: count } }
      format.html { render json: { success: true, action: "dismiss_for_collective", collective_id: collective_id, count: count } }
      format.md do
        render_action_success({
          action_name: "dismiss_for_collective",
          resource: nil,
          result: "#{count} notifications dismissed for #{collective_name}.",
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
