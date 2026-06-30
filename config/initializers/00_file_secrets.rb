# frozen_string_literal: true

# File-mounted secrets (Docker / Compose `secrets:`).
#
# WHY: env-var secrets leak. They show up in `docker inspect`, /proc/<pid>/environ,
# every child process that inherits the environment, crash dumps, and error
# reporters (Sentry et al. love to attach the process env to reports). Mounting
# each secret as a file under /run/secrets/<NAME> (tmpfs) keeps it out of all
# of those surfaces.
#
# HOW: for every file in SECRETS_DIR, set ENV["<NAME>"] from its contents —
# but only if the env var isn't already set. So precedence is:
#   explicit ENV (e.g. legacy .env)  >  /run/secrets file  >  unset
# That makes this a strict no-op on any host without /run/secrets (dev, test,
# today's prod), and lets us migrate one secret at a time.
#
# The "00_" filename prefix loads this before initializers that read these
# vars. Note: SECRET_KEY_BASE and DATABASE_URL are consumed very early in boot
# (DB connection config, key derivation). If you move THOSE to file-secrets,
# prefer exporting them in the container entrypoint before Rails starts — see
# docs/INFRASTRUCTURE.md "Boot-ordering caveat". Everything else is safe here.

secrets_dir = ENV.fetch("SECRETS_DIR", "/run/secrets")

if File.directory?(secrets_dir)
  Dir.each_child(secrets_dir) do |name|
    path = File.join(secrets_dir, name)
    next unless File.file?(path)
    next if ENV.key?(name) # explicit env wins; don't clobber

    value = File.read(path).chomp
    ENV[name] = value unless value.empty?
  end
end
