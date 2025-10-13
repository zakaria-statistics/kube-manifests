# 1.1 Enable (idempotent)
vault secrets enable database || true

# 1.2 Connection config -> DB VM 10.20.4.5
vault write database/config/app-postgres-b \
  plugin_name=postgresql-database-plugin \
  allowed_roles=app-db-role-b \
  connection_url="postgresql://{{username}}:{{password}}@10.20.4.5:5432/appdb?sslmode=disable" \
  username="vault_admin" \
  password="StrongVaultAdmin!"

# 1.3 Role (how to mint dynamic users)
vault write database/roles/app-db-role-b \
  db_name=app-postgres-b \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                       GRANT CONNECT ON DATABASE appdb TO \"{{name}}\"; \
                       GRANT USAGE ON SCHEMA public TO \"{{name}}\"; \
                       GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=150m \
  max_ttl=3h

  # 2.1 Minimal policy (read only this role’s creds)
cat >/tmp/app-db-read-b.hcl <<'HCL'
path "database/creds/app-db-role-b" { capabilities = ["read"] }
HCL
vault policy write app-db-read-b /tmp/app-db-read-b.hcl

# 2.2 AppRole bound to that policy
vault auth enable approle || true
vault write auth/approle/role/app-approle-b \
  secret_id_num_uses=10 \
  secret_id_ttl=100m \
  token_ttl=130m \
  token_max_ttl=3h \
  token_policies="app-db-read-b"

# 2.3 Get bootstrap values for Kubernetes Secret
ROLE_ID=$(vault read  -field=role_id  auth/approle/role/app-approle-b/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/app-approle-b/secret-id)
echo "ROLE_ID=$ROLE_ID"
echo "SECRET_ID=$SECRET_ID"

# Result:
ROLE_ID=603e9881-c5a0-6945-d175-f94fd040bb6e
SECRET_ID=64237c41-03ce-fe9f-3014-08530d3e9aae

# Issue one dynamic cred
vault read -format=json database/creds/app-db-role-b | tee /tmp/cred_b.json
jq -r '.data.username,.data.password,.lease_id' /tmp/cred_b.json

# Optional: test login directly to DB VM .5
USER=$(jq -r .data.username   /tmp/cred_b.json)
PASS=$(jq -r .data.password   /tmp/cred_b.json)
LEASE_ID=$(jq -r .lease_id /tmp/cred_b.json)
PGPASSWORD="$PASS" psql \
  "host=10.20.4.5 port=5432 dbname=appdb user=$USER sslmode=disable" \
  -tAc "SELECT current_user, now();"
