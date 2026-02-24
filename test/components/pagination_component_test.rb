# typed: false

require "test_helper"
require_relative "component_test_helper"

class PaginationComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  test "renders nothing when total_pages is 1" do
    render_inline(PaginationComponent.new(page: 1, total_pages: 1, base_url: "/admin/users?"))
    assert_no_selector ".pulse-pagination"
  end

  test "shows disabled previous on page 1" do
    render_inline(PaginationComponent.new(page: 1, total_pages: 3, base_url: "/admin/users?"))
    assert_selector "span.pulse-pagination-disabled", text: /Previous/
    assert_no_selector "a", text: /Previous/
  end

  test "shows active previous link on page 2" do
    render_inline(PaginationComponent.new(page: 2, total_pages: 3, base_url: "/admin/users?"))
    assert_selector "a[href='/admin/users?page=1']", text: /Previous/
  end

  test "shows disabled next on last page" do
    render_inline(PaginationComponent.new(page: 3, total_pages: 3, base_url: "/admin/users?"))
    assert_selector "span.pulse-pagination-disabled", text: /Next/
    assert_no_selector "a", text: /Next/
  end

  test "shows active next link on middle page" do
    render_inline(PaginationComponent.new(page: 2, total_pages: 3, base_url: "/admin/users?"))
    assert_selector "a[href='/admin/users?page=3']", text: /Next/
  end

  test "shows page indicator" do
    render_inline(PaginationComponent.new(page: 2, total_pages: 5, base_url: "/admin/users?"))
    assert_text "Page 2 of 5"
  end

  test "preserves query params in base_url" do
    render_inline(PaginationComponent.new(page: 2, total_pages: 3, base_url: "/admin/users?q=test&"))
    assert_selector "a[href='/admin/users?q=test&page=1']", text: /Previous/
    assert_selector "a[href='/admin/users?q=test&page=3']", text: /Next/
  end
end
