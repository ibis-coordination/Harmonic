# typed: false

require "test_helper"

class EligibilityFieldsComponentTest < ViewComponent::TestCase
  setup do
    @collective = Collective.new(name: "Test Collective")
    # The datalist is the only thing that reads members, and the component is
    # under test here rather than the query.
    @collective.define_singleton_method(:collective_members) { CollectiveMember.none }
  end

  def component(**overrides)
    EligibilityFieldsComponent.new(collective: @collective, **overrides)
  end

  test "renders both electorate fields, proposing first" do
    render_inline(component)

    assert_selector "input[name='proposer_eligibility']"
    assert_selector "input[name='voter_eligibility']"
    names = page.all("input[type='text']").map { |i| i[:name] }
    assert_equal %w[proposer_eligibility voter_eligibility], names
  end

  test "an empty field reads as everyone rather than as unset" do
    render_inline(component)

    assert_selector "input[name='voter_eligibility'][placeholder='everyone']"
  end

  test "the settings variant uses settings section and label classes" do
    render_inline(component(variant: :settings))

    assert_selector "section.pulse-settings-section"
    assert_selector "label.pulse-label"
  end

  test "the form variant uses form section and label classes" do
    render_inline(component(variant: :form))

    assert_selector "section.pulse-form-section"
    assert_selector "label.pulse-form-label"
  end

  test "rejected input is shown back so it can be corrected" do
    render_inline(component(rejected_input: { "voter_eligibility" => "user:@nope" }))

    assert_selector "input[name='voter_eligibility'][value='user:@nope']"
  end

  test "rejected input accepts symbol keys" do
    render_inline(component(rejected_input: { voter_eligibility: "role:admin" }))

    assert_selector "input[name='voter_eligibility'][value='role:admin']"
  end

  test "a field with no rejected input falls back to the stored rule" do
    rule = Object.new
    rule.define_singleton_method(:to_s) { |collective:| "role:admin" }
    decision = Decision.new
    decision.define_singleton_method(:voter_eligibility_rule) { rule }
    decision.define_singleton_method(:proposer_eligibility_rule) { nil }

    # Blank rather than absent, since the form submits every field: a blank
    # submission must not mask the stored rule.
    render_inline(component(decision: decision, rejected_input: { "voter_eligibility" => "" }))

    assert_selector "input[name='voter_eligibility'][value='role:admin']"
  end

  test "renders the handle datalist the fields point at" do
    render_inline(component)

    assert_selector "datalist#eligibility-handles", visible: :all
    assert_selector "input[name='voter_eligibility'][list='eligibility-handles']"
  end
end
