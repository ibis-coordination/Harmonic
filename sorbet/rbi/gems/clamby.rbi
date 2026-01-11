# typed: true

module Clamby
  sig { params(options: T::Hash[Symbol, T.untyped]).void }
  def self.configure(options); end

  sig { params(path: String).returns(T::Boolean) }
  def self.safe?(path); end

  sig { params(path: String).returns(T::Boolean) }
  def self.virus?(path); end

  sig { params(path: String).returns(T.nilable(String)) }
  def self.scan(path); end
end
