# typed: false

# RepresentationPolicy is the single place that answers the two representation
# questions, for every interface:
#
#   1. "Is this representation session valid, and what does it resolve to?"
#      -> representation_rejection_reason / apply_representation_session!
#         (the shared resolver gate, called by BOTH the browser-cookie and the
#         API/MCP-header resolvers in ApplicationController).
#   2. "Where may an active representation act?"
#      -> enforce_representation_scope! (a real before_action).
#
# Centralizing (1) means the validity sequence — session exists, not ended, not
# expired, grant still active, token/cookie user is the representative, and the
# representing credential matches — is defined ONCE and cannot drift between the
# browser and API transports. Before this, resolve_browser_representation and
# resolve_api_representation each open-coded the same six checks in the same
# order; the two could silently diverge (a check tightened on one transport and
# forgotten on the other), which is the same class of gap #419 exposed on the
# enforcement side. The transports still differ only in their thin I/O edges:
# how the session id and representing credential are read (cookies vs headers)
# and how a rejection is surfaced (clear+flash vs JSON 403).
#
# It also replaces the previously lazy (and therefore
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

  # Rejection reason -> API error string. The API transport renders these as
  # JSON 403s. Kept verbatim from the pre-unification resolve_api_representation
  # so API clients (and their tests) see the same messages.
  API_REJECTION_MESSAGES = {
    not_found: "Invalid representation session ID",
    ended: "Representation session has ended",
    expired: "Representation session has expired",
    grant_inactive: "Trustee authorization is no longer active",
    not_representative: "Token user is not the session's representative",
  }.freeze

  # Rejection reason -> browser flash. Only two reasons surface a flash; the
  # rest clear the stale representation silently. Kept verbatim from the
  # pre-unification resolve_browser_representation.
  BROWSER_REPRESENTATION_FLASH = {
    expired: "Representation session expired.",
    grant_inactive: "Trustee authorization is no longer active.",
  }.freeze

  private

  # The shared resolver gate. Runs the identical validity sequence for both
  # transports against an already-looked-up RepresentationSession and returns a
  # rejection reason symbol, or nil when the session passes every check.
  #
  # Pure: no rendering, no cookie/session mutation. The caller maps the reason
  # to its transport's failure surface (API_REJECTION_MESSAGES for JSON,
  # BROWSER_REPRESENTATION_FLASH for the browser) and computes the transport's
  # representing credential (X-Representing-* header vs representing_* cookie),
  # passing the boolean in as `credential_valid` so the credential match is part
  # of the one sequence too — in the same last-check position on both sides.
  def representation_rejection_reason(rep_session, representative_user, credential_valid:)
    return :not_found if rep_session.nil?
    return :ended if rep_session.ended?
    return :expired if rep_session.expired?
    return :grant_inactive if rep_session.trustee_grant && !rep_session.trustee_grant.active?
    return :not_representative unless rep_session.representative_user_id == representative_user.id
    return :invalid_credential unless credential_valid

    nil
  end

  # Applies a validated session: memoize it, set the representation context, and
  # swap @current_user to the effective (represented) user. Shared by both
  # transports so "what a valid session does" is also single-source. Returns the
  # effective user.
  def apply_representation_session!(rep_session)
    @current_representation_session = rep_session
    RepresentationContext.set!(rep_session.representative_user)
    @current_user = rep_session.effective_user
  end

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
