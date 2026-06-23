# frozen_string_literal: true

# Shared structural assertions against the canonical bridge_protocol
# fixtures in test/fixtures/bridge_protocol/. The TypeScript bridge tests
# load the same fixtures via harmonic-bridge/src/test-fixtures.ts. If a
# field is renamed on either side, the OTHER side's tests fail at the
# fixture-shape check.
#
# The helpers assert TYPE and key PRESENCE, not value equality — the
# fixtures document the wire shape, not specific values.
module BridgeProtocolFixtures
  FIXTURE_DIR = Rails.root.join("test/fixtures/bridge_protocol").freeze

  def load_bridge_protocol_fixture(name)
    JSON.parse(File.read(FIXTURE_DIR.join(name)))
  end

  # Assert `actual` has the same structural shape as the fixture: every key
  # in the fixture must be present in `actual` with a value of the same
  # type. Extra keys in `actual` are allowed (responses can grow without
  # breaking old clients).
  def assert_matches_bridge_protocol_fixture(actual, fixture_name)
    fixture = load_bridge_protocol_fixture(fixture_name)
    assert_shape_matches(fixture, actual, "(#{fixture_name})")
  end

  private

  def assert_shape_matches(expected, actual, path)
    case expected
    when Hash
      assert_kind_of Hash, actual, "expected Hash at #{path}, got #{actual.class}"
      expected.each do |k, v|
        assert actual.key?(k), "missing key #{k.inspect} at #{path} (have: #{actual.keys.inspect})"
        assert_shape_matches(v, actual[k], "#{path}.#{k}")
      end
    when Array
      assert_kind_of Array, actual, "expected Array at #{path}, got #{actual.class}"
      next_shape = expected.first
      actual.each_with_index do |item, i|
        assert_shape_matches(next_shape, item, "#{path}[#{i}]") if next_shape
      end
    when String
      assert_kind_of String, actual, "expected String at #{path}, got #{actual.class}"
    when Integer
      assert_kind_of Integer, actual, "expected Integer at #{path}, got #{actual.class}"
    when Float
      assert_kind_of Numeric, actual, "expected Numeric at #{path}, got #{actual.class}"
    when TrueClass, FalseClass
      assert_includes [true, false], actual, "expected boolean at #{path}, got #{actual.inspect}"
    when NilClass
      assert_nil actual, "expected null at #{path}, got #{actual.inspect}"
    end
  end
end
