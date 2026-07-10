# DNS for the bare domain, the app/auth/primary subdomains, and the wildcard
# that makes per-tenant subdomains work (*.<domain> -> the droplet). Caddy
# terminates TLS for each, so a single A + wildcard A is enough.

resource "digitalocean_domain" "harmonic" {
  name = var.domain
}

# Bare domain -> droplet (Caddy redirects it to the primary subdomain).
resource "digitalocean_record" "root" {
  domain = digitalocean_domain.harmonic.id
  type   = "A"
  name   = "@"
  value  = digitalocean_droplet.web.ipv4_address
  ttl    = 300
}

# Wildcard -> droplet. Covers app/auth/www AND every tenant subdomain without
# a per-tenant terraform change. New tenants are a pure app-level operation.
resource "digitalocean_record" "wildcard" {
  domain = digitalocean_domain.harmonic.id
  type   = "A"
  name   = "*"
  value  = digitalocean_droplet.web.ipv4_address
  ttl    = 300
}
