# typed: false

class NotificationsController < ApplicationController
  before_action :require_user

  def index
    @sidebar_mode = 'minimal'
    # Set only tenant scope (not collective scope) to allow loading events from all studios
    # This is needed because notifications span all studios, not just the current one
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
    # collectives from all studios for the current tenant.
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

    # Group notifications by collective (studio)
    # Notifications without an event (reminders) go into a nil key
    @notifications_by_collective = @notification_recipients.group_by do |nr|
      @collective_for_nr[nr.id]
    end

    # Now set the full scope for other controller methods
    @current_tenant = Tenant.find_by(id: Tenant.current_id)

    # Load future scheduled reminders separately
    @scheduled_reminders = ReminderService.scheduled_for(current_user)

    @unread_count = NotificationService.unread_count_for(current_user, tenant: current_tenant)
    @page_title = @unread_count > 0 ? "(#{@unread_count}) Notifications" : "Notifications"
  end

  def new
    @sidebar_mode = 'minimal'
    @page_title = "New Reminder"
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

  def describe_dismiss_for_studio
    render_action_description(ActionsHelper.action_description("dismiss_for_studio", resource: nil))
  end

  def execute_dismiss_for_studio
    studio_id = params[:studio_id]

    # Special case: "reminders" dismisses notifications without an event
    if studio_id == "reminders"
      count = NotificationService.dismiss_all_reminders(current_user, tenant: current_tenant)
      studio_name = "Reminders"
    else
      studio = Collective.find_by(id: studio_id)
      if studio.nil?
        return respond_to do |format|
          format.json { render json: { success: false, error: "Studio not found." }, status: :not_found }
          format.html { render json: { success: false, error: "Studio not found." }, status: :not_found }
          format.md do
            render_action_error({
              action_name: "dismiss_for_studio",
              resource: nil,
              error: "Studio not found.",
            })
          end
        end
      end

      count = NotificationService.dismiss_all_for_collective(current_user, tenant: current_tenant, collective_id: studio.id)
      studio_name = studio.name
    end

    respond_to do |format|
      format.json { render json: { success: true, action: "dismiss_for_studio", studio_id: studio_id, count: count } }
      format.html { render json: { success: true, action: "dismiss_for_studio", studio_id: studio_id, count: count } }
      format.md do
        render_action_success({
          action_name: "dismiss_for_studio",
          resource: nil,
          result: "#{count} notifications dismissed for #{studio_name}.",
        })
      end
    end
  end

  def describe_create_reminder
    render_action_description(ActionsHelper.action_description("create_reminder", resource: nil))
  end

  def execute_create_reminder
    title = params[:title]
    body = params[:body]
    url = params[:url]
    timezone = params[:timezone]
    scheduled_for = parse_scheduled_time(params[:scheduled_for], timezone: timezone)

    if title.blank?
      return render_reminder_error("Title is required")
    end

    if scheduled_for.nil?
      return render_reminder_error("scheduled_for is required and must be a valid time")
    end

    begin
      notification = ReminderService.create!(
        user: current_user,
        title: title,
        body: body,
        scheduled_for: scheduled_for,
        url: url,
      )

      respond_to do |format|
        format.html { redirect_to notifications_path, notice: "Reminder scheduled" }
        format.json { render json: { success: true, id: notification.id, scheduled_for: scheduled_for.iso8601 } }
        format.md do
          render_action_success({
            action_name: "create_reminder",
            resource: nil,
            result: "Reminder scheduled for #{scheduled_for.strftime('%Y-%m-%d %H:%M %Z')}",
          })
        end
      end
    rescue ReminderService::ReminderLimitExceeded => e
      render_reminder_error(e.message)
    rescue ReminderService::ReminderRateLimitExceeded => e
      render_reminder_error(e.message)
    rescue ReminderService::ReminderSchedulingError => e
      render_reminder_error(e.message)
    rescue StandardError => e
      render_reminder_error("Failed to create reminder: #{e.message}")
    end
  end

  def describe_delete_reminder
    render_action_description(ActionsHelper.action_description("delete_reminder", resource: nil))
  end

  def execute_delete_reminder
    nr = current_user.notification_recipients
      .joins(:notification)
      .where(notifications: { notification_type: "reminder" })
      .find_by(id: params[:id])

    if nr.nil?
      return render_reminder_error("Reminder not found", action_name: "delete_reminder")
    end

    begin
      ReminderService.delete!(nr)

      respond_to do |format|
        format.html { redirect_to notifications_path, notice: "Reminder deleted" }
        format.json { render json: { success: true } }
        format.md do
          render_action_success({
            action_name: "delete_reminder",
            resource: nil,
            result: "Reminder deleted.",
          })
        end
      end
    rescue StandardError => e
      render_reminder_error("Failed to delete reminder: #{e.message}", action_name: "delete_reminder")
    end
  end

  private

  def render_reminder_error(message, action_name: "create_reminder")
    respond_to do |format|
      format.html { redirect_to notifications_path, alert: message }
      format.json { render json: { success: false, error: message }, status: :unprocessable_entity }
      format.md do
        render_action_error({
          action_name: action_name,
          resource: nil,
          error: message,
        })
      end
    end
  end

  def parse_scheduled_time(value, timezone: nil)
    return nil if value.blank?

    result = case value.to_s
    when /^\d{10,}$/ # Unix timestamp (10+ digits)
      Time.at(value.to_i).utc
    when /^\d+[smhdw]$/i # Relative time: 30s, 5m, 1h, 2d, 1w
      parse_relative_time(value)
    when /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/ # datetime-local format (no timezone): 2024-01-22T14:00
      # Parse in provided timezone, or fall back to tenant's timezone, or UTC
      tz = timezone.present? ? ActiveSupport::TimeZone[timezone] : nil
      tz ||= @current_tenant&.timezone || ActiveSupport::TimeZone["UTC"]
      tz.parse(value).utc
    when /^\d{4}-\d{2}-\d{2}/ # ISO 8601 with timezone info
      Time.parse(value).utc
    else
      # Try parsing as a general datetime string
      Time.parse(value).utc
    end

    # Ensure we return ActiveSupport::TimeWithZone for Sorbet type checking
    result&.in_time_zone("UTC")
  rescue ArgumentError, TypeError
    nil
  end

  def parse_relative_time(value)
    match = value.to_s.match(/^(\d+)([smhdw])$/i)
    return nil unless match

    amount = match[1].to_i
    unit = match[2].downcase

    case unit
    when "s"
      amount.seconds.from_now
    when "m"
      amount.minutes.from_now
    when "h"
      amount.hours.from_now
    when "d"
      amount.days.from_now
    when "w"
      amount.weeks.from_now
    else
      nil
    end
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
