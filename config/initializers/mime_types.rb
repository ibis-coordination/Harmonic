Mime::Type.register "text/markdown", :md

# Markdown responses are text, not HTML, so ERB must not HTML-escape their
# interpolations: agents would read `&amp;` and `&quot;` in place of what users
# wrote. Pages that turn markdown into HTML sanitize it in MarkdownRenderer.
ActionView::Template::Handlers::ERB.escape_ignore_list << "text/markdown"
