# kube cli
# 1) Ensure SA + binding exist
kubectl -n kube-system create sa vault-auth 2>/dev/null || true
kubectl create clusterrolebinding vault-auth \
  --clusterrole=system:auth-delegator \
  --serviceaccount=kube-system:vault-auth 2>/dev/null || true

# 2) Create a short-lived reviewer JWT (e.g., 1h)
kubectl -n kube-system create token vault-auth --duration=5h > /tmp/token_reviewer_jwt

# 3) Get the cluster CA (from the namespace CM)
kubectl -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > /tmp/ca.crt

# 4) Sanity check
head -c 20 /tmp/token_reviewer_jwt && echo
head -n1 /tmp/ca.crt

# vault cli
export K8S_API="https://10.20.2.4:6443"   # your API endpoint

vault auth enable kubernetes 2>/dev/null || true
vault write auth/kubernetes/config \
  token_reviewer_jwt=@/tmp/token_reviewer_jwt \
  kubernetes_host="$K8S_API" \
  kubernetes_ca_cert=@/tmp/ca.crt \
  issuer="https://kubernetes.default.svc.cluster.local"

# verification
# should return JSON with "data"
curl -sS $K8S_API/version --cacert /tmp/ca.crt | head
[ -s /tmp/token_reviewer_jwt ] && echo "JWT OK"


# database engine
# --- 2) Database engine (Postgres example: edit host/DB/admin user+pass) ---
vault secrets enable -path=database database 2>/dev/null || true

vault write database/config/postgresdb \
  plugin_name=postgresql-database-plugin \
  allowed_roles="readonly-role" \
  connection_url="postgresql://{{username}}:{{password}}@10.20.4.5:5432/appdb?sslmode=disable" \
  username="vault_admin" \
  password="StrongVaultAdmin!"

vault write database/roles/readonly-role \
  db_name=postgresdb \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="2h" max_ttl="24h"

# --- 3) Minimal policy to read the dynamic creds ---
cat >/tmp/db-policy.hcl <<'HCL'
path "database/creds/readonly-role" {
  capabilities = ["read"]
}
HCL
vault policy write db-policy /tmp/db-policy.hcl

# --- 4) Bind K8s SA (apps/db-app-sa) to that policy ---
vault write auth/kubernetes/role/db-role \
  bound_service_account_names="db-app-sa" \
  bound_service_account_namespaces="apps" \
  policies="db-policy" \
  ttl="2h"

# Install agent
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set server.enabled=false \
  --set injector.enabled=true \
  --set injector.externalVaultAddr=http://10.20.6.4:8200 \
  --set injector.logLevel=debug


# kube manifests:
# file: native-vault-k8s.yaml
apiVersion: v1
kind: Namespace
metadata: { name: apps }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: db-app-sa
  namespace: apps
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-config
  namespace: apps
data:
  DB_HOST: "pg-db-b.apps.svc.cluster.local"
  DB_PORT: "5432"
  DB_NAME: "appdb"
---
# Only needed if Vault uses a private CA. If public CA, delete this block.
# apiVersion: v1
# kind: Secret
# metadata:
#   name: vault-ca
#   namespace: apps
# type: Opaque
# data:
#   ca.crt: ""   # base64 of your Vault CA PEM; or create via kubectl CLI