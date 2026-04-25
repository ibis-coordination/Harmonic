# typed: true

class SidebarComponent < ViewComponent::Base
  extend T::Sig

  ADMIN_MODES = T.let(%w[system_admin app_admin tenant_admin].freeze, T::Array[String])
  VALID_MODES = T.let(%w[full resource settings minimal chat system_admin app_admin tenant_admin none].freeze, T::Array[String])

  sig do
    params(
      requested_mode: String,
      collective: T.nilable(Collective),
    ).void
  end
  def initialize(requested_mode: "full", collective: nil)
    super()
    @requested_mode = T.let(
      VALID_MODES.include?(requested_mode) ? requested_mode : "full",
      String,
    )
    @collective = collective
  end

  sig { returns(String) }
  def resolved_mode
    @resolved_mode = T.let(@resolved_mode, T.nilable(String)) unless defined?(@resolved_mode)
    @resolved_mode ||= compute_resolved_mode
  end

  private

  sig { returns(T::Boolean) }
  def show_sidebar?
    resolved_mode != "none"
  end

  sig { returns(String) }
  def sidebar_partial
    case resolved_mode
    when "full" then "pulse/sidebar"
    when "resource" then "pulse/sidebar_resource"
    when "settings" then "pulse/sidebar_settings"
    when "minimal" then "pulse/sidebar_minimal"
    when "chat" then "pulse/sidebar_chat"
    when "system_admin" then "pulse/sidebar_system_admin"
    when "app_admin" then "pulse/sidebar_app_admin"
    when "tenant_admin" then "pulse/sidebar_tenant_admin"
    else "pulse/sidebar"
    end
  end

  sig { returns(String) }
  def compute_resolved_mode
    return @requested_mode if admin_mode?
    return @requested_mode if @requested_mode == "chat"
    return "none" if @collective&.is_main_collective?

    @requested_mode
  end

  sig { returns(T::Boolean) }
  def admin_mode?
    ADMIN_MODES.include?(@requested_mode)
  end
end
