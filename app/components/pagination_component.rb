# typed: true

class PaginationComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      page: Integer,
      total_pages: Integer,
      base_url: String
    ).void
  end
  def initialize(page:, total_pages:, base_url:)
    super()
    @page = page
    @total_pages = total_pages
    @base_url = base_url
  end

  sig { returns(T::Boolean) }
  def render?
    @total_pages > 1
  end

  private

  sig { returns(T::Boolean) }
  def has_previous?
    @page > 1
  end

  sig { returns(T::Boolean) }
  def has_next?
    @page < @total_pages
  end

  sig { returns(String) }
  def previous_url
    "#{@base_url}page=#{@page - 1}"
  end

  sig { returns(String) }
  def next_url
    "#{@base_url}page=#{@page + 1}"
  end
end
