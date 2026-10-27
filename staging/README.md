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

## Kenapa tidak lewat Pterodactyl

Pterodactyl adalah panel server game. Server game dijalankan Wings sebagai satu container yolk dengan aturan Wings sendiri: file di `/home/container`, user UID `988`, startup command dari egg, dan satu container per server. Image BE/FE di repo ini sengaja dibuat lain (user `node`/`101`, filesystem image sendiri, nginx non-root di port 8080), dan staging butuh tiga sampai empat container yang saling bicara lewat network privat. Memaksakannya ke egg berarti membongkar hardening image, dan tetap tanpa health check, rollback, atau deploy by digest.

VPS staging kelompok ini (Ubuntu 24.04, x86_64, RAM 842 MB, 2 vCPU, Azure) hanya menjalankan **Panel** Pterodactyl (nginx, PHP-FPM, queue worker, MariaDB, Redis), **tanpa Wings dan tanpa Docker**. Jadi Docker Engine dipasang sendiri (langkah 3), lalu BE, FE, dan cloudflared dijalankan dengan `docker compose`. Database staging menumpang di MariaDB host milik Panel, dengan database dan user tersendiri (langkah 5). Panel tetap berjalan di host seperti biasa. Kalau suatu saat Wings dipasang di VPS yang sama, keduanya tetap bisa hidup berdampingan: Wings hanya mengurus container buatannya sendiri, network-nya terpisah (`axon-staging` bukan `pterodactyl_nw`), dan stack ini tidak mem-publish port.

## Anggaran memori

| Komponen | `mem_limit` | Pemakaian normal |
|---|---|---|
| dockerd + containerd | - | sekitar 60–100 MB |
| MariaDB | sudah ada untuk Panel | tambahan kecil (data classicmodels hanya beberapa MB) |
| BE (Node, heap maks 160 MB) | 256 MB | sekitar 70–110 MB (perkiraan, belum diukur dengan image asli) |
| FE (nginx) | 64 MB | sekitar 5–10 MB |
| cloudflared | 64 MB | sekitar 20–35 MB |

Tambahannya sekitar 160–250 MB, sedangkan `available` VPS sebelum staging hanya sekitar 395 MB. Artinya staging **akan** memakai swap. Itu masih dapat diterima untuk staging yang hanya diakses tim (respons lebih lambat, bukan crash), asalkan swap 2 GB ada dan RAM Panel dihemat (langkah 2). Untuk beban yang lebih serius, 1 GB memang terlalu kecil; naikkan VPS ke 2 GB.

## Persiapan VPS (sekali, sebelum branch ini di-merge)

Perintah dijalankan sebagai root (`sudo -i`), kecuali disebut lain.

### 1. Cek kondisi

```bash
uname -m                         # harus x86_64: image hanya di-build untuk amd64
free -m                          # sisa RAM dan swap
swapon --show                    # swap 2 GB harus ada
ps aux --sort=-rss | head -20    # siapa yang memakan RAM
systemctl is-active mariadb mysql redis-server nginx 2>/dev/null
```

Swap 2 GB sudah ada di VPS ini. Kalau suatu saat hilang (mis. VPS dibuat ulang):

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

Turunkan kecenderungan swap, supaya swap hanya dipakai saat benar-benar perlu:

```bash
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf && sysctl --system
```

### 2. Hemat RAM Panel

Tiga worker `php-fpm: pool www` memakan sekitar 45 MB masing-masing walau Panel sedang tidak dibuka. Dengan `pm = ondemand`, worker hanya hidup saat ada request, lalu dimatikan setelah 30 detik menganggur. Panel tetap berfungsi; hanya request pertama setelah lama diam terasa sedikit lebih lambat.

```bash
f=$(ls /etc/php/*/fpm/pool.d/www.conf | head -n 1); echo "$f"
cp "$f" "$f.bak"
sed -i -E 's/^pm = .*/pm = ondemand/; s/^;?pm.max_children = .*/pm.max_children = 4/; s/^;?pm.process_idle_timeout = .*/pm.process_idle_timeout = 30s/' "$f"
systemctl restart 'php*-fpm.service'
systemctl list-units 'php*-fpm*'     # pastikan statusnya active (running)
```

Opsional, menghemat sekitar 30 MB lagi: Panel tidak membutuhkan snap.

```bash
snap list                        # pastikan tidak ada snap yang dipakai
apt purge -y snapd
```

### 3. Pasang Docker Engine

Dari repositori resmi Docker, yang sekaligus memasang plugin `docker compose`:

```bash
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
less /tmp/get-docker.sh          # baca dulu sebelum menjalankan skrip dari internet
sh /tmp/get-docker.sh
```

Batasi ukuran log container, supaya disk dan memori tidak habis oleh log:

```bash
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
systemctl restart docker
docker version --format '{{.Server.Version}}' && docker compose version
```

Docker mengatur iptables sendiri, tetapi tidak menyentuh nginx Panel di port 80/443, karena stack staging tidak mem-publish port apa pun.

### 4. User deploy dan direktori stack

```bash
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy        # grup docker = setara root, karena itu kuncinya dikunci (langkah 7)
install -d -o deploy -g deploy -m 750 /opt/axon-staging
```

### 5. Salin file dan siapkan database

Dari laptop, di root repo BE (ganti `vps` dengan host SSH admin):

```bash
scp staging/compose.yaml staging/.env.example vps:/opt/axon-staging/
scp staging/axon-staging.sh vps:/usr/local/bin/axon-staging
scp test/fixtures/classicmodels.sql vps:/tmp/classicmodels.sql
```

Lalu di VPS. Pertama skrip dan `.env`:

```bash
chmod 755 /usr/local/bin/axon-staging && chown root:root /usr/local/bin/axon-staging
cd /opt/axon-staging
cp .env.example .env && chmod 600 .env
sed -i "s/^APP_DB_PASSWORD=.*/APP_DB_PASSWORD=$(openssl rand -hex 24)/" .env
nano .env                        # isi TUNNEL_TOKEN (langkah 6)
chown -R deploy:deploy /opt/axon-staging
```

Skrip dimiliki root dan tidak bisa ditulis user `deploy`: kunci CI tidak bisa mengubah perintah yang dijalankannya sendiri.

Kedua, database `classicmodels` di MariaDB host. Dump membuat database-nya sendiri, terpisah dari database Panel (`panel`). User `'classicmodels_app'@'localhost'` hanya punya `SELECT` di database itu, jadi tidak bisa membaca atau mengubah data Panel:

```bash
mariadb < /tmp/classicmodels.sql && rm /tmp/classicmodels.sql
PW=$(sed -n 's/^APP_DB_PASSWORD=//p' /opt/axon-staging/.env)
mariadb -e "CREATE USER 'classicmodels_app'@'localhost' IDENTIFIED BY '$PW';
            GRANT SELECT ON classicmodels.* TO 'classicmodels_app'@'localhost';"
unset PW
mariadb -e "SHOW GRANTS FOR 'classicmodels_app'@'localhost'"
```

Ketiga, jaga folder socket tetap sama saat MariaDB di-restart. Container BE me-mount `/run/mysqld` dari host. Secara bawaan systemd menghapus folder itu setiap MariaDB berhenti (mis. saat `unattended-upgrades` memasang pembaruan keamanan), lalu membuat folder baru. Container masih menunjuk folder lama, dan BE kehilangan database sampai di-restart. Ini mencegahnya:

```bash
mkdir -p /etc/systemd/system/mariadb.service.d
printf '[Service]\nRuntimeDirectoryPreserve=yes\n' > /etc/systemd/system/mariadb.service.d/staging-socket.conf
systemctl daemon-reload && systemctl restart mariadb
```

Keempat, pastikan socket itu tidak membuka pintu lain. MariaDB di Ubuntu mengizinkan login lewat `unix_socket` berdasarkan UID proses. Proses di container BE berjalan sebagai UID 1000. Jadi pastikan tidak ada akun MariaDB `unix_socket` milik user host ber-UID 1000:

```bash
getent passwd 1000 | cut -d: -f1                 # nama user host ber-UID 1000, kalau ada
mariadb -e "SELECT user, host FROM mysql.global_priv WHERE priv LIKE '%unix_socket%'"
```

Yang boleh muncul hanya `root` dan `mysql`. Kalau nama dari perintah pertama ikut muncul, hapus akun itu atau ganti plugin-nya ke password.

### 6. Cloudflare Tunnel

Di Cloudflare Zero Trust: **Networks → Tunnels → Create a tunnel** (tipe Cloudflared), salin token-nya ke `TUNNEL_TOKEN` di `.env`. Tambahkan **Public Hostname**, mis. `staging.domain-anda.com`, dengan service `http://devsecops_fe:8080`. API ikut lewat proxy `/api/` milik nginx FE, sama dengan produksi.

Disarankan memasang **Cloudflare Access** di hostname itu supaya staging tidak terbuka untuk umum. Kalau dipasang, smoke test publik di `staging.yml` akan dialihkan ke halaman login; kosongkan `STAGING_URL` atau buat service token.

Tanpa Cloudflare: kosongkan `COMPOSE_PROFILES`, set `BEHIND_CLOUDFLARE=false`, aktifkan baris `ports: ["127.0.0.1:8081:8080"]` di `compose.yaml`, lalu akses lewat `ssh -L 8081:127.0.0.1:8081 vps`.

Jalankan tunnel (BE dan FE baru muncul setelah pipeline pertama):

```bash
sudo -u deploy docker compose -f /opt/axon-staging/compose.yaml up -d cloudflared
```

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

### 8. Secret dan variable organisasi di GitHub

Cukup **sekali** untuk kedua repo, di **Organization `kel-2-wdevsecops` → Settings → Secrets and variables → Actions**. Setiap secret dan variable diberi **Repository access → Selected repositories → `axon-sales-backend` dan `axon-sales-frontend`**, jangan *All repositories*, supaya repo lain di organisasi tidak bisa memakai kunci VPS.

| Tab | Nama | Isi |
|---|---|---|
| Secrets | `STAGING_SSH_HOST` | IP atau hostname VPS |
| Secrets | `STAGING_SSH_KEY` | isi file `axon-staging-ci` (private key) |
| Secrets | `STAGING_SSH_KNOWN_HOSTS` | isi file `known_hosts` dari langkah 7 |
| Variables | `STAGING_SSH_USER` | `deploy` (opsional, default `deploy`) |
| Variables | `STAGING_URL` | `https://staging.domain-anda.com` (opsional, untuk smoke test) |

`NTFY_TOPIC` boleh ikut dipindah ke organisasi dengan cara yang sama.

Hal yang perlu diperhatikan:

- **Paket GitHub.** Pada paket GitHub Free, secret dan variable organisasi hanya bisa dibaca repo **publik**. Kalau kedua repo privat dan organisasinya Free, nilai ini terbaca kosong dan job staging gagal dengan pesan "Secret organisasi untuk staging belum lengkap". Pilihannya: naik ke GitHub Team (untuk keperluan kuliah, dosen dapat mengajukannya lewat GitHub Education), atau kembali memakai secret di environment `staging` masing-masing repo. Nama secret-nya sama, jadi workflow tidak perlu diubah.
- **Jangan ada salinan dengan nama sama** di repo atau environment. Urutan prioritas GitHub adalah environment → repo → organisasi, jadi salinan lama akan diam-diam menimpa nilai organisasi.
- **Pagar cabang tetap lewat environment.** Secret organisasi tidak bisa dibatasi per cabang. Karena itu job staging tetap memakai environment `staging` tanpa secret di dalamnya. Di kedua repo, buka **Settings → Environments → `staging`** (dibuat otomatis pada run pertama, atau buat manual), lalu di **Deployment branches and tags** pilih *Selected branches* → `main`.

Setelah semua secret terisi, hapus `axon-staging-ci` dari laptop.

### 9. Urutan aktivasi

1. Langkah 1–8 selesai, `ssh ... version` berhasil.
2. Merge PR repo BE lebih dulu, lalu repo FE. Push merge itu langsung menjalankan staging; pantau tab Actions.
3. Cek `ssh -i ... deploy@IP_VPS status` atau buka `STAGING_URL`.
4. Isi variable `STAGING_URL` **setelah** BE dan FE sama-sama pernah ter-deploy. Smoke test BE lewat nginx FE (`/api/v1/health`), jadi kalau diisi sebelum container FE ada, staging BE akan gagal.

Selama secret organisasi di atas belum terisi atau belum dibuka untuk repo ini, job staging **gagal** dan rilis tertahan. Itu disengaja: staging adalah gerbang, bukan hiasan.

## Operasional

| Kebutuhan | Perintah |
|---|---|
| Status stack dan RAM | `sudo -u deploy axon-staging status` |
| Log BE | `sudo -u deploy docker compose -f /opt/axon-staging/compose.yaml logs --tail 100 devsecops_be` |
| Reset data staging | `mariadb < classicmodels.sql` (dump menghapus dan membuat ulang tabelnya), user dan grant tetap |
| Kenapa digest X jalan | `grep _IMAGE= /opt/axon-staging/.env`, lalu cocokkan dengan run Actions |

`compose.yaml` dan `axon-staging.sh` **tidak** disinkronkan oleh workflow. Kalau file itu berubah di repo, salin ulang secara manual (langkah 5). Ini harga dari keamanan: kunci CI yang bisa mengganti `compose.yaml` bisa menjalankan container `privileged` dan menguasai seluruh VPS, termasuk Pterodactyl.

## Kalau gagal

| Gejala | Penyebab umum |
|---|---|
| `Host key verification failed` | `STAGING_SSH_KNOWN_HOSTS` kosong/salah, atau VPS di-reinstall |
| `Permission denied (publickey)` | baris `authorized_keys` salah, atau mode file bukan `600` |
| `denied` saat `docker pull` | package GHCR belum memberi akses repo ini (Package settings → Manage Actions access) |
| BE tidak sehat, rollback (`exit 3`) | biasanya DB: `APP_DB_PASSWORD` di `.env` berbeda dengan password user `classicmodels_app`, atau MariaDB host mati (`systemctl status mariadb`) |
| BE sempat sehat, lalu `/api/v1/health` gagal setelah MariaDB di-restart | drop-in `RuntimeDirectoryPreserve=yes` (langkah 5) belum dipasang; restart BE: `docker compose up -d --force-recreate devsecops_be` |
| Container mati dengan `OOMKilled` | RAM habis: lihat `free -m`, jalankan langkah 2, atau naikkan VPS |
| `exec format error` | VPS bukan x86_64 |
