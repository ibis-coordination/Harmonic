# typed: false

class NotificationsController < ApplicationController
  layout 'pulse', only: [:index, :new]
  before_action :require_user

  def index
    @sidebar_mode = 'minimal'
    # Show immediate notifications and due reminders (not future scheduled)
    @notification_recipients = NotificationRecipient
      .where(user: current_user)
      .in_app
      .not_scheduled
      .where.not(status: "dismissed")
      .includes(notification: :event)
      .order(created_at: :desc)
      .limit(50)

    # Load future scheduled reminders separately
    @scheduled_reminders = ReminderService.scheduled_for(current_user)

    @unread_count = NotificationService.unread_count_for(current_user)
    @page_title = @unread_count > 0 ? "(#{@unread_count}) Notifications" : "Notifications"
  end

  def new
    @sidebar_mode = 'minimal'
    @page_title = "New Reminder"
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

    case value.to_s
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
