require "test_helper"

# Tests the `allows_anonymous` class macro on ApplicationController.
#
# Critical invariant: declarations on a parent controller must NOT leak to
# subclasses. The whole point of the macro vs. `class_attribute` is that
# `Api::V1::NotesController < NotesController` must not silently inherit
# anonymous access from its parent.
class ApplicationControllerAllowsAnonymousTest < ActiveSupport::TestCase
  # Fresh anonymous controller classes per test — Ruby `Class.new(Parent)` makes
  # disposable subclasses without polluting the global namespace.
  test "ApplicationController.allows_anonymous? returns false on the base class with no declarations" do
    assert_not ApplicationController.allows_anonymous?(:show)
    assert_not ApplicationController.allows_anonymous?(:index)
  end

  test "declared actions return true" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show, :index)

    assert parent.allows_anonymous?(:show)
    assert parent.allows_anonymous?(:index)
  end

  test "undeclared actions return false on a controller with some declarations" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show)

    assert_not parent.allows_anonymous?(:edit)
    assert_not parent.allows_anonymous?(:create)
  end

  test "symbol/string normalization: declared with symbol, queried with string" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show)

    assert parent.allows_anonymous?("show")
  end

  test "symbol/string normalization: declared with string, queried with symbol" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous("show")

    assert parent.allows_anonymous?(:show)
  end

  test "subclass does NOT inherit anonymous declarations from its parent" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show)

    child = Class.new(parent)

    assert parent.allows_anonymous?(:show)
    assert_not child.allows_anonymous?(:show),
               "subclass must not inherit allows_anonymous — that would silently grant anon access to API subclasses"
  end

  test "sibling controllers do not cross-contaminate" do
    sibling_a = Class.new(ApplicationController)
    sibling_b = Class.new(ApplicationController)

    sibling_a.allows_anonymous(:show)

    assert sibling_a.allows_anonymous?(:show)
    assert_not sibling_b.allows_anonymous?(:show)
  end

  test "multiple declarations on the same controller accumulate" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show)
    parent.allows_anonymous(:index)

    assert parent.allows_anonymous?(:show)
    assert parent.allows_anonymous?(:index)
  end

  test "splat declaration accepts multiple actions in one call" do
    parent = Class.new(ApplicationController)
    parent.allows_anonymous(:show, :index, :foo, :bar)

    [:show, :index, :foo, :bar].each do |action|
      assert parent.allows_anonymous?(action), "expected #{action} to be allowed"
    end
    assert_not parent.allows_anonymous?(:baz)
  end
end
