# frozen_string_literal: true

Clamby.configure({
                   # Use clamd daemon mode (connects to clamav Docker service)
                   daemonize: true,

                   # Use TCP streaming to send file content to clamd
                   # Required when clamd runs in a separate container
                   fdpass: false,
                   stream: true,

                   # Path to clamd.conf that specifies the clamav service connection
                   config_file: "/etc/clamav/clamd.conf",

                   # Error handling
                   error_clamscan_missing: false, # Don't raise if clamscan binary not found
                   error_clamscan_client_error: false, # Don't raise on scan errors (handle gracefully)
                   error_file_missing: true, # Raise if file to scan doesn't exist
                   error_file_virus: false, # Don't raise on virus found - we handle in validation

                   # Output options
                   output_level: Rails.env.production? ? "low" : "medium",
                 })
