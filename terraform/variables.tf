variable "domain" {
  type        = string
  description = "Root domain for the deployment, e.g. harmonic.example.com. Tenant subdomains live under this as *.<domain>."
}

variable "region" {
  type        = string
  description = "DigitalOcean region slug for the droplet, database, and Spaces bucket."
  default     = "nyc3"
}

variable "ses_region" {
  type        = string
  description = "AWS region for the SES domain identity. Need not match the DO region."
  default     = "us-east-1"
}

variable "droplet_size" {
  type        = string
  description = "Droplet size slug. The prod compose reserves ~1.75G across web+sidekiq+agent-runner+redis+caddy+clamav, so 4GB is a sane floor."
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  type    = string
  default = "ubuntu-24-04-x64"
}

variable "pg_version" {
  type    = string
  default = "16"
}

variable "pg_size" {
  type        = string
  description = "Managed Postgres node size slug."
  default     = "db-s-1vcpu-1gb"
}

variable "pg_node_count" {
  type    = number
  default = 1
}

variable "ssh_key_fingerprints" {
  type        = list(string)
  description = "Fingerprints of SSH keys already uploaded to the DO account, granted root on the droplet."
}

variable "ssh_allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach SSH (port 22). Lock this to your IPs; do NOT leave 0.0.0.0/0."
  default     = []
}

variable "spaces_bucket_name" {
  type        = string
  description = "Name for the ActiveStorage Spaces bucket. Must be globally unique within the region."
}
