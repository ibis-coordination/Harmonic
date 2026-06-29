require "test_helper"

class MarkdownRendererTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    # Set thread context for display_references
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  # === Basic Rendering Tests ===

  test "render returns HTML from markdown" do
    markdown = "# Hello World"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("Hello World")
    assert html.include?("<h")  # Header tag should be present
  end

  test "render handles nil content" do
    html = MarkdownRenderer.render(nil)
    assert_equal "", html
  end

  test "render handles empty string" do
    html = MarkdownRenderer.render("")
    assert_equal "", html
  end

  test "render converts bold text" do
    markdown = "This is **bold** text"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<strong>bold</strong>")
  end

  test "render converts italic text" do
    markdown = "This is *italic* text"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<em>italic</em>")
  end

  test "render does not treat intra-word underscores as italics" do
    markdown = "a_b c_d"
    html = MarkdownRenderer.render(markdown)

    # no_intra_emphasis keeps underscores inside/between words literal
    assert html.include?("a_b c_d"), "Expected underscores to be preserved literally: #{html}"
    assert_not html.include?("<em>"), "Expected no <em> tag for intra-word underscores: #{html}"
  end

  test "render still converts underscore-delimited italics" do
    markdown = "This is _italic_ text"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<em>italic</em>"), "Expected single-underscore emphasis to still render: #{html}"
  end

  test "render converts links" do
    markdown = "[Click here](https://example.com)"
    html = MarkdownRenderer.render(markdown)

    assert html.include?('href="https://example.com"')
    assert html.include?("Click here")
  end

  test "render preserves relative links" do
    markdown = "[Settings](/settings)"
    html = MarkdownRenderer.render(markdown, display_references: false)

    assert html.include?('href="/settings"'), "Expected relative link to be preserved in output: #{html}"
    assert html.include?("Settings")
  end

  test "render preserves relative links with paths" do
    markdown = "[User profile](/u/someuser)"
    html = MarkdownRenderer.render(markdown, display_references: false)

    assert html.include?('href="/u/someuser"'), "Expected relative link path to be preserved in output: #{html}"
    assert html.include?("User profile")
  end

  test "render preserves anchor links" do
    markdown = "[Jump to section](#section)"
    html = MarkdownRenderer.render(markdown, display_references: false)

    assert html.include?('href="#section"'), "Expected anchor link to be preserved in output: #{html}"
    assert html.include?("Jump to section")
  end

  test "absolute http(s) links to external hosts open in a new tab with the external-link class and octicon" do
    html = MarkdownRenderer.render("[Cursor docs](https://cursor.com/docs/mcp)")
    assert_includes html, 'target="_blank"'
    assert_match(/class="[^"]*external-link[^"]*"/, html)
    assert_match(/octicon-link-external/, html)
  end

  test "absolute links to the current tenant host are treated as internal" do
    html = MarkdownRenderer.render("[Settings](https://#{@tenant.domain}/u/handle/settings)", display_references: false)
    refute_includes html, 'target="_blank"'
    refute_match(/external-link/, html)
  end

  test "absolute links to other Harmonic subdomains are treated as internal" do
    other_host = "ideas.#{ENV['HOSTNAME']}"
    html = MarkdownRenderer.render("[Ideas](https://#{other_host}/help)", display_references: false)
    refute_includes html, 'target="_blank"'
    refute_match(/external-link/, html)
  end

  test "absolute links to the bare hostname are treated as internal" do
    html = MarkdownRenderer.render("[Root](https://#{ENV['HOSTNAME']}/help)", display_references: false)
    refute_includes html, 'target="_blank"'
    refute_match(/external-link/, html)
  end

  test "absolute links to hostnames that look-alike but aren't subdomains are external" do
    # evilharmonic.local should NOT be treated as harmonic.local
    html = MarkdownRenderer.render("[Lookalike](https://evil#{ENV['HOSTNAME']}/page)")
    assert_includes html, 'target="_blank"'
    assert_match(/external-link/, html)
  end

  test "relative links do not get target=_blank or external-link class" do
    html = MarkdownRenderer.render("[Settings](/settings)", display_references: false)
    refute_includes html, 'target="_blank"'
    refute_match(/external-link/, html)
  end

  test "anchor links do not get target=_blank or external-link class" do
    html = MarkdownRenderer.render("[Jump](#section)", display_references: false)
    refute_includes html, 'target="_blank"'
    refute_match(/external-link/, html)
  end

  test "mailto links do not get target=_blank" do
    html = MarkdownRenderer.render("[Email](mailto:foo@example.com)")
    refute_includes html, 'target="_blank"'
  end

  test "render converts unordered lists" do
    markdown = "- Item 1\n- Item 2\n- Item 3"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<ul>")
    assert html.include?("<li>")
  end

  test "render converts ordered lists" do
    markdown = "1. First\n2. Second\n3. Third"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<ol>")
    assert html.include?("<li>")
  end

  test "render converts code blocks" do
    markdown = "```ruby\nputs 'hello'\n```"
    html = MarkdownRenderer.render(markdown, display_references: false)

    # Fenced code blocks render as pre > code
    assert html.include?("<pre>") || html.include?("<code>")
    assert html.include?("puts")
  end

  test "render converts inline code" do
    markdown = "Use the `puts` method"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<code>puts</code>")
  end

  test "render converts blockquotes" do
    markdown = "> This is a quote"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<blockquote>")
  end

  test "render converts tables" do
    markdown = <<~MD
      | Header 1 | Header 2 |
      |----------|----------|
      | Cell 1   | Cell 2   |
    MD
    html = MarkdownRenderer.render(markdown, display_references: false)

    # Tables may render differently depending on redcarpet settings
    # Just verify the content is present
    assert html.include?("Header 1") || html.include?("Cell 1")
  end

  test "render converts tables to proper HTML table elements" do
    markdown = <<~MD
      | Header 1 | Header 2 |
      |----------|----------|
      | Cell 1   | Cell 2   |
    MD
    html = MarkdownRenderer.render(markdown, display_references: false)

    assert html.include?("<table>"), "Expected <table> tag in output: #{html}"
    assert html.include?("<th>"), "Expected <th> tag in output: #{html}"
    assert html.include?("<td>"), "Expected <td> tag in output: #{html}"
  end

  test "render preserves table thead and tbody elements" do
    markdown = <<~MD
      | Name | Age |
      |------|-----|
      | Alice | 30 |
      | Bob | 25 |
    MD
    html = MarkdownRenderer.render(markdown, display_references: false)

    assert html.include?("<thead>"), "Expected <thead> tag in output: #{html}"
    assert html.include?("<tbody>"), "Expected <tbody> tag in output: #{html}"
    assert html.include?("<tr>"), "Expected <tr> tag in output: #{html}"
  end

  # === Header Shifting Tests ===

  test "render shifts headers by default" do
    markdown = "# Heading 1\n## Heading 2"
    html = MarkdownRenderer.render(markdown)

    # h1 should become h2, h2 should become h3
    assert html.include?("<h2>")
    assert html.include?("<h3>")
    assert_not html.include?("<h1>")
  end

  test "render does not shift headers when shift_headers is false" do
    markdown = "# Heading 1\n## Heading 2"
    html = MarkdownRenderer.render(markdown, shift_headers: false)

    assert html.include?("<h1>")
    assert html.include?("<h2>")
  end

  # === Security Sanitization Tests ===

  test "render sanitizes script tags" do
    markdown = "<script>alert('xss')</script>"
    html = MarkdownRenderer.render(markdown, display_references: false)

    # Script tags are removed, content may remain but is not executable
    assert_not html.include?("<script>")
  end

  test "render sanitizes javascript links" do
    markdown = "[Click me](javascript:alert('xss'))"
    html = MarkdownRenderer.render(markdown, display_references: false)

    # safe_links_only prevents javascript: links from rendering as <a> tags
    assert_not html.include?('href="javascript:')
  end

  test "render adds rel noopener noreferrer to links" do
    markdown = "[External](https://example.com)"
    html = MarkdownRenderer.render(markdown)

    assert html.include?('rel="noopener noreferrer"')
  end

  test "render allows mailto links" do
    markdown = "[Email](mailto:test@example.com)"
    html = MarkdownRenderer.render(markdown)

    assert html.include?('href="mailto:test@example.com"')
  end

  test "render removes links with dangerous protocols" do
    markdown = "[Bad](data:text/html,<script>alert(1)</script>)"
    html = MarkdownRenderer.render(markdown, display_references: false)

    # data: protocol links should not render as clickable links
    assert_not html.include?('href="data:')
  end

  test "render sanitizes onclick handlers" do
    markdown = '<a href="#" onclick="alert(1)">Click</a>'
    html = MarkdownRenderer.render(markdown)

    assert_not html.include?("onclick")
  end

  # === Image Handling Tests ===

  test "render allows images with http/https" do
    markdown = "![Alt text](https://example.com/image.png)"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("<img")
    assert html.include?('src="https://example.com/image.png"')
  end

  test "render adds lazy loading to images" do
    markdown = "![Alt text](https://example.com/image.png)"
    html = MarkdownRenderer.render(markdown)

    assert html.include?('loading="lazy"')
  end

  test "render removes images with dangerous protocols" do
    # Note: markdown with javascript: protocol may not render as img tag
    # Test with data: protocol which would be a security risk
    markdown = "![Bad](data:image/png;base64,abc123)"
    html = MarkdownRenderer.render(markdown)

    # Either the image is removed entirely or the data: URL is stripped
    assert_not html.include?('src="data:')
  end

  # === render_inline Tests ===

  test "render_inline returns HTML without paragraph wrapper" do
    markdown = "Simple text"
    html = MarkdownRenderer.render_inline(markdown)

    assert_not html.include?("<p>")
    assert html.include?("Simple text")
  end

  test "render_inline converts inline formatting" do
    markdown = "**bold** and *italic*"
    html = MarkdownRenderer.render_inline(markdown)

    assert html.include?("<strong>bold</strong>")
    assert html.include?("<em>italic</em>")
  end

  test "render_inline sanitizes content" do
    markdown = "<script>bad</script>Safe text"
    html = MarkdownRenderer.render_inline(markdown)

    assert_not html.include?("<script>")
    assert html.include?("Safe text")
  end

  # === Hard Wrap Tests ===

  test "render creates line breaks with hard wrap" do
    markdown = "Line 1\nLine 2"
    html = MarkdownRenderer.render(markdown)

    # Hard wrap should convert single newlines to <br>
    assert html.include?("<br>") || html.include?("<br/>") || html.include?("<br />")
  end

  # === Complex Markdown Tests ===

  test "render handles complex nested markdown" do
    markdown = <<~MD
      # Main Title

      This is a paragraph with **bold** and *italic* text.

      ## Section 1

      - List item with `code`
      - Another item

      > A blockquote here

      ```python
      def hello():
          print("Hello")
      ```

      [Link](https://example.com)
    MD

    html = MarkdownRenderer.render(markdown)

    assert html.include?("Main Title")
    assert html.include?("<strong>bold</strong>")
    assert html.include?("<em>italic</em>")
    assert html.include?("<ul>")
    assert html.include?("<blockquote>")
    assert html.include?("<code>")
  end

  # === Display References Tests ===

  test "render with display_references true processes internal links" do
    # Create a note to link to
    user = @global_user
    note = create_note(tenant: @tenant, collective: @collective, created_by: user, title: "Target", text: "Content")
    link_url = "https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    markdown = "[#{link_url}](#{link_url})"
    html = MarkdownRenderer.render(markdown, display_references: true)

    # Should contain the icon and formatted reference
    assert html.include?("note-icon") || html.include?(note.truncated_id)
  end

  test "render with display_references false does not process internal links" do
    user = @global_user
    note = create_note(tenant: @tenant, collective: @collective, created_by: user, title: "Target", text: "Content")
    link_url = "https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    markdown = "[Click here](#{link_url})"
    html = MarkdownRenderer.render(markdown, display_references: false)

    # Should keep original link text
    assert html.include?("Click here")
    assert_not html.include?("note-icon")
  end

  # === @mention Linking Tests ===

  test "render links @mention handles that resolve to a user" do
    @global_user.tenant_user.update!(handle: "alice")

    html = MarkdownRenderer.render("Hello @alice, welcome!", display_references: false)

    # Mentions are rendered during the markdown pass, so (like every other
    # relative link) they also pick up rel="noopener noreferrer" from sanitize.
    assert_match %r{<a href="/u/alice"[^>]*class="mention-link"[^>]*>@alice</a>}, html
  end

  test "render leaves unknown @mentions as plain text" do
    html = MarkdownRenderer.render("Hello @nobody_here", display_references: false)

    assert_includes html, "@nobody_here"
    assert_not html.include?('class="mention-link"')
  end

  test "render links multiple resolvable mentions" do
    @global_user.tenant_user.update!(handle: "alice")
    bob = create_user(email: "bob_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @global_tenant.add_user!(bob, handle: "bob")

    html = MarkdownRenderer.render("@alice and @bob", display_references: false)

    assert_match %r{<a href="/u/alice"[^>]*class="mention-link"[^>]*>@alice</a>}, html
    assert_match %r{<a href="/u/bob"[^>]*class="mention-link"[^>]*>@bob</a>}, html
  end

  test "render does not linkify mentions inside inline code" do
    @global_user.tenant_user.update!(handle: "alice")

    html = MarkdownRenderer.render("Use `@alice` literally", display_references: false)

    assert_not html.include?('class="mention-link"')
    assert_includes html, "<code>@alice</code>"
  end

  test "render does not linkify mentions inside code blocks" do
    @global_user.tenant_user.update!(handle: "alice")

    html = MarkdownRenderer.render("```\nping @alice\n```", display_references: false)

    assert_not html.include?('class="mention-link"')
  end

  test "render does not linkify a mention that is already inside a link" do
    @global_user.tenant_user.update!(handle: "alice")

    html = MarkdownRenderer.render("[@alice](https://example.com)", display_references: false)

    # The text stays inside the original link; no nested mention link is added.
    assert_not html.include?('class="mention-link"')
    assert_includes html, 'href="https://example.com"'
  end

  test "render escapes surrounding text when linkifying mentions" do
    @global_user.tenant_user.update!(handle: "alice")

    html = MarkdownRenderer.render("1 < 2 and @alice", display_references: false)

    assert_includes html, "1 &lt; 2"
    assert_match %r{<a href="/u/alice"[^>]*class="mention-link"[^>]*>@alice</a>}, html
  end

  # === Edge Cases ===

  test "render handles very long content" do
    markdown = "Long content. " * 1000
    html = MarkdownRenderer.render(markdown)

    assert html.present?
  end

  test "render handles unicode content" do
    markdown = "# こんにちは 🎉\n\nEmojis: 👍 ❤️ 🚀"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("こんにちは")
    assert html.include?("🎉")
    assert html.include?("👍")
  end

  test "render handles mixed markdown and HTML" do
    markdown = "# Title\n\n<div>Some HTML</div>\n\n**Bold text**"
    html = MarkdownRenderer.render(markdown)

    assert html.include?("Title")
    assert html.include?("<strong>Bold text</strong>")
  end
end
