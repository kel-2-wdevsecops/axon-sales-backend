# F00 — Fondasi API: Validasi, Cache, dan Keamanan (BE)

| | |
|---|---|
| Prioritas | P0 |
| Repo / branch | BE · `feat/f00-fondasi-api` |
| Pasangan FE | Tidak ada pekerjaan FE (lihat `docs/features/F00-fondasi-api-keamanan.md` di repo FE) |
| Bergantung pada | – (fitur pertama yang dikerjakan di BE) |
| Dipakai oleh | Semua fitur BE (F01–F07) |
| Status | 🟩 Selesai (belum dirilis) |

## Tujuan

Menyediakan pola bersama untuk semua endpoint dashboard agar setiap fitur otomatis cepat, aman, dan konsisten. Fitur F01–F07 hanya menulis query dan bentuk respons; validasi, cache, dan penanganan error berasal dari fondasi ini.

## Cakupan Branch Ini

Dikerjakan di branch ini: helper bersama di `src/lib/` (`money`, `continents`, `filters`, `sqlFilters`), skema validasi bersama, konvensi cache dan respons, aturan Semgrep custom, dan harness tes angka emas.

Bukan di branch ini (dikerjakan di branch fitur masing-masing): modul `src/modules/<fitur>/`, `src/lib/growth.ts` (F03), `src/lib/insights.ts` (F07).

## Struktur Kode

```text
src/
  lib/
    continents.ts      peta negara -> benua (+ test)
    growth.ts          growthPct(), previousPeriod(), isPartial() (+ test)   <- dikerjakan di F03
    filters.ts         normalisasi filter -> cache key stabil (+ test)
    money.ts           toNumber() untuk Decimal/bigint dari $queryRaw (+ test)
    sqlFilters.ts      penyusun potongan WHERE dengan Prisma.sql/Prisma.join
  modules/
    filters/  overview/  products/  growth/  customers/  operations/  insights/
      <nama>.routes.ts  <nama>.controller.ts  <nama>.dto.ts  <nama>.service.ts
```

Router didaftarkan di `src/app.ts` setelah `api.use(apiLimiter)`, mis. `api.use('/dashboard/overview', overviewRoutes)`.

## Aturan Implementasi

**Validasi (DTO Zod)**

- Skema query memakai `z.object({...}).strict()`: parameter tak dikenal ditolak 422.
- `year`: bilangan bulat 2000–2100 (`z.coerce.number().int()`). Tahun tanpa data menghasilkan nilai nol, bukan error.
- `month`: bilangan bulat 1–12.
- `continent`: enum dari `continents.ts` (`Africa`, `Asia`, `Europe`, `North America`, `Oceania`).
- `country`: enum dari kunci peta di `continents.ts` (27 negara).
- `productLine`: menerima string atau array string (Express 5 mengubah key berulang menjadi array), maksimal 7 item, tiap item maksimal 50 karakter dan cocok dengan `^[A-Za-z &]+$`.
- `status`: enum 6 status order.
- Controller memanggil `schema.parse(req.query)`; `ZodError` diteruskan `asyncHandler` ke `error.middleware.ts` (422).

**Query**

- Gunakan Prisma Client untuk query sederhana dan `prisma.$queryRaw` tagged template untuk agregat. Potongan WHERE dinamis disusun di `sqlFilters.ts` dengan `Prisma.sql` dan `Prisma.join`.
- Dilarang: `$queryRawUnsafe`, `$executeRaw*`, dan interpolasi string ke SQL. Tambahkan aturan Semgrep custom di `.semgrep/` yang menggagalkan CI bila pola ini muncul.
- Negara selalu dibandingkan dan dikelompokkan dengan `TRIM(c.country)`.
- `COUNT` (`bigint`) dan `SUM` (`Decimal`) dikonversi dengan `toNumber()` sebelum dikirim; uang dibulatkan 2 desimal, persen 2 desimal.
- Query satu endpoint dijalankan dengan `Promise.all`.

**Cache**

- Setiap service membungkus loader dengan `createTtlCache(5 * 60_000, 500)`.
- Key cache = `filters.ts#cacheKey(filter)`: key diurutkan, array diurutkan dan di-dedup, nilai kosong dibuang. Dua URL dengan filter sama menghasilkan key yang sama.
- Controller menambahkan `Cache-Control: public, max-age=300`. Respons error tidak di-cache.

**Bentuk respons**

- Sukses: `ApiResponse.success(res, data)`.
- Hanya field yang tercantum di dokumen fitur yang boleh keluar. Bentuk respons ditulis sebagai tipe TypeScript eksplisit di service; jangan mengirim objek hasil Prisma mentah.
- Field yang tidak pernah dikirim: `phone`, `addressLine*`, `postalCode`, `email`, `extension`, `contactFirstName`, `contactLastName`, `checkNumber`, `creditLimit` per customer.

**Database kosong**

- Semua pembagian aman nol (hasil `null`), semua `SUM` di-`COALESCE` ke 0, array boleh kosong. Endpoint harus 200 pada DB hasil `prisma migrate deploy` tanpa data, karena ZAP di `build.yml` berjalan di kondisi itu.

## Langkah Pengerjaan

Catatan: belum ada endpoint di branch ini, jadi kriteria yang butuh endpoint (422, header cache, DB kosong 200) dibuktikan dengan unit test skema dan cache; pembuktian pada endpoint nyata dilakukan di F06/F01.

- [ ] 1. Buat branch `feat/f00-fondasi-api` dari `main` terbaru; ubah status F00 di `docs/PRD.md` §7 menjadi 🟨.
- [x] 2. `src/lib/money.ts`: `toNumber()` untuk `bigint`, `Decimal`, dan `null`; pembulatan 2 desimal untuk uang dan persen. Tambah `money.test.ts`.
- [x] 3. `src/lib/continents.ts`: peta 27 negara → benua sesuai PRD §6 (Europe 16, North America 2, Asia 6, Oceania 2, Africa 1), fungsi pencari benua yang men-trim nama, dan daftar enum benua/negara. Tambah `continents.test.ts` (27 negara terpetakan, `"Norway  "` setelah trim).
- [x] 4. `src/lib/filters.ts`: `cacheKey(filter)` (key diurutkan, array diurutkan dan di-dedup, nilai kosong dibuang). Tambah `filters.test.ts`.
- [x] 5. `src/lib/sqlFilters.ts`: penyusun potongan WHERE berbasis `Prisma.sql`/`Prisma.join` untuk tahun, bulan, benua/negara (`TRIM(c.country)`), product line, status. Tambah tes untuk bentuk SQL dan parameter terikat.
- [x] 6. Skema validasi bersama untuk `year`, `month`, `continent`, `country`, `productLine`, `status` (usulan lokasi: `src/lib/querySchemas.ts`; tidak tertulis di dokumen asli). Tambah tes nilai valid dan tidak valid, termasuk `.strict()` menolak parameter tak dikenal.
- [x] 7. Konvensi cache: verifikasi `createTtlCache(5 * 60_000, 500)` dan `cacheKey` dipakai bersama; tes cache (panggilan kedua dengan filter sama tidak memanggil loader).
- [x] 8. Helper controller untuk header `Cache-Control: public, max-age=300` pada respons sukses saja (error tidak di-cache).
- [x] 9. Aturan Semgrep custom di `.semgrep/` yang menolak `$queryRawUnsafe` dan `$executeRaw*`, dengan file contoh pelanggaran untuk tes aturan. Tambahkan `--config .semgrep/` ke step SAST di `.github/workflows/ci.yml`.
- [x] 10. Harness tes angka emas: salin dump ke `test/fixtures/classicmodels.sql`, skrip `npm run test:golden`, dan job CI dengan service MariaDB yang mengimpor dump. Fitur berikutnya menambah asersi angkanya ke harness ini. (Catatan: `npm test` saat ini hanya menjalankan `vitest run --dir src`.)
- [x] 11. Tes kontrak: pemeriksa yang menolak kunci terlarang (`phone`, `addressLine*`, `postalCode`, `email`, `extension`, `contactFirstName`, `contactLastName`, `checkNumber`, `creditLimit`) di objek respons; dipakai ulang oleh tiap fitur.
- [x] 12. Jalankan `npm run lint`, `npm test`, `npm run build`; pastikan CI hijau.
- [x] 13. Commit terakhir: status F00 di `docs/PRD.md` §7 menjadi 🟩, isi kolom PR; buka PR ke `main`.

## Kriteria Penerimaan

- [x] `GET /api/v1/dashboard/overview?foo=1` → 422 dengan `errors.query` atau `errors.foo`. (Dibuktikan pada endpoint nyata di F01; di F00 lewat tes skema.)
- [x] `?year=abc`, `?month=13`, `?continent=Mars` → 422.
- [x] `?productLine=Classic%20Cars&productLine=Ships` diterima sebagai array 2 item.
- [x] Dua request berurutan dengan filter sama: request kedua tidak menyentuh DB (dibuktikan dengan unit test cache atau log query dev).
- [x] Respons sukses memiliki header `Cache-Control: public, max-age=300`.
- [x] Semua endpoint 200 pada DB kosong.
- [x] Semgrep custom rule menolak `$queryRawUnsafe` (dibuktikan dengan file contoh di test rule).
- [x] Tidak ada field terlarang di respons mana pun (tes kontrak memeriksa kunci respons).

## Tes

- Unit: `continents.test.ts` (27 negara terpetakan, termasuk `"Norway  "` setelah trim), `filters.test.ts`, `money.test.ts`, skema validasi; `growth.test.ts` dikerjakan di F03; DTO tiap modul (nilai valid dan tidak valid) di branch fitur masing-masing.
- Rekonsiliasi angka emas: skrip `npm run test:golden` yang menjalankan service terhadap DB berisi dump dan membandingkan dengan angka di kriteria penerimaan F01–F05. Disarankan menambah job CI yang mengimpor dump ke service MariaDB; untuk itu dump perlu disalin ke repo BE (mis. `test/fixtures/classicmodels.sql`).

## Definisi Selesai

Semua langkah tercentang, kriteria yang bisa dibuktikan di branch ini tercentang, CI hijau (lint, test, Semgrep termasuk aturan custom, Trivy, Gitleaks), status di PRD §7 = 🟩.
