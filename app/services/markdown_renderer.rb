# typed: true

# The purpose of this class is to render Markdown content as HTML, while
# sanitizing the HTML and adding rel="noopener noreferrer" to all links.
# This is a security measure to prevent malicious links from being used to
# exploit users.
# Also, for image tags we check for http(s) protocol and add loading="lazy"
# to enable lazy loading of images for performance and partial DoS protection.
class MarkdownRenderer
  extend T::Sig
  @@markdown = Redcarpet::Markdown.new(
    Redcarpet::Render::HTML.new(
      hard_wrap: true,
      safe_links_only: true,
      filter_html: false, # Turned off so we can handle sanitization manually
      no_images: false,   # Same as above
      no_links: false,    # Same as above
      no_styles: true     # No need for inline styles
    ),
    autolink: true,
    tables: true,
    fenced_code_blocks: true
  )

  sig { params(content: T.untyped, shift_headers: T::Boolean, display_references: T::Boolean).returns(String) }
  def self.render(content, shift_headers: true, display_references: true)
    raw_html = @@markdown.render(content.to_s)
    sanitized_html = sanitize(raw_html)
    if shift_headers
      output = shift_headers(sanitized_html)
    else
      output = sanitized_html
    end
    if display_references
      output = display_refereces(output)
    end
    output
  end

  sig { params(content: T.untyped).returns(String) }
  def self.render_inline(content)
    raw_html = @@markdown.render(content.to_s)
    sanitized_html = sanitize(raw_html)
    sanitized_html.gsub(/<p>(.*)<\/p>/, '\1')
  end

  private

  # HTML tags allowed through sanitization
  ALLOWED_TAGS = %w[
    p br hr
    h1 h2 h3 h4 h5 h6
    strong b em i u s strike del
    a img
    ul ol li
    blockquote pre code
    table thead tbody tfoot tr th td
    div span
  ].freeze

  sig { params(html: String).returns(String) }
  def self.sanitize(html)
    sanitized_html = ActionController::Base.helpers.sanitize(html, tags: ALLOWED_TAGS)
    doc = Nokogiri::HTML.fragment(sanitized_html)

    # Remove dangerous protocols from URLs
    # Allow relative links (nil scheme) and anchor links, plus safe absolute schemes
    doc.search('a').each do |a|
      if a['href']
        uri = URI.parse(a['href']) rescue nil
        if uri && uri.scheme && !["http", "https", "mailto"].include?(uri.scheme)
          a.remove
        else
          a['rel'] = 'noopener noreferrer'
        end
      end
    end

    # Handle Image tags
    doc.search('img').each do |img|
      if img['src']
        uri = URI.parse(img['src']) rescue nil
        if uri && !["http", "https"].include?(uri.scheme)
          img.remove
        else
          # Optionally add lazy loading for performance and partial DoS protection
          img['loading'] = 'lazy'
        end
      end
    end

    doc.to_html
  end

  sig { params(html: String, shift_by: Integer).returns(String) }
  def self.shift_headers(html, shift_by: 1)
    doc = Nokogiri::HTML.fragment(html)
    (1..6).reverse_each do |i|
      doc.search("h#{i}").each do |header|
        header.name = "h#{i + shift_by}"
      end
    end
    doc.to_html
  end

  sig { params(html: String).returns(String) }
  def self.display_refereces(html)
    link_parser = LinkParser.new(subdomain: Tenant.current_subdomain, collective_handle: Collective.current_handle)
    doc = Nokogiri::HTML.fragment(html)
    doc.search('a').each do |a|
      a['href'] && link_parser.parse(a['href']) do |resource|
        if a.content == a['href']
          model_name = resource.class.name.downcase
          # a['class'] = "resource-link-#{model_name}"
          a.inner_html = "<i class='#{model_name}-icon'></i> <code>#{model_name[0]}/#{resource.truncated_id}</code>"
        end
      end
    end
    doc.to_html
  end

end
