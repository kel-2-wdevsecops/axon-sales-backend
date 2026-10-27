# Axon Sales API (BE)

API **publik dan hanya-baca** untuk dashboard penjualan Axon, retailer miniatur mobil klasik. Datanya adalah database MySQL `classicmodels` (dump-nya ada di folder `Context/` di samping folder repo ini). Dashboard-nya meniru laporan Power BI Axon (Ringkasan, Produk, Pertumbuhan) dan menambah halaman Pelanggan, Operasional, serta sorotan insight. Rinciannya di `docs/PRD.md`.

Tidak ada login, akun, maupun endpoint tulis: dump aslinya tidak punya tabel pengguna, dan dashboard memang terbuka untuk umum. Karena hanya membaca, user DB aplikasi cukup punya hak `SELECT`.

Stack: Node.js 24, TypeScript, Express 5, Prisma 7 (adapter `mariadb`, kompatibel MySQL/MariaDB), Zod 4, Vitest.

## Menjalankan di lokal

1. **Impor dump** ke MySQL/MariaDB (membuat database `classicmodels`):
   ```bash
   mariadb -u root -p < "../Context/Axon sales - Mysql Database.sql"
   ```
2. **Buat user DB untuk aplikasi**, hanya dengan hak baca (jangan pakai root):
   ```sql
   CREATE USER 'classicmodels_app'@'localhost' IDENTIFIED BY '<password>';
   GRANT SELECT ON classicmodels.* TO 'classicmodels_app'@'localhost';
   ```
3. **Konfigurasi**: salin `.env.example` ke `.env`, lalu isi `DATABASE_URL`.
4. **Install & generate client**:
   ```bash
   npm install
   npm run db:generate
   ```
5. `npm run dev` lalu buka `http://localhost:3008/api/v1/dashboard/overview`.

## Perintah

| Perintah | Fungsi |
|---|---|
| `npm run dev` | Server dev dengan reload (tsx watch) |
| `npm run build` / `npm start` | Kompilasi ke `dist/` / jalankan hasilnya |
| `npm test` | Unit test (Vitest, file `*.test.ts` di samping kodenya) |
| `npm run test:golden` | Tes angka emas: endpoint dipanggil lewat HTTP terhadap DB berisi dump (`test/golden/`) |
| `npm run test:empty` | Semua endpoint 200 pada DB kosong (`test/empty/`); `DATABASE_URL` harus menunjuk DB hasil `db:deploy` |
| `npm run lint` | ESLint, warning pun gagal (sama dengan CI) |
| `npm run db:generate` | Generate Prisma client ke `src/generated/prisma` (tidak di-commit) |
| `npm run db:pull` | Introspeksi ulang DB ke `prisma/schema.prisma` |
| `npm run db:migrate` / `db:deploy` | Migrasi Prisma (butuh user ber-hak DDL; lihat bagian Skema) |

## Struktur

```text
prisma/
  schema.prisma          8 model hasil `prisma db pull`, sama persis dengan dump
  migrations/0_init      baseline dari dump
src/
  app.ts                 middleware global, /health, pendaftaran route modul
  server.ts              bootstrap + graceful shutdown
  config/                env (divalidasi saat start), Prisma client, ambang (thresholds.ts)
  middleware/            error handler (Zod -> 422), rate limit
  lib/                   fungsi murni bersama (+ test): money, continents, filters (cacheKey),
                         sqlFilters, querySchemas (skema Zod), cache, growth, insights
  modules/               satu folder per endpoint: filters, overview, products, growth,
                         customers, operations, insights
  utils/                 ApiResponse, asyncHandler, clientIp, ttlCache
test/
  fixtures/              dump classicmodels untuk tes angka emas
  golden/                tes angka emas per fitur (butuh DB berisi dump)
  empty/                 semua endpoint 200 pada DB kosong (hasil migrasi saja)
  helpers/               app di port acak (`useApi`), pemeriksa kunci terlarang
.semgrep/                aturan Semgrep custom (larangan $queryRawUnsafe) + contohnya
```

## Menambah modul

Satu folder per endpoint, mis. `src/modules/overview/`:

- **`<nama>.routes.ts`**: `Router` Express, hanya `GET`. Daftarkan di `src/app.ts`: `api.use('/dashboard/<nama>', <nama>Routes)`.
- **`<nama>.controller.ts`**: tipis. Parse query string dengan DTO, panggil service, kirim `ApiResponse.cached` (menambah `Cache-Control: public, max-age=300`). Setiap handler dibungkus `asyncHandler`, supaya error (termasuk `ZodError` -> 422) sampai ke error middleware.
- **`<nama>.dto.ts`**: `z.object({...}).strict()` dari skema bersama di `lib/querySchemas.ts`. Nilai yang tidak valid dan parameter tak dikenal ditolak 422, bukan ditebak.
- **`<nama>.service.ts`**: query Prisma. Agregat lintas tabel boleh `prisma.$queryRaw` **tagged template** (nilai filter jadi parameter terikat); jangan pernah `$queryRawUnsafe` atau string SQL yang digabung manual. Potongan kondisi dinamis disusun dengan `lib/sqlFilters.ts`. Loader dibungkus `cached()` dari `lib/cache.ts`. Semgrep custom di CI menolak `$queryRawUnsafe`/`$executeRaw*`.
- Fungsi murni (perhitungan, pemetaan) di `lib/` dengan file `*.test.ts` di sampingnya.

Catatan data:
- `COUNT` dari `$queryRaw` datang sebagai `bigint` dan `SUM` sebagai `Decimal`: ubah dengan `toNumber()` dari `lib/money.ts`.
- Angka yang bisa dicocokkan dengan PRD ditambahkan sebagai asersi di `test/golden/<fitur>.test.ts`, beserta pemeriksaan `forbiddenKeys` (minimasi data).
- Ada nilai negara dengan spasi di belakang (`"Norway  "`); trim sebelum dipakai sebagai label.

## API

Semua di bawah `/api/v1`, hanya `GET`, tanpa login, format `{ success, message, data, errors? }`. Kontrak lengkap (bentuk respons dan aturan bisnis) ada di `docs/features/`; daftar fitur dan statusnya di `docs/PRD.md` §7.

| Endpoint | Fitur | Filter |
|---|---|---|
| `GET /health` | cek DB + versi rilis (dipakai CI/CD) | – |
| `GET /dashboard/filters` | F06: pilihan filter (rentang data, tahun, benua, negara, product line, status) | – |
| `GET /dashboard/overview` | F01: KPI, top 5 negara, customer per benua/negara, penjualan per tahun | `year`, `month`, `continent`, `country` |
| `GET /dashboard/products` | F02: KPI, penjualan per product line, order per tahun/bulan, top 5 vendor, semua produk | `productLine` (boleh berulang), `year`, `month` |
| `GET /dashboard/growth` | F03: YoY, QoQ, MoM, YTD, penjualan & profit per tahun | `year` |
| `GET /dashboard/customers` | F04: KPI pelanggan, top 10 customer, sales rep, kantor, segmen credit limit | `year`, `continent`, `country` |
| `GET /dashboard/operations` | F05: KPI fulfillment, penjualan per status, order perlu perhatian, lama kirim | `year`, `status` |
| `GET /dashboard/insights` | F07: 5–9 sorotan insight beserta rekomendasi | – |

Nilai di luar daftar (`continent=Mars`, `month=13`) dan parameter tak dikenal dijawab 422. Respons sukses membawa `Cache-Control: public, max-age=300`.

Definisi angka (PRD §6), supaya hasilnya bisa dicocokkan dengan Power BI:

- **Penjualan** = `SUM(quantityOrdered × priceEach)`, **profit** = `SUM(quantityOrdered × (priceEach − buyPrice))`, dari semua order termasuk yang Cancelled. Total tanpa filter: penjualan 9.604.190,61, profit 3.825.880,25; 122 customer, 23 karyawan, 110 produk, 326 order.
- **Benua** tidak ada di dump; dipetakan di `lib/continents.ts` mengikuti Power BI (Russia dan Israel di Asia).
- **Growth** dibandingkan dengan periode kalender sebelumnya (Januari 2004 vs Desember 2003). Periode tanpa pembanding bernilai `null`, bukan "Infinity". Data 2005 hanya sampai Mei (`isPartial: true`).

### Keamanan endpoint publik

- User DB hanya `SELECT`. Query lintas tabel memakai `$queryRaw` tagged template; Semgrep custom menolak `$queryRawUnsafe`/`$executeRaw*`.
- Minimasi data: tidak ada telepon, alamat, email, nama kontak, atau credit limit per customer di respons (diperiksa tes kontrak).
- Rate limit 120 request/menit per IP untuk seluruh `/api/v1`; hasil agregat di-cache 5 menit (maks. 500 entri per endpoint).
- Tanpa body parser, CORS hanya `GET`, header keamanan lewat helmet.

## Skema

`prisma/schema.prisma` sama persis dengan dump. Aplikasi tidak pernah menjalankan migrasi: container langsung `node dist/server.js`. Migrasi `0_init` dipakai untuk membuat tabel di DB kosong (uji migrasi di CI, DB untuk DAST di deploy). Kalau suatu saat perlu `prisma migrate dev` di DB lokal yang berisi dump, tandai baseline sekali dengan user ber-hak DDL:

```bash
DATABASE_URL="mysql://root:<pw>@localhost:3306/classicmodels" npx prisma migrate resolve --applied 0_init
```

Nama model dan kolom mengikuti dump apa adanya: tabel jamak huruf kecil, kolom camelCase, misalnya `customers.customerNumber`.

## CI/CD

Alur setiap push ke `main`: **ci → build → staging → release → deploy**. Setiap tahap adalah gerbang untuk tahap berikutnya.

- **Pull request ke `main`** (`ci.yml`): commitlint, lint, `npm audit`, test, typecheck, uji migrasi ke MariaDB kosong, SAST (Semgrep), secret scan (Gitleaks), SCA (Trivy fs), SBOM.
- **Push ke `main`** (`release.yml`):
  1. `ci.yml` dijalankan lagi.
  2. `build.yml`: build image, scan image (Trivy), DAST (ZAP), push `:<sha>` ke GHCR, sign (Cosign), provenance.
  3. `staging.yml`: verifikasi tanda tangan dan provenance, lalu deploy image itu by digest ke VPS staging lewat SSH, health check, rollback otomatis. Panduan VPS ada di [`staging/README.md`](staging/README.md).
  4. release-please membuka atau memperbarui **PR rilis** berdasarkan pesan commit, atau membuat tag `vX.Y.Z` kalau PR rilis baru di-merge.
- **PR rilis di-merge** (`deploy.yml`): digest yang sama dengan yang lolos staging diberi tag `:X.Y.Z` dan `:latest` (tanpa build ulang), lalu verifikasi di server produksi, deploy, health check, dan rollback otomatis.

Deploy produksi **hanya** terjadi saat PR rilis di-merge. Biarkan PR rilis terbuka sampai server siap. Staging menerima setiap push ke `main`.

Pesan commit wajib [Conventional Commits](https://www.conventionalcommits.org/). Ini dicek hook husky dan CI, dan dipakai release-please untuk menentukan versi: `feat` menaikkan minor, `fix` patch, `!` major.

Pengecualian kerentanan yang diterima ada di `.trivyignore`, lengkap dengan alasan dan tanggal kedaluwarsa. Paket-paket itu hanya ada di CLI Prisma (devDependency), tidak di image produksi.

### Topologi server

Semua container berada di satu network Docker, `uts-net`, dan **tidak ada port aplikasi yang di-publish ke host**:

```text
internet -> Cloudflare -> cloudflared --uts-net--> devsecops_fe (nginx :8080)
                                                     | /api/
                                                     v
                                                   devsecops_be (:3008) --> mysql (:3306)
```

- BE (`compose.yaml` repo ini) dan FE (`compose.yaml` repo FE) di-deploy terpisah, tapi keduanya bergabung ke `uts-net` dan saling menjangkau lewat nama service.
- `BEHIND_CLOUDFLARE=true`: IP pengunjung dibaca dari header `CF-Connecting-IP`. Ini hanya aman karena BE dan FE tidak bisa dijangkau tanpa lewat Cloudflare.
- Health check workflow berjalan di dalam container (`docker compose exec ... wget`), bukan lewat port host.

### Persiapan server (sekali, sebelum merge PR rilis pertama)

Server: self-hosted runner Windows, folder `D:\.server\kuliah\d4\devsecops\uts`.

1. Buat network: `docker network create uts-net`. Workflow deploy juga membuatnya kalau belum ada.
2. Jalankan container MySQL/MariaDB dan cloudflared di network itu (`--network uts-net`, atau `networks: [uts-net]` dengan `external: true` di compose masing-masing). Port MySQL tidak perlu di-publish ke host.
3. Impor dump ke container MySQL, lalu buat user aplikasi dengan `GRANT SELECT` saja (langkah 1–2 di atas). Host user-nya `'%'` atau subnet `uts-net`, karena koneksi datang dari container lain, bukan `localhost`.
4. Isi GitHub Secrets:
   - `DATABASE_URL`, dengan host berupa nama container MySQL, mis. `mysql://classicmodels_app:<pw>@mysql:3306/classicmodels`.
   - `NTFY_TOPIC`.

   Lalu jalankan workflow **Update Env Variables**.
5. Arahkan public hostname di Cloudflare Tunnel ke `http://devsecops_fe:8080`. API ikut lewat proxy `/api/` milik nginx FE. Kalau perlu hostname API terpisah, arahkan ke `http://devsecops_be:3008`.
6. Nyalakan "Allow GitHub Actions to create and approve pull requests" (Settings → Actions → General, di tingkat organisasi lalu repo).
