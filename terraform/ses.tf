# AWS SES domain identity for transactional mail. This is the ONE place the
# AWS provider is used — everything else is DigitalOcean. The verification and
# DKIM records that SES emits are written back into the DO DNS zone, so the
# identity verifies itself end-to-end on `apply`.
#
# Note: new SES accounts start in the sandbox (can only send to verified
# addresses) and SMTP credentials are created separately (IAM user -> SES SMTP
# password). Requesting production access and minting SMTP creds are manual /
# out-of-band steps; the SMTP_USERNAME/PASSWORD then live in the SOPS secrets
# file, not here. See docs/INFRASTRUCTURE.md.

resource "aws_ses_domain_identity" "harmonic" {
  domain = var.domain
}

resource "aws_ses_domain_dkim" "harmonic" {
  domain = aws_ses_domain_identity.harmonic.domain
}

# Domain verification TXT record (in the DO zone).
resource "digitalocean_record" "ses_verification" {
  domain = digitalocean_domain.harmonic.id
  type   = "TXT"
  name   = "_amazonses"
  value  = aws_ses_domain_identity.harmonic.verification_token
  ttl    = 600
}

# Three DKIM CNAMEs (in the DO zone).
resource "digitalocean_record" "ses_dkim" {
  count  = 3
  domain = digitalocean_domain.harmonic.id
  type   = "CNAME"
  name   = "${aws_ses_domain_dkim.harmonic.dkim_tokens[count.index]}._domainkey"
  value  = "${aws_ses_domain_dkim.harmonic.dkim_tokens[count.index]}.dkim.amazonses.com."
  ttl    = 600
}

# SPF (TXT) on the bare domain so receivers trust SES as a sender.
resource "digitalocean_record" "spf" {
  domain = digitalocean_domain.harmonic.id
  type   = "TXT"
  name   = "@"
  value  = "v=spf1 include:amazonses.com ~all"
  ttl    = 600
}
