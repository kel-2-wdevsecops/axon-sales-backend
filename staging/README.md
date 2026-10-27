# Staging di VPS 1 GB (berdampingan dengan Pterodactyl)

Alur lengkap setiap push ke `main`:

```text
ci ──> build ──> staging ──> release ──> deploy
│      │         │           │           └ deploy.yml   : digest yang SAMA diberi tag :x.y.z/:latest,
│      │         │           │                            lalu di-deploy ke server produksi (Windows)
│      │         │           └ release-please: PR rilis / tag vX.Y.Z (hanya kalau staging sehat)
│      │         └ staging.yml : verifikasi tanda tangan, SSH ke VPS, pull by digest, health check,
│      │                         rollback otomatis
│      └ build.yml : build image, Trivy, ZAP, push :<sha>, Cosign, provenance
└ ci.yml : lint, test, typecheck, migrasi, Semgrep, Gitleaks, Trivy fs, SBOM
```

Image di-build **sekali** di runner GitHub. VPS tidak pernah menjalankan `npm` atau `docker build`; ia hanya menarik image yang sudah di-scan dan di-sign. Image yang sehat di staging adalah image yang sama, byte demi byte, yang nanti sampai ke produksi.

## Kenapa tidak lewat egg Pterodactyl

Pterodactyl adalah panel server game. Wings memang menjalankan Docker, tetapi setiap "server" adalah satu container yolk dengan aturan Wings sendiri: file di `/home/container`, user UID `988`, startup command dari egg, dan satu container per server. Image BE/FE di repo ini sengaja dibuat lain (user `node`/`101`, filesystem image sendiri, nginx non-root di port 8080), dan staging butuh tiga sampai empat container yang saling bicara lewat network privat. Memaksakannya ke egg berarti membongkar hardening image, dan tetap tanpa health check, rollback, atau deploy by digest.

Yang dipakai adalah Docker milik VPS itu sendiri (yang sudah terpasang untuk Wings) lewat `docker compose`. Wings hanya mengurus container yang ia buat sendiri, jadi stack ini tidak mengganggu server game dan sebaliknya. Network-nya pun terpisah (`axon-staging`, bukan `pterodactyl_nw`), dan tidak ada port yang di-publish, jadi tidak bentrok dengan alokasi port Wings.

## Anggaran memori

| Container | `mem_limit` | Pemakaian normal |
|---|---|---|
| MariaDB (buffer pool 64 MB, `performance_schema` mati) | 320 MB | sekitar 60–120 MB |
| BE (Node, heap maks 160 MB) | 256 MB | sekitar 70–110 MB |
| FE (nginx) | 64 MB | sekitar 5–10 MB |
| cloudflared | 64 MB | sekitar 20–35 MB |

Totalnya sekitar 250–350 MB. Wings sendiri memakai sekitar 50–100 MB. **Kalau Panel Pterodactyl (PHP-FPM, MariaDB, Redis, nginx) juga berjalan di VPS yang sama, ditambah server game, 1 GB tidak cukup**, dan swap hanya menunda OOM killer. Cek dulu sebelum lanjut (langkah 1).

## Persiapan VPS (sekali, sebelum branch ini di-merge)

Semua perintah dijalankan sebagai root di VPS, kecuali disebut lain.

### 1. Cek kondisi

```bash
uname -m                         # harus x86_64: image hanya di-build untuk amd64
free -m                          # sisa RAM sebelum staging
docker version                   # Docker sudah ada karena Wings
docker compose version           # kalau belum ada: apt install docker-compose-plugin
ps aux --sort=-rss | head -15    # siapa yang memakan RAM
systemctl is-active wings
```

Kalau `available` di `free -m` kurang dari sekitar 400 MB tanpa swap, matikan dulu server game yang tidak dipakai, atau pindahkan Panel ke mesin lain.

### 2. Swap 2 GB

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf && sysctl --system
```

### 3. Beri tahu Pterodactyl bahwa RAM itu terpakai

Di Panel: **Admin → Nodes → (node VPS ini) → Settings → Allocation Limits**, kurangi **Total Memory** sekitar 700 MB dan set **Memory Over-Allocation** ke `0`. Tanpa ini, Panel masih mengira RAM itu bebas dan akan membagikannya ke server game baru.

### 4. User deploy dan direktori stack

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy        # grup docker = setara root, karena itu kuncinya dikunci (langkah 7)
install -d -o deploy -g deploy -m 750 /opt/axon-staging
# 755: script init dibaca entrypoint MariaDB sebagai user mysql (UID 999).
install -d -o deploy -g deploy -m 755 /opt/axon-staging/initdb
```

### 5. Salin file dari repo ini

Dari laptop, di root repo BE (ganti `vps` dengan host SSH admin):

```bash
scp staging/compose.yaml staging/mariadb.cnf staging/.env.example vps:/opt/axon-staging/
scp staging/initdb/20-app-user.sh vps:/opt/axon-staging/initdb/
scp test/fixtures/classicmodels.sql vps:/opt/axon-staging/initdb/10-classicmodels.sql
scp staging/axon-staging.sh vps:/usr/local/bin/axon-staging
```

Lalu di VPS:

```bash
chmod 755 /usr/local/bin/axon-staging && chown root:root /usr/local/bin/axon-staging
chmod 755 /opt/axon-staging/initdb/20-app-user.sh
cd /opt/axon-staging
cp .env.example .env && chmod 600 .env
sed -i "s/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s/^APP_DB_PASSWORD=.*/APP_DB_PASSWORD=$(openssl rand -hex 24)/" .env
nano .env                        # isi TUNNEL_TOKEN (langkah 6)
chown -R deploy:deploy /opt/axon-staging
```

Skrip dimiliki root dan tidak bisa ditulis user `deploy`: kunci CI tidak bisa mengubah perintah yang dijalankannya sendiri.

### 6. Cloudflare Tunnel

Di Cloudflare Zero Trust: **Networks → Tunnels → Create a tunnel** (tipe Cloudflared), salin token-nya ke `TUNNEL_TOKEN` di `.env`. Tambahkan **Public Hostname**, mis. `staging.domain-anda.com`, dengan service `http://devsecops_fe:8080`. API ikut lewat proxy `/api/` milik nginx FE, sama dengan produksi.

Disarankan memasang **Cloudflare Access** di hostname itu supaya staging tidak terbuka untuk umum. Kalau dipasang, smoke test publik di `staging.yml` akan dialihkan ke halaman login; kosongkan `STAGING_URL` atau buat service token.

Tanpa Cloudflare: kosongkan `COMPOSE_PROFILES`, set `BEHIND_CLOUDFLARE=false`, aktifkan baris `ports: ["127.0.0.1:8081:8080"]` di `compose.yaml`, lalu akses lewat `ssh -L 8081:127.0.0.1:8081 vps`.

Jalankan database dan tunnel (BE dan FE baru muncul setelah pipeline pertama):

```bash
sudo -u deploy docker compose -f /opt/axon-staging/compose.yaml up -d mariadb cloudflared
sudo -u deploy docker compose -f /opt/axon-staging/compose.yaml logs -f mariadb   # tunggu "ready for connections"
```

Import dump hanya berjalan saat volume `mariadb-data` masih kosong. Setelah itu `initdb/10-classicmodels.sql` boleh dihapus untuk menghemat disk.

### 7. Kunci SSH khusus CI

Di laptop (jangan di VPS, dan jangan memakai kunci pribadi):

```bash
ssh-keygen -t ed25519 -N "" -C github-actions-staging -f axon-staging-ci
```

Di VPS, isi `/home/deploy/.ssh/authorized_keys` (satu baris, mode `600`, pemilik `deploy`):

```text
restrict,command="/usr/local/bin/axon-staging" ssh-ed25519 AAAA...isi-axon-staging-ci.pub... github-actions-staging
```

`restrict` mematikan PTY, port forwarding, agent, dan X11; `command=` memaksa setiap koneksi menjalankan `axon-staging`, apa pun perintah yang diminta. Coba dari laptop:

```bash
ssh -i axon-staging-ci deploy@IP_VPS version     # harus mencetak: 1
ssh -i axon-staging-ci deploy@IP_VPS bash        # harus ditolak: perintah tidak dikenal
```

Ambil host key VPS untuk `known_hosts`, lalu **cocokkan fingerprint-nya** dengan `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` yang dijalankan langsung di VPS:

```bash
ssh-keyscan -t ed25519 IP_VPS > known_hosts && ssh-keygen -lf known_hosts
```

Isinya satu baris `IP_VPS ssh-ed25519 AAAA...`: **host key publik** VPS, bukan sekadar alamat. Karena itu `STAGING_SSH_KNOWN_HOSTS` tidak sama dengan `STAGING_SSH_HOST`, walau keduanya memuat IP yang sama. Alamat memberi tahu runner ke mana harus menyambung; host key membuktikan bahwa yang menjawab memang VPS Anda, bukan pihak yang membajak DNS atau rute dan menunggu `GITHUB_TOKEN` dikirim. IP di dalam `known_hosts` harus persis sama dengan `STAGING_SSH_HOST`.

SSH dianggap memakai port 22. Kalau port SSH VPS diubah, tambahkan `-p PORT` di step *Deploy ke VPS staging* pada `staging.yml` kedua repo.

### 8. Environment `staging` di GitHub

Lakukan di **kedua** repo (BE dan FE): **Settings → Environments → New environment → `staging`**.

| Jenis | Nama | Isi |
|---|---|---|
| Secret | `STAGING_SSH_HOST` | IP atau hostname VPS |
| Secret | `STAGING_SSH_KEY` | isi file `axon-staging-ci` (private key) |
| Secret | `STAGING_SSH_KNOWN_HOSTS` | isi file `known_hosts` dari langkah 7 |
| Variable | `STAGING_SSH_USER` | `deploy` (opsional, default `deploy`) |
| Variable | `STAGING_URL` | `https://staging.domain-anda.com` (opsional, untuk smoke test) |

Di **Deployment branches and tags**, pilih *Selected branches* → `main`, supaya hanya workflow dari `main` yang bisa memakai kunci itu. Setelah semua secret terisi, hapus `axon-staging-ci` dari laptop.

### 9. Urutan aktivasi

1. Langkah 1–8 selesai, `ssh ... version` berhasil.
2. Merge PR repo BE lebih dulu, lalu repo FE. Push merge itu langsung menjalankan staging; pantau tab Actions.
3. Cek `ssh -i ... deploy@IP_VPS status` atau buka `STAGING_URL`.
4. Isi variable `STAGING_URL` **setelah** BE dan FE sama-sama pernah ter-deploy. Smoke test BE lewat nginx FE (`/api/v1/health`), jadi kalau diisi sebelum container FE ada, staging BE akan gagal.

Selama environment `staging` belum terisi, job staging **gagal** dan rilis tertahan. Itu disengaja: staging adalah gerbang, bukan hiasan.

## Operasional

| Kebutuhan | Perintah |
|---|---|
| Status stack dan RAM | `sudo -u deploy axon-staging status` |
| Log BE | `sudo -u deploy docker compose -f /opt/axon-staging/compose.yaml logs --tail 100 devsecops_be` |
| Reset data staging | `docker compose ... down -v`, salin ulang dump ke `initdb/`, lalu `up -d mariadb` |
| Kenapa digest X jalan | `grep _IMAGE= /opt/axon-staging/.env`, lalu cocokkan dengan run Actions |

`compose.yaml`, `mariadb.cnf`, dan `axon-staging.sh` **tidak** disinkronkan oleh workflow. Kalau file itu berubah di repo, salin ulang secara manual (langkah 5). Ini harga dari keamanan: kunci CI yang bisa mengganti `compose.yaml` bisa menjalankan container `privileged` dan menguasai seluruh VPS, termasuk Pterodactyl.

## Kalau gagal

| Gejala | Penyebab umum |
|---|---|
| `Host key verification failed` | `STAGING_SSH_KNOWN_HOSTS` kosong/salah, atau VPS di-reinstall |
| `Permission denied (publickey)` | baris `authorized_keys` salah, atau mode file bukan `600` |
| `denied` saat `docker pull` | package GHCR belum memberi akses repo ini (Package settings → Manage Actions access) |
| BE tidak sehat, rollback (`exit 3`) | biasanya DB: `APP_DB_PASSWORD` di `.env` berbeda dengan user yang dibuat saat init pertama |
| Container mati dengan `OOMKilled` | RAM habis: lihat `free -m`, matikan server game, atau naikkan VPS |
| `exec format error` | VPS bukan x86_64 |
