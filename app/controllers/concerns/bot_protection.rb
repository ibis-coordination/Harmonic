# typed: false

# BotProtection — honeypot + minimum-form-time + Cloudflare Turnstile gating
# for unauthenticated or low-friction POSTs (signup invite-code submit,
# password reset, identity register/callback, etc.).
#
# Usage:
#   class SomeController < ApplicationController
#     include BotProtection
#     protect_from_bots only: [:create]
#     # protect_from_bots only: [:verify], turnstile: false  # honeypot only
#   end
#
# Defenses (in order, fastest first):
#   1. Honeypot field — invisible input that legitimate users leave blank.
#   2. Min form time  — form must have been rendered at least N seconds before
#                       submit (catches naive scripts that immediately POST).
#   3. Turnstile      — Cloudflare-managed challenge. Disabled when
#                       TURNSTILE_SECRET_KEY is unset (dev/test/CI no-op).
#
# On detection: we silently redirect_back with a generic flash. We do not tell
# the bot which signal tripped, because that's a free oracle for tuning.
#
# Test mode: disabled unless ENV["FORCE_BOT_PROTECTION_IN_TEST"] is set, so
# existing test fixtures don't need to fill the honeypot/timestamp. Tests that
# exercise the bot defenses set the env var in their setup.
module BotProtection
  extend ActiveSupport::Concern

  HONEYPOT_FIELD = "company_website".freeze
  HONEYPOT_TIMESTAMP_FIELD = "form_render_ts".freeze
  TURNSTILE_TOKEN_FIELD = "cf_turnstile_response".freeze
  # 1 second is enough to catch naive scripts that POST without rendering;
  # anything higher risks tripping legitimate users on password-manager
  # autofill submits.
  MIN_FORM_TIME_SECONDS = 1

  class_methods do
    # Adds a before_action that enforces honeypot + (optionally) Turnstile.
    # Pass `turnstile: false` to skip the Turnstile check on this action
    # (e.g. for 2FA verify, where the user already authenticated with a
    # password and we don't want to add a second friction surface).
    def protect_from_bots(turnstile: true, **action_filter_opts)
      before_action(**action_filter_opts) do
        run_bot_protection(turnstile: turnstile)
      end
    end
  end

  private

  def run_bot_protection(turnstile: true)
    return if bot_protection_disabled?

    if honeypot_failed? || submitted_too_fast?
      log_bot_signal(reason: "honeypot")
      redirect_back_on_bot_detected
      return
    end

    return unless turnstile && turnstile_enabled?

    ok = TurnstileVerifier.verify(
      token: params[TURNSTILE_TOKEN_FIELD],
      ip: request.remote_ip
    )
    return if ok

    log_bot_signal(reason: "turnstile")
    redirect_back_on_bot_detected
  end

  def honeypot_failed?
    params[HONEYPOT_FIELD].to_s.strip.present?
  end

  # Missing timestamp does NOT trip the time check — a bot that strips the
  # timestamp field will already fail the honeypot (which is always rendered
  # alongside it), and we don't want to penalize legitimate sessions where
  # the field got dropped (e.g. cached form without the partial).
  def submitted_too_fast?
    ts = params[HONEYPOT_TIMESTAMP_FIELD].to_s
    return false if ts.blank?

    Time.current - Time.zone.at(ts.to_i) < MIN_FORM_TIME_SECONDS
  end

  def turnstile_enabled?
    ENV["TURNSTILE_SECRET_KEY"].to_s.present?
  end

  def bot_protection_disabled?
    Rails.env.test? && ENV["FORCE_BOT_PROTECTION_IN_TEST"].to_s.empty?
  end

  def redirect_back_on_bot_detected
    flash[:alert] ||= "Submission could not be processed. Please try again."
    redirect_back(fallback_location: "/login")
  end

  def log_bot_signal(reason:)
    SecurityAuditLog.log_bot_signal(
      ip: request.remote_ip,
      path: request.path,
      reason: reason,
      user_id: session[:user_id]
    )
  end
end
