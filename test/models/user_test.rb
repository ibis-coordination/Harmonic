require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "User.create works" do
    user = User.create!(
      email: "#{SecureRandom.hex(8)}@example.com",
      name: 'Test Person',
      user_type: 'person'
    )
    assert user.persisted?
    assert_equal 'Test Person', user.name
    assert_equal 'person', user.user_type
    assert user.email.present?
  end
end
