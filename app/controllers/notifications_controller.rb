# typed: false

class NotificationsController < ApplicationController
  before_action :require_user

  PUSH_BANNER_NOTICE_ID = "push-optin-banner".freeze

  def index
    @sidebar_mode = 'minimal'
    # Set only tenant scope (not collective scope) to allow loading events from all collectives
    # This is needed because notifications span all collectives, not just the current one
    Tenant.scope_thread_to_tenant(subdomain: request.subdomain)

    # Show immediate notifications and due reminders (not future scheduled).
    # Read notifications stay in the inbox until dismissed.
    @notification_recipients = NotificationRecipient
      .where(user: current_user)
      .in_app
      .not_scheduled
      .undismissed
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

    # Look up actors for tune_in notifications so the view can render a
    # "Tune in back" button per row. Batched: one Event query, one User
    # query, one TenantUser query — independent of recipient count.
    tune_in_recipients_with_event = @notification_recipients.filter_map do |nr|
      next unless nr.notification.notification_type == "tune_in"

      eid = notification_event_map[nr.notification_id]
      eid ? [nr.id, eid] : nil
    end

    tune_in_event_ids = tune_in_recipients_with_event.map { |_, eid| eid }.uniq
    event_actor_map = tune_in_event_ids.any? ?
      Event.tenant_scoped_only.where(id: tune_in_event_ids).pluck(:id, :actor_id).to_h :
      {}

    tune_in_actor_ids = event_actor_map.values.compact.uniq
    tune_in_actors_by_id = User.where(id: tune_in_actor_ids).index_by(&:id)
    if tune_in_actors_by_id.any?
      # Attach the TenantUser so #path returns the correct /u/:handle URL.
      TenantUser
        .where(tenant_id: @current_tenant.id, user_id: tune_in_actors_by_id.keys)
        .each { |tu| tune_in_actors_by_id[tu.user_id]&.tenant_user = tu }
    end

    @actor_for_tune_in_recipient = tune_in_recipients_with_event.each_with_object({}) do |(nr_id, eid), acc|
      actor = tune_in_actors_by_id[event_actor_map[eid]]
      acc[nr_id] = actor if actor
    end

    @tune_in_state = TuneInState.compute(
      viewer:     current_user,
      target_ids: tune_in_actor_ids,
      tenant:     @current_tenant,
    )

    @unread_count = NotificationService.unread_count_for(current_user, tenant: current_tenant)
    @page_title = @unread_count > 0 ? "(#{@unread_count}) Notifications" : "Notifications"
    @show_push_banner = show_push_banner?
  end

  # POST /notifications/dismiss-push-banner
  def dismiss_push_banner
    current_user.tenant_user&.dismiss_notice!(PUSH_BANNER_NOTICE_ID)
    redirect_to "/notifications"
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
            status: :not_found,
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
              status: :not_found,
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

  def describe_mark_read
    render_action_description(ActionsHelper.action_description("mark_read", resource: nil))
  end

  def execute_mark_read
    recipient = NotificationRecipient.find_by(id: params[:id], user: current_user)

    respond_to do |format|
      if recipient
        recipient.mark_read!
        format.json { render json: { success: true, id: recipient.id, action: "mark_read" } }
        format.html { render json: { success: true, id: recipient.id, action: "mark_read" } }
        format.md do
          render_action_success({
            action_name: "mark_read",
            resource: nil,
            result: "Notification marked read.",
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
            status: :not_found,
          })
        end
      end
    end
  end

  def describe_mark_all_read
    render_action_description(ActionsHelper.action_description("mark_all_read", resource: nil))
  end

  def execute_mark_all_read
    count = NotificationService.mark_all_read_for(current_user, tenant: current_tenant)

    respond_to do |format|
      format.json { render json: { success: true, action: "mark_all_read", count: count } }
      format.html { render json: { success: true, action: "mark_all_read", count: count } }
      format.md do
        render_action_success({
          action_name: "mark_all_read",
          resource: nil,
          result: "#{count} notifications marked read.",
        })
      end
    end
  end

  def describe_mark_read_for_collective
    render_action_description(ActionsHelper.action_description("mark_read_for_collective", resource: nil))
  end

  def execute_mark_read_for_collective
    collective_id = params[:collective_id]

    # Special case: "reminders" marks notifications without an event
    if collective_id == "reminders"
      count = NotificationService.mark_all_read_reminders(current_user, tenant: current_tenant)
      collective_name = "Reminders"
    else
      collective = Collective.find_by(id: collective_id)
      if collective.nil?
        return respond_to do |format|
          format.json { render json: { success: false, error: "Collective not found." }, status: :not_found }
          format.html { render json: { success: false, error: "Collective not found." }, status: :not_found }
          format.md do
            render_action_error({
              action_name: "mark_read_for_collective",
              resource: nil,
              error: "Collective not found.",
              status: :not_found,
            })
          end
        end
      end

      count = NotificationService.mark_all_read_for_collective(current_user, tenant: current_tenant, collective_id: collective.id)
      collective_name = collective.name
    end

    respond_to do |format|
      format.json { render json: { success: true, action: "mark_read_for_collective", collective_id: collective_id, count: count } }
      format.html { render json: { success: true, action: "mark_read_for_collective", collective_id: collective_id, count: count } }
      format.md do
        render_action_success({
          action_name: "mark_read_for_collective",
          resource: nil,
          result: "#{count} notifications marked read for #{collective_name}.",
        })
      end
    end
  end

  def describe_dismiss_for_chat
    render_action_description(ActionsHelper.action_description("dismiss_for_chat", resource: nil))
  end

  def execute_dismiss_for_chat
    partner = TenantUser.tenant_scoped_only(current_tenant.id).find_by(handle: params[:handle])&.user

    respond_to do |format|
      if partner
        NotificationService.dismiss_chat_notifications_from!(user: current_user, sender: partner, tenant: current_tenant)
        format.json { render json: { success: true, action: "dismiss_for_chat", handle: params[:handle] } }
        format.html { render json: { success: true, action: "dismiss_for_chat", handle: params[:handle] } }
        format.md do
          render_action_success({
            action_name: "dismiss_for_chat",
            resource: nil,
            result: "Chat notifications dismissed.",
          })
        end
      else
        format.json { render json: { success: false, error: "User not found." }, status: :not_found }
        format.html { render json: { success: false, error: "User not found." }, status: :not_found }
        format.md do
          render_action_error({
            action_name: "dismiss_for_chat",
            resource: nil,
            error: "User not found.",
            status: :not_found,
          })
        end
      end
    end
  end

  private

  # The push opt-in banner shows to humans on push-enabled tenants who have
  # no registered device and haven't dismissed it. A subscription on ANY
  # device hides it everywhere — they know the feature exists; don't nag.
  def show_push_banner?
    return false unless @current_tenant.web_push_available?
    return false unless current_user.human?

    tenant_user = current_user.tenant_user
    return false if tenant_user.nil?
    return false if tenant_user.dismissed_notices.include?(PUSH_BANNER_NOTICE_ID)

    !current_user.web_push_subscriptions.active.exists?
  end

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to view notifications.", status: :unauthorized }
    end
  end
end
