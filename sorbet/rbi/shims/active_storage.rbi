# typed: true

# ActiveStorage::Attached::{One,Many} delegate methods like #variant, #preview,
# and #representation to the underlying attachment via method_missing.
# Sorbet doesn't trace method_missing, so it can't see these. This shim
# declares the methods we actually call so callers can stay typed: true
# without sprinkling T.unsafe.
class ActiveStorage::Attached::One
  sig do
    params(transformations: T.any(Symbol, T::Hash[Symbol, T.untyped]))
      .returns(T.untyped)
  end
  def variant(transformations); end

  sig do
    params(transformations: T.any(Symbol, T::Hash[Symbol, T.untyped]))
      .returns(T.untyped)
  end
  def preview(transformations); end

  sig do
    params(transformations: T.any(Symbol, T::Hash[Symbol, T.untyped]))
      .returns(T.untyped)
  end
  def representation(transformations); end
end

class ActiveStorage::Attached::Many
  sig do
    params(transformations: T.any(Symbol, T::Hash[Symbol, T.untyped]))
      .returns(T.untyped)
  end
  def variant(transformations); end
end
