# Leda Diecutting kube-objects

Netcup k3s kümesi için GitOps manifest'leri (ArgoCD + Kustomize + KSOPS). Branch: `main`.

| Ortam | Web | API | Namespace | Deploy |
|-------|-----|-----|-----------|--------|
| dev | `dev-diecutting.ledayazilim.com` | `dev-api-diecutting.ledayazilim.com` | `leda-diecutting-dev` | FE/BE `main` push'unda **otomatik** |
| prod | `diecutting.ledayazilim.com` | `api-diecutting.ledayazilim.com` | `leda-diecutting-prod` | FE/BE reposunda **manuel** "Deploy prod" (onaylı) |

```
be/base, fe/base          ortak Deployment / Service / Ingress
*/overlays/{dev,prod}     namespace, host, env, imaj tag'i, SOPS secret'ları
argocd/                   leda-diecutting-{be,fe}-{dev,prod} Application'ları
scripts/bootstrap.sh      DB + secret + ArgoCD tek seferlik kurulum
```

## Akış

```
FE/BE main push ─► GitHub Actions ─► ghcr.io/sdsonbay/ledayazilim-diecutting-{fe,be}:sha-xxxxxxx
                                └─► */overlays/dev/kustomization.yaml newTag ─► ArgoCD ─► dev
"Deploy prod" (production onayı) ─► aynı imaj → prod-xxxxxxx ─► */overlays/prod ─► ArgoCD ─► prod
```

Web pod'u `/api/` isteklerini kümedeki `leda-diecutting-api` servisine proxy'ler; mobil uygulama doğrudan API host'una gider.

## İlk kurulum (bir kez, Mac'ten)

1. **DNS** — dört host'un A kaydı Netcup sunucusunu göstermeli.
2. **Bootstrap** (SSH + sops + age anahtarı gerekir):
   ```bash
   export SSH_TARGET=deploy@<netcup-ip>
   export DB_HOST=<pod'ların Postgres'e eriştiği adres>
   export GHCR_USER=sdsonbay GHCR_TOKEN=<read:packages PAT>
   scripts/bootstrap.sh
   git add */overlays/*/secrets/*.enc.yaml && git commit -m "chore: secrets" && git push
   ```
   Yalnızca `diecutting_dev` / `diecutting_prod` rol ve veritabanlarını, `leda-diecutting-*` uygulamalarını oluşturur.
   Postgres süper kullanıcı komutu farklıysa `PSQL_ADMIN="..."` ile verin.
3. **GitHub** — FE ve BE repolarında:
   - Secret `KUBE_OBJECTS_TOKEN`: bu repoya `Contents: Read and write` yetkili fine-grained PAT
   - Settings → Environments → `production` → *Required reviewers* (prod onayı buradan gelir)

## Secret düzenleme

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops be/overlays/prod/secrets/api-secrets.enc.yaml
```

| Dosya | Anahtarlar |
|-------|------------|
| `be/overlays/*/secrets/api-secrets.enc.yaml` | `DATABASE_URL`, `AUTH_SECRET` |
| `{be,fe}/overlays/*/secrets/ghcr-pull.enc.yaml` | `.dockerconfigjson` (ghcr.io) |

## Geri alma

`*/overlays/prod/kustomization.yaml` içindeki `newTag`'i önceki `prod-…` değerine çekip push edin; ArgoCD eski imaja döner.
