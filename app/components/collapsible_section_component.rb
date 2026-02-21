# typed: true

class CollapsibleSectionComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      title: String,
      header_level: Integer,
      hidden: T::Boolean,
      title_superscript: T.nilable(T.any(String, Integer, T::Hash[String, T.untyped])),
      icon: T.nilable(String),
      target: T.nilable(T::Hash[String, String]),
      indent: T::Boolean,
      lazy_load: T.nilable(String),
    ).void
  end
  def initialize(title:, header_level: 1, hidden: false, title_superscript: nil, icon: nil, target: nil, indent: false, lazy_load: nil) # rubocop:disable Metrics/ParameterLists
    super()
    @title = title
    @header_level = header_level
    @hidden = hidden
    @title_superscript = title_superscript
    @icon = icon
    @target = target
    @indent = indent
    @lazy_load = lazy_load
  end

  private

  sig { returns(Integer) }
  def icon_height
    @header_level < 3 ? 24 : 16
  end

  sig { returns(String) }
  def target_attributes
    return "" if @target.blank?

    @target.map { |k, v| "data-#{k}-target='#{v}'" }.join(" ").html_safe
  end

  sig { returns(String) }
  def body_style
    style = "display:#{@hidden ? 'none' : 'block'};"
    style += "padding-left:16px;border-left:1px solid var(--color-border-default);" if @indent
    style
  end
end
