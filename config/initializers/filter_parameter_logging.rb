# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # User-supplied webhook URLs may carry auth in query strings or paths
  # (e.g. `https://hooks.example.com/T0123/B0456/abcdef`). Filter so they
  # don't accumulate in retained request logs.
  :webhook_url,
]
