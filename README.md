# Leda Diecutting kube-objects

Netcup k3s kümesi için GitOps manifest'leri (ArgoCD + Kustomize + KSOPS). Branch: `main`.

| Ortam | Web | API | Namespace | Deploy |
|-------|-----|-----|-----------|--------|
| dev | `dev-diecutting.ledayazilim.com` | `dev-api-diecutting.ledayazilim.com` | `leda-diecutting-dev` | FE/BE `main` push'unda **otomatik** |
| prod | `diecutting.ledayazilim.com` | `api-diecutting.ledayazilim.com` | `leda-diecutting-prod` | FE/BE `main` push'unda **otomatik** (geri alma: "Prod sürüm seç" workflow'u) |

```
be/base, fe/base          ortak Deployment / Service / Ingress
*/overlays/{dev,prod}     namespace, host, env, imaj tag'i, SOPS secret'ları
argocd/                   leda-diecutting-{be,fe}-{dev,prod} Application'ları
scripts/bootstrap.sh      DB + secret + ArgoCD tek seferlik kurulum
```

## Akış

```
FE/BE main push ─► GitHub Actions ─► ghcr.io/sdsonbay/ledayazilim-diecutting-{fe,be}:{sha,prod}-xxxxxxx
                                └─► */overlays/dev  newTag sha-xxxxxxx  ─► ArgoCD ─► dev
                                └─► */overlays/prod newTag prod-xxxxxxx ─► ArgoCD ─► prod
"Prod sürüm seç (geri alma)" (manuel) ─► seçilen sha-… imajı → prod-… ─► */overlays/prod
```

Web pod'u `/api/` isteklerini kümedeki `leda-diecutting-api` servisine proxy'ler; mobil uygulama doğrudan API host'una gider.
API açılışta `sql/*.sql` migration'larını kendisi uygular.

## Kurulum durumu (2026-10-04)

- **DNS** (Route53 `ledayazilim.com`): dört host → `159.195.150.97`
- **Postgres** (Netcup host, PG 17): `diecutting_dev` / `diecutting_prod` rol + veritabanı; `pg_hba.conf`'ta
  `10.42.0.0/16` (pod ağı) satırları. Şifreler yalnız SOPS secret'larında ve yerel `.bootstrap/`'ta.
- **ArgoCD**: `leda-diecutting-{be,fe}-{dev,prod}`; repo public olduğundan repo credential gerekmez.
- **GitHub**: FE ve BE repolarında `KUBE_OBJECTS_DEPLOY_KEY` secret'ı; bu repoda karşılığı yazma yetkili deploy key.

## İlk kurulum (yeniden gerekirse, Mac'ten)

1. **DNS** — dört host'un A kaydı Netcup sunucusunu göstermeli.
2. **Bootstrap** (SSH + sops + age anahtarı gerekir):
   ```bash
   export SSH_TARGET=deploy@159.195.150.97
   export DB_HOST=159.195.150.97
   export GHCR_USER=sdsonbay GHCR_TOKEN=<read:packages PAT (classic)>
   scripts/bootstrap.sh
   git add */overlays/*/secrets/*.enc.yaml && git commit -m "chore: secrets" && git push
   ```
   Yalnızca `diecutting_dev` / `diecutting_prod` rol ve veritabanlarını, `leda-diecutting-*` uygulamalarını oluşturur.
   `deploy` kullanıcısının `sudo`'su şifre istediğinden Postgres komutları ayrıcalıklı geçici bir pod ile
   (`nsenter` + `sudo -u postgres psql`) verilir: `PSQL_ADMIN="ssh … <host-exec-yardımcısı> 'sudo -u postgres psql …'"`.
3. **GitHub** — FE ve BE repolarında:
   - Secret `KUBE_OBJECTS_DEPLOY_KEY`: bu repoya yazma yetkili deploy key'in özel anahtarı
   - Environment `production` (onay istenirse *Required reviewers*)

## Secret düzenleme

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops be/overlays/prod/secrets/api-secrets.enc.yaml
```

| Dosya | Anahtarlar |
|-------|------------|
| `be/overlays/*/secrets/api-secrets.enc.yaml` | `DATABASE_URL`, `AUTH_SECRET` |
| `{be,fe}/overlays/*/secrets/ghcr-pull.enc.yaml` | `.dockerconfigjson` (ghcr.io); secret adı BE `ghcr-pull`, FE `ghcr-pull-web` |

## Geri alma

FE/BE reposunda Actions → "Prod sürüm seç (geri alma)" → önceki `sha-…` tag'i. Ya da
`*/overlays/prod/kustomization.yaml` içindeki `newTag`'i önceki `prod-…` değerine çekip push edin.
