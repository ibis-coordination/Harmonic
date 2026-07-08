# typed: false

# RepresentationPolicy centralizes "where may an active representation act?"
# into a single before_action, replacing the previously lazy (and therefore
# dead) path guard that lived inside ApplicationController#current_representation_session.
#
# Background (Harmonic#419): the old guard ran inside the *memoized*
# current_representation_session helper. Once a resolver
# (resolve_browser_representation / resolve_api_representation) had assigned
# @current_representation_session, the helper returned it immediately and the
# path check below it never executed. So in the browser flow, navigating
# directly to a top-level route like /chat or /settings while representing
# quietly rendered the representative's own personal surface while the
# representation session stayed silently active — the confusing "in-between"
# #419 flags.
#
# Running the check as a real before_action (this module) means no route can
# dodge it, regardless of whether the session has already been memoized.
#
# Policy (per the #454 decision):
#   * User representation — you are acting as the represented identity, so the
#     represented experience is broad: the public space (/, /about), the
#     /representing dashboard, and collective-scoped pages (/collectives/*) all
#     render normally (grant collective-scope and private-workspace blocks are
#     enforced separately in ApplicationController#validate_authenticated_access,
#     before any spurious membership is created). What is blocked is the
#     *representative's own personal surfaces* — /chat and /settings — which are
#     what #419 flags and what PR #417 hid from the nav. Hitting them drops back
#     to /representing instead of quietly rendering a personal surface while the
#     session stays silently active.
#   * Collective representation — route through: a collective acting as itself
#     may reach its own surfaces, including /chat and /settings, so it can act
#     and edit its public profile as the collective.
module RepresentationPolicy
  extend ActiveSupport::Concern

  # Top-level personal surfaces that a *user* representation must not render.
  # Matched as whole path segments (the prefix itself or a "<prefix>/…"
  # sub-path), so /chat, /chat/:handle, /settings and /settings/two-factor are
  # all covered while unrelated paths like /chatter are not.
  REPRESENTATIVE_PERSONAL_SURFACES = ["/chat", "/settings"].freeze

  private

  def enforce_representation_scope!
    # Browser flow only. API/MCP representation is validated in
    # resolve_api_representation (session lookup + X-Representing-* headers) and
    # signals failures with JSON errors, not redirects; #419 is a browser-nav
    # bug.
    return if api_token_present?

    session = current_representation_session
    return unless session&.active?

    # Collective representation routes through to the collective's own
    # surfaces; it may reach /chat and /settings as itself.
    return unless session.user_representation?

    return unless representative_personal_surface?(request.path)

    redirect_to "/representing"
  end

  def representative_personal_surface?(path)
    REPRESENTATIVE_PERSONAL_SURFACES.any? do |prefix|
      path == prefix || path.start_with?("#{prefix}/")
    end
  end
end
