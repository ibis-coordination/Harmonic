# typed: true

# Redcarpet's render callbacks are implemented in C, so tapioca doesn't capture
# them and Sorbet can't see them. MarkdownRenderer::MentionRenderer overrides
# two of these callbacks and calls `super`, which requires Sorbet to know the
# methods exist on an ancestor. Declare them (untyped) here.
class Redcarpet::Render::HTML
  def normal_text(text); end
  def link(link, title, content); end
end
