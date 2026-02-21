# typed: true

class ResourceLinkComponent < ViewComponent::Base
  extend T::Sig

  sig { params(resource: T.untyped).void }
  def initialize(resource:)
    super()
    @resource = resource
  end

  private

  sig { returns(String) }
  def resource_type
    if @resource.is_a?(Hash)
      @resource[:type]&.downcase || "note"
    else
      @resource.class.to_s.downcase
    end
  end

  sig { returns(String) }
  def resource_path
    @resource.is_a?(Hash) ? @resource[:path] : @resource.path
  end

  sig { returns(String) }
  def resource_title
    @resource.is_a?(Hash) ? @resource[:title] : @resource.title
  end

  sig { returns(T.nilable(T.any(String, Integer))) }
  def metric_value
    if @resource.is_a?(Hash)
      @resource[:metric_value]
    elsif @resource.respond_to?(:metric_value)
      @resource.metric_value
    end
  end

  sig { returns(T.nilable(String)) }
  def metric_name
    if @resource.is_a?(Hash)
      @resource[:metric_name]
    elsif @resource.respond_to?(:metric_title)
      @resource.metric_title
    end
  end

  sig { returns(T.nilable(String)) }
  def metric_icon
    if @resource.is_a?(Hash)
      @resource[:octicon_metric_icon_name]
    elsif @resource.respond_to?(:octicon_metric_icon_name)
      @resource.octicon_metric_icon_name
    end
  end
end
