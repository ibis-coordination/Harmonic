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
    inline = params[:inline].to_s == "true"

    if text.length > MAX_PREVIEW_LENGTH
      render html: empty_message("Too much text to preview.", inline:), status: :unprocessable_entity
      return
    end

    if text.strip.empty?
      render html: empty_message("Nothing to preview.", inline:)
      return
    end

    rendered = inline ? helpers.markdown_inline(text) : helpers.markdown(text)
    render html: rendered
  end

  private

  # Placeholder shown when there's nothing (or too much) to render. Inline
  # consumers (e.g. comments) get a span so it sits in their inline-styled pane;
  # block consumers get a paragraph.
  def empty_message(text, inline:)
    tag_name = inline ? :span : :p
    helpers.tag.public_send(tag_name, text, class: "pulse-md-empty")
  end

  # No single resource backs this endpoint.
  def current_resource_model
    nil
  end
end
