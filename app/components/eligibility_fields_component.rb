# typed: true

# The two electorate fields on the new-decision and decision-settings forms.
#
# Both are edited as the compact user-set grammar rather than through a narrower
# control, so that a set built through the API — including a multi-clause union —
# round-trips through the form instead of being flattened.
class EligibilityFieldsComponent < ViewComponent::Base
  extend T::Sig

  # Proposing is listed first because it happens first.
  FIELDS = T.let(
    [
      { name: "proposer_eligibility", label: "Who can add options" },
      { name: "voter_eligibility", label: "Who can vote" },
    ].freeze,
    T::Array[T::Hash[Symbol, String]]
  )

  # The two forms divide their sections in opposite directions — the settings
  # form with border-bottom, the new-decision form with border-top. Picking the
  # wrong variant puts two rules side by side.
  SECTION_CLASSES = T.let(
    { form: "pulse-form-section", settings: "pulse-settings-section" }.freeze,
    T::Hash[Symbol, String]
  )
  LABEL_CLASSES = T.let(
    { form: "pulse-form-label", settings: "pulse-label" }.freeze,
    T::Hash[Symbol, String]
  )

  sig do
    params(
      collective: Collective,
      decision: T.nilable(Decision),
      variant: Symbol,
      rejected_input: T.untyped
    ).void
  end
  def initialize(collective:, decision: nil, variant: :settings, rejected_input: nil)
    super()
    @collective = collective
    @decision = decision
    @variant = variant
    # Permitted params or a plain hash, keyed by field name.
    @rejected_input = (rejected_input || {}).to_h.with_indifferent_access
  end

  sig { returns(String) }
  def section_class
    SECTION_CLASSES.fetch(@variant)
  end

  sig { returns(String) }
  def label_class
    LABEL_CLASSES.fetch(@variant)
  end

  # Input the last submit could not parse wins over the stored rule, so the
  # re-rendered form shows what was typed. The stored rule cannot stand in for
  # it — parsing is exactly what failed.
  sig { params(field: String).returns(T.nilable(String)) }
  def value_for(field)
    rejected = @rejected_input[field]
    return rejected if rejected.present?

    @decision&.public_send(:"#{field}_rule")&.to_s(collective: @collective)
  end

  # Feeds the datalist that completes a handle into a whole `user:` clause.
  sig { returns(T::Array[String]) }
  def member_handles
    @collective.collective_members.includes(:user).filter_map { |m| m.user.handle }.sort
  end
end
