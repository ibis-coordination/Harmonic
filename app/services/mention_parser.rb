# typed: true

class MentionParser
  extend T::Sig

  MENTION_PATTERN = /@([a-zA-Z0-9_-]+)/
  TRIO_HANDLE = "trio"

  # A fenced code block: an opening run of >=3 backticks or tildes at line
  # start, through the matching closing fence (or end of text if unclosed).
  FENCED_CODE_BLOCK = /^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?(?:^[ \t]*\1[ \t]*$|\z)/m

  # An inline code span: a run of backticks, the shortest span up to the same
  # run. (`@trio` -> matched and excluded; a lone stray backtick won't match.)
  INLINE_CODE_SPAN = /(`+)[^`]*?\1/

  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: T.nilable(Collective),
    ).returns(T::Array[User])
  end
  def self.parse(text, tenant_id:, collective: nil)
    return [] if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return [] if handles.empty?

    # When a collective is provided, "@trio" ALWAYS means this collective's
    # trio. The handle index would otherwise also resolve "@trio" to the
    # main collective's trio (which claims the literal handle "trio") even
    # when mentioned in some other collective, fanning out the mention to a
    # trio that isn't local to the conversation.
    index_handles = if collective
      handles - [TRIO_HANDLE]
    else
      handles
    end

    users = if index_handles.any?
      TenantUser.where(tenant_id: tenant_id, handle: index_handles)
        .includes(:user)
        .map(&:user)
    else
      []
    end

    if collective && handles.include?(TRIO_HANDLE)
      trio = collective.trio_user
      users << trio if trio
    end

    users
  end

  # Parse mentions and filter to valid notification recipients:
  # - Must be a member of the collective
  # - Must not be the excluded user (typically the actor)
  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: Collective,
      exclude_user: T.nilable(User),
    ).returns(T::Array[User])
  end
  def self.parse_for_notification(text, tenant_id:, collective:, exclude_user: nil)
    users = parse(text, tenant_id: tenant_id, collective: collective)
    users
      .reject { |u| exclude_user && u.id == exclude_user.id }
      .select { |u| collective.user_is_member?(u) }
  end

  # Resolve mentioned handles to profile paths so @mentions can be rendered
  # as links. Returns a hash of { handle => profile_path } containing only
  # the handles that resolve to a real user in the tenant. Resolution mirrors
  # .parse (including the collective-local @trio special case); handles that
  # don't resolve are omitted so callers can leave them as plain text.
  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: T.nilable(Collective),
    ).returns(T::Hash[String, String])
  end
  def self.resolve_paths(text, tenant_id:, collective: nil)
    return {} if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return {} if handles.empty?

    # Same @trio handling as .parse: when a collective is provided, "@trio"
    # always means this collective's trio, resolved below rather than through
    # the tenant-wide handle index.
    index_handles = if collective
      handles - [TRIO_HANDLE]
    else
      handles
    end

    paths = {}

    if index_handles.any?
      TenantUser.where(tenant_id: tenant_id, handle: index_handles)
        .includes(:user)
        .each do |tenant_user|
          path = tenant_user.user.path
          paths[tenant_user.handle] = path if path
        end
    end

    if collective && handles.include?(TRIO_HANDLE)
      trio_path = collective.trio_user&.path
      paths[TRIO_HANDLE] = trio_path if trio_path
    end

    paths
  end

  sig { params(text: T.nilable(String)).returns(T::Array[String]) }
  def self.extract_handles(text)
    return [] if text.blank?

    # Skip @handles written inside code spans/blocks so they don't generate
    # mention notifications — they render as literal text, not links. This
    # mirrors the Markdown renderer (MarkdownRenderer::MentionRenderer, #295),
    # which gets the same exclusion for free because Redcarpet routes code
    # through callbacks that never reach #normal_text. Here the notification
    # path parses the raw Markdown source, so we strip code first. (#299)
    #
    # On the rendering path this is a no-op: resolve_paths only ever sees a
    # single (already code-free) text node, so there is nothing to strip.
    strip_code(text).scan(MENTION_PATTERN).flatten.uniq
  end

  # Replace fenced code blocks and inline code spans with a space so the
  # mention pattern can't match handles inside them. Fenced blocks are removed
  # first so their delimiter backticks don't get consumed as inline spans.
  sig { params(text: T.nilable(String)).returns(String) }
  def self.strip_code(text)
    return "" if text.nil?

    text.gsub(FENCED_CODE_BLOCK, " ").gsub(INLINE_CODE_SPAN, " ")
  end
  private_class_method :strip_code
end
