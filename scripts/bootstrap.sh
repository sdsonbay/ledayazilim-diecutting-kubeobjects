#!/usr/bin/env bash
# Leda Diecutting — tek seferlik altyapı kurulumu (Mac'te, repo kökünden çalıştırın).
#
#   1. Netcup Postgres'te SADECE bu projeye ait rol + veritabanları (dev, prod)
#   2. SOPS ile şifreli Kubernetes secret'ları (api-secrets, ghcr-pull)
#   3. ArgoCD Application'ları (leda-diecutting-{be,fe}-{dev,prod})
#
# Mevcut hiçbir veritabanına, role ya da namespace'e dokunmaz: her adım
# "yoksa oluştur" şeklindedir ve yalnızca leda-diecutting-* / diecutting_* adlarını kullanır.
#
# Gerekenler: ssh erişimi (deploy@netcup), sops, age anahtarı (~/.config/sops/age/keys.txt), openssl
#
# Örnek:
#   export SSH_TARGET=deploy@<netcup-ip>
#   export DB_HOST=<pod'ların Postgres'e eriştiği adres, ör. netcup-ip>
#   export GHCR_USER=sdsonbay GHCR_TOKEN=<read:packages yetkili PAT>
#   scripts/bootstrap.sh            # hepsi
#   scripts/bootstrap.sh db         # sadece veritabanı
#   scripts/bootstrap.sh secrets    # sadece secret'lar
#   scripts/bootstrap.sh argocd     # sadece ArgoCD uygulamaları
set -euo pipefail

cd "$(dirname "$0")/.."

STEP="${1:-all}"
ENVS="${ENVS:-dev prod}"
SSH_TARGET="${SSH_TARGET:?SSH_TARGET gerekli (ör. deploy@1.2.3.4)}"
DB_HOST="${DB_HOST:-${SSH_TARGET#*@}}"
DB_PORT="${DB_PORT:-5432}"
# Postgres'e süper kullanıcı olarak SQL gönderen komut (stdin'den okur).
PSQL_ADMIN="${PSQL_ADMIN:-ssh $SSH_TARGET sudo -u postgres psql -v ON_ERROR_STOP=1 -X -q}"
KUBECTL="${KUBECTL:-ssh $SSH_TARGET kubectl}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

STATE_DIR=".bootstrap"          # .gitignore'da; üretilen şifreler burada (yerelde) kalır
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

log() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "$1 kurulu değil"; }
need openssl
need sops

# Ortam başına kalıcı rastgele değer (tekrar çalıştırmada aynı kalır).
secret_for() {
  local file="$STATE_DIR/$1"
  [ -s "$file" ] || openssl rand -hex 32 > "$file"
  chmod 600 "$file"
  cat "$file"
}

db_step() {
  for env in $ENVS; do
    local role="diecutting_${env}" db="diecutting_${env}"
    local pass; pass="$(secret_for "db-${env}")"
    log "Postgres: rol ${role}, veritabanı ${db}"
    # Rol/veritabanı yoksa oluşturulur; varsa yalnızca şifresi bu projeninkiyle eşitlenir.
    $PSQL_ADMIN <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role}') THEN
    CREATE ROLE ${role} LOGIN PASSWORD '${pass}';
  ELSE
    ALTER ROLE ${role} WITH LOGIN PASSWORD '${pass}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${db} OWNER ${role}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')\gexec
REVOKE ALL ON DATABASE ${db} FROM PUBLIC;
GRANT ALL ON DATABASE ${db} TO ${role};
\c ${db}
CREATE EXTENSION IF NOT EXISTS pgcrypto;
ALTER SCHEMA public OWNER TO ${role};
SQL
  done
  log "Veritabanları hazır. pg_hba.conf pod ağından bu rollere izin vermiyorsa bir satır eklemeniz gerekir:"
  echo "    host  diecutting_dev,diecutting_prod  diecutting_dev,diecutting_prod  <pod-cidr>  scram-sha-256"
}

encrypt_to() {
  local target="$1"
  local plain="${target%.enc.yaml}.plain.yaml"
  mkdir -p "$(dirname "$target")"
  cat > "$plain"
  sops --encrypt --filename-override "$target" "$plain" > "$target"
  rm -f "$plain"
}

secrets_step() {
  : "${GHCR_USER:?GHCR_USER gerekli}"
  : "${GHCR_TOKEN:?GHCR_TOKEN gerekli (read:packages yetkili PAT)}"
  local auth; auth="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 | tr -d '\n')"
  local dockercfg
  dockercfg="{\"auths\":{\"ghcr.io\":{\"username\":\"${GHCR_USER}\",\"password\":\"${GHCR_TOKEN}\",\"auth\":\"${auth}\"}}}"

  for env in $ENVS; do
    local pass; pass="$(secret_for "db-${env}")"
    local jwt; jwt="$(secret_for "auth-${env}")"
    log "Secret'lar: ${env}"
    encrypt_to "be/overlays/${env}/secrets/api-secrets.enc.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: leda-diecutting-api-secrets
type: Opaque
stringData:
  DATABASE_URL: postgres://diecutting_${env}:${pass}@${DB_HOST}:${DB_PORT}/diecutting_${env}
  AUTH_SECRET: ${jwt}
YAML
    for component in be fe; do
      encrypt_to "${component}/overlays/${env}/secrets/ghcr-pull.enc.yaml" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: '${dockercfg}'
YAML
    done
  done
  log "Şifreli dosyalar yazıldı. Gözden geçirip commit edin:"
  echo "    git add */overlays/*/secrets/*.enc.yaml && git commit -m 'chore: secrets' && git push"
}

argocd_step() {
  for env in $ENVS; do
    for component in be fe; do
      log "ArgoCD: leda-diecutting-${component}-${env}"
      $KUBECTL apply -f - < "argocd/leda-diecutting-${component}-${env}.yaml"
    done
  done
}

case "$STEP" in
  db) db_step ;;
  secrets) secrets_step ;;
  argocd) argocd_step ;;
  all) db_step; secrets_step; argocd_step ;;
  *) die "Bilinmeyen adım: $STEP (db | secrets | argocd | all)" ;;
esac

log "Tamam."
