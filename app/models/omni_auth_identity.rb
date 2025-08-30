class OmniAuthIdentity < OmniAuth::Identity::Models::ActiveRecord
  auth_key :email
end
