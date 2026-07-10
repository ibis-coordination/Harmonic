# These outputs are what you hand to the server .env / your private secrets
# store. The sensitive ones are exactly the managed-resource credentials that
# live in state — read them with `terraform output -raw <name>`.

output "droplet_ip" {
  description = "Public IPv4 of the droplet. Point deploys / SSH here."
  value       = digitalocean_droplet.web.ipv4_address
}

# The app's database.yml consumes split POSTGRES_* vars (not DATABASE_URL),
# so emit the pieces under matching names for the server .env.
output "postgres_host" {
  description = "POSTGRES_HOST (private network host)."
  value       = digitalocean_database_cluster.pg.private_host
}

output "postgres_port" {
  description = "POSTGRES_PORT."
  value       = digitalocean_database_cluster.pg.port
}

output "postgres_db" {
  description = "POSTGRES_DB."
  value       = digitalocean_database_db.harmonic.name
}

output "postgres_user" {
  description = "POSTGRES_USER."
  value       = digitalocean_database_user.harmonic.name
}

output "postgres_password" {
  description = "POSTGRES_PASSWORD. Lives in state — see versions.tf on encrypting the backend."
  value       = digitalocean_database_user.harmonic.password
  sensitive   = true
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
