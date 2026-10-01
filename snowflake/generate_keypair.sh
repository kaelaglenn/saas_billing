#!/usr/bin/env bash
# Generate an RSA key pair for a Snowflake service user and print the SQL that registers it.
#
#   snowflake/generate_keypair.sh DLT_SVC
#
# The private key is written outside the repo to ~/.snowflake/keys/<user>.p8 (mode 600).
# It is unencrypted so it can be stored directly as a GitHub Actions secret; keep it off shared machines.
set -euo pipefail

user="${1:?usage: $0 <SNOWFLAKE_USER>}"
dir="${HOME}/.snowflake/keys"
key="${dir}/${user}.p8"

mkdir -p "${dir}"
chmod 700 "${dir}"
if [[ -e "${key}" ]]; then
  echo "Refusing to overwrite existing key ${key}. Delete it first to rotate." >&2
  exit 1
fi

openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -out "${key}"
chmod 600 "${key}"
public_key="$(openssl rsa -in "${key}" -pubout 2>/dev/null | sed '1d;$d' | tr -d '\n')"

echo "Private key: ${key}"
echo
echo "Run in Snowsight as USERADMIN or ACCOUNTADMIN:"
echo
echo "ALTER USER ${user} SET RSA_PUBLIC_KEY = '${public_key}';"
