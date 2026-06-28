# typed: false
# frozen_string_literal: true

# Renders a markdown preview for text-entry forms, so users can see how their
# markdown will render before posting it. The rendering goes through the same
# MarkdownRenderer used to display posted content, so the preview matches the
# final result (including sanitization and reference linking).
class MarkdownPreviewsController < ApplicationController
  # Cap the amount of text we render in a single preview request. This is well
  # above any real note/comment length and exists only to bound work per request.
  MAX_PREVIEW_LENGTH = 100_000

  def create
    text = params[:text].to_s

    if text.length > MAX_PREVIEW_LENGTH
      render html: helpers.tag.p("Too much text to preview.", class: "pulse-md-empty"), status: :unprocessable_entity
      return
    end

    if text.strip.empty?
      render html: helpers.tag.p("Nothing to preview.", class: "pulse-md-empty")
      return
    end

    inline = params[:inline].to_s == "true"
    rendered = inline ? helpers.markdown_inline(text) : helpers.markdown(text)
    render html: rendered
  end

  private

  # No single resource backs this endpoint.
  def current_resource_model
    nil
  end
end
