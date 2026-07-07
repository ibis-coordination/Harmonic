# typed: true

require "redcarpet/render_strip"

class MentionParser
  extend T::Sig

  MENTION_PATTERN = /@([a-zA-Z0-9_-]+)/
  # Kept as an alias so existing references (User, autocomplete, dispatcher)
  # keep working; the canonical value now lives in the reserved-handle registry.
  TRIO_HANDLE = ReservedHandles::TRIO

  # A Redcarpet plain-text renderer that drops code while keeping every other
  # kind of text. It subclasses StripDown — which already extracts the text
  # content of each node — and blanks only the code callbacks. The upshot is
  # that "what counts as code" is decided by the same Markdown tokenizer the
  # HTML renderer uses (MarkdownRenderer, #295), so the notification path can't
  # drift from the render path the way a separate hand-rolled regex would: a
  # fenced block, an *indented* (4-space/tab) block, an inline span, and a
  # mention inside a nested list are all classified here exactly as on render.
  # Code is replaced with whitespace (never nothing) so text on either side of
  # a span can't fuse into a spurious handle — "@" `x` "foo" must not read as
  # "@foo". (#299)
  class CodeStrippingRenderer < Redcarpet::Render::StripDown
    def block_code(_code, _language)
      "\n"
    end

    def codespan(_code)
      " "
    end
  end

  # Tokenizer extensions mirror MarkdownRenderer's so code is recognized
  # identically on both paths: fenced_code_blocks so ``` fences route through
  # block_code, and no_intra_emphasis so underscores in handles aren't eaten as
  # emphasis (e.g. @a_b_c stays one handle rather than splitting on the _b_).
  CODE_STRIPPER = T.let(
    Redcarpet::Markdown.new(
      CodeStrippingRenderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      no_intra_emphasis: true,
    ),
    Redcarpet::Markdown,
  )

  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: T.nilable(Collective),
      author: T.nilable(User),
    ).returns(T::Array[User])
  end
  def self.parse(text, tenant_id:, collective: nil, author: nil)
    return [] if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return [] if handles.empty?

    # Collective-local handles (@trio, @everyone, @admins) ALWAYS mean this
    # collective's trio/members/admins. The tenant-wide handle index would
    # otherwise resolve, say, "@trio" to the main collective's trio (which
    # claims the literal handle) even when written in some other collective,
    # fanning out the mention to a set that isn't local to the conversation.
    index_handles = if collective
      handles.reject { |h| ReservedHandles.collective_local?(h) }
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

    users.concat(resolve_collective_local(handles, collective: collective, author: author)) if collective

    # A user can be named by more than one tag (mentioned directly and via
    # @everyone, or in both @everyone and @admins); collapse so callers don't
    # double-notify.
    users.uniq(&:id)
  end

  # Parse mentions and filter to valid notification recipients:
  # - Must be a member of the collective
  # - Must not be the excluded user (typically the actor)
  #
  # `author` is the user whose text this is; it gates @everyone (admin-only).
  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: Collective,
      exclude_user: T.nilable(User),
      author: T.nilable(User),
    ).returns(T::Array[User])
  end
  def self.parse_for_notification(text, tenant_id:, collective:, exclude_user: nil, author: nil)
    users = parse(text, tenant_id: tenant_id, collective: collective, author: author)
    users
      .reject { |u| exclude_user && u.id == exclude_user.id }
      .select { |u| collective.user_is_member?(u) }
  end

  # Expand collective-local tags to the users they name, within `collective`:
  #   @trio             → this collective's trio user
  #   @admins /         → members holding that role (any member may use a role
  #   @representatives /   tag). The tags come from ReservedHandles.role_tags,
  #   @summarizers / …     which is derived from the collective role list, so a
  #                        new/custom role's tag resolves here with no change.
  #   @everyone         → all members, but only when `author` is an admin.
  #                       Without a known admin author the tag expands to nobody,
  #                       so it can never fan out by accident (e.g.
  #                       background/system parse paths that don't carry an
  #                       author).
  sig do
    params(
      handles: T::Array[String],
      collective: Collective,
      author: T.nilable(User),
    ).returns(T::Array[User])
  end
  def self.resolve_collective_local(handles, collective:, author:)
    wanted = handles.map(&:downcase)
    result = T.let([], T::Array[User])

    if wanted.include?(TRIO_HANDLE)
      trio = collective.trio_user
      result << trio if trio
    end

    ReservedHandles.role_tags.each do |tag, role|
      result.concat(collective.users_with_role(role)) if wanted.include?(tag)
    end

    if wanted.include?(ReservedHandles::EVERYONE) && author && collective.admin?(author)
      result.concat(collective.member_users)
    end

    result
  end
  private_class_method :resolve_collective_local

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

    # Render path: text is a single, already code-free node, so skip stripping.
    handles = extract_handles(text, strip: false)
    return {} if handles.empty?

    # Same collective-local handling as .parse: within a collective, @trio and
    # the group tags resolve locally, not through the tenant-wide handle index.
    index_handles = if collective
      handles.reject { |h| ReservedHandles.collective_local?(h) }
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

    if collective
      # Keys are the handles as written (case preserved) so the renderer, which
      # looks up each matched substring verbatim, links them regardless of case.
      collective_path = collective.path
      handles.each do |handle|
        down = handle.downcase
        if down == TRIO_HANDLE
          trio_path = collective.trio_user&.path
          paths[handle] = trio_path if trio_path
        elsif ReservedHandles.group_tag?(down)
          # @everyone / @admins render as a link to the collective. Rendering is
          # display only — the admin-only gate on @everyone lives on the
          # notification path, so the tag is shown regardless of who wrote it.
          paths[handle] = collective_path
        end
      end
    end

    paths
  end

  sig { params(text: T.nilable(String), strip: T::Boolean).returns(T::Array[String]) }
  def self.extract_handles(text, strip: true)
    return [] if text.blank?

    # The notification path parses the raw Markdown source, so strip code first:
    # @handles inside code spans/blocks render as literal text, not links, and
    # must not generate mention notifications. This mirrors the renderer
    # (MarkdownRenderer::MentionRenderer, #295), which gets the same exclusion
    # for free because Redcarpet routes code through callbacks that never reach
    # #normal_text. (#299)
    #
    # The render path passes strip: false — resolve_paths is only ever called
    # with a single, already code-free text node, so stripping there is both
    # unnecessary and undesirable (it would re-tokenize each fragment).
    source = strip ? strip_code(text) : T.must(text)
    source.scan(MENTION_PATTERN).flatten.uniq
  end

  # Render the Markdown to plain text with every code construct removed (see
  # CodeStrippingRenderer), so the mention pattern can't match handles inside
  # code. Returns "" for nil input.
  sig { params(text: T.nilable(String)).returns(String) }
  def self.strip_code(text)
    return "" if text.nil?

    CODE_STRIPPER.render(text)
  end
  private_class_method :strip_code
end
