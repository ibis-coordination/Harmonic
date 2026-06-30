# These outputs are what you hand to the secrets file / first boot. The
# sensitive ones are exactly the managed-resource credentials that live in
# state — read them with `terraform output -raw <name>` to seed the SOPS file.

output "droplet_ip" {
  description = "Public IPv4 of the droplet. Point deploys / SSH here."
  value       = digitalocean_droplet.web.ipv4_address
}

output "database_url" {
  description = "DATABASE_URL for the app (private network host). Goes into the secrets file."
  value = format(
    "postgres://%s:%s@%s:%d/%s?sslmode=require",
    digitalocean_database_user.harmonic.name,
    digitalocean_database_user.harmonic.password,
    digitalocean_database_cluster.pg.private_host,
    digitalocean_database_cluster.pg.port,
    digitalocean_database_db.harmonic.name,
  )
  sensitive = true
}

output "spaces_bucket" {
  value = digitalocean_spaces_bucket.storage.name
}

output "spaces_endpoint" {
  value = "https://${var.region}.digitaloceanspaces.com"
}

output "spaces_access_key_id" {
  value     = digitalocean_spaces_key.storage.access_key
  sensitive = true
}

output "spaces_secret_access_key" {
  value     = digitalocean_spaces_key.storage.secret_key
  sensitive = true
}

output "ses_smtp_server" {
  description = "SMTP host for SES in the chosen region."
  value       = "email-smtp.${var.ses_region}.amazonaws.com"
}
