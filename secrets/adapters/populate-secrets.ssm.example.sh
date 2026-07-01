#!/bin/bash
# EXAMPLE populate hook — AWS SSM Parameter Store adapter. OPTIONAL, not
# installed by default.
#
# This is one way to implement scripts/deploy.sh's $SECRETS_HOOK. It is an
# example: copy it OUT of this repo, set $SSM_PATH_PREFIX for your account, and
# install it on the server (e.g. as /opt/harmonic/secrets/populate-secrets.sh,
# the default $SECRETS_HOOK path). Nothing here fetches anything on its own.
#
# Fit: operators already on AWS (Harmonic uses SES there anyway). The single
# bootstrapped credential is the box's AWS access — ideally an EC2/instance
# role (no long-lived key at all), or an IAM user's creds planted at provision
# time. No age key, no encrypted blob.
#
#   - Store one SecureString parameter per secret NAME under a shared path,
#     e.g. /harmonic/prod/DATABASE_URL, /harmonic/prod/SMTP_PASSWORD, ...
#   - The parameter's leaf name must match a NAME from secrets/secrets.example.
#
# deploy.sh calls this with $SECRETS_DIR exported; the job is to write one
# 0600 file per secret into $SECRETS_DIR.
set -euo pipefail

# BYO: the SSM path prefix that holds your parameters (no trailing slash).
SSM_PATH_PREFIX="${SSM_PATH_PREFIX:-/harmonic/prod}"
# Optional: region / profile for the AWS CLI (else use the box's default chain).
export AWS_REGION="${AWS_REGION:-us-east-1}"
SECRETS_DIR="${SECRETS_DIR:-secrets/run}"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: the AWS CLI ('aws') is not installed." >&2
  exit 1
fi

install -d -m 700 "$SECRETS_DIR"

# Fetch every parameter under the prefix, decrypting SecureStrings. The AWS CLI
# auto-paginates, so one call returns them all as "Name<TAB>Value" lines. The
# parameter's leaf name (after the last '/') is the secret NAME.
aws ssm get-parameters-by-path --path "$SSM_PATH_PREFIX" \
  --recursive --with-decryption \
  --query 'Parameters[].[Name,Value]' --output text \
  | while IFS=$'\t' read -r name value; do
      [ -n "$name" ] || continue
      leaf="${name##*/}"
      printf '%s' "$value" > "$SECRETS_DIR/$leaf"
      chmod 600 "$SECRETS_DIR/$leaf"
    done

echo "Populated $SECRETS_DIR from SSM path $SSM_PATH_PREFIX"
