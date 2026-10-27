import { describe, expect, it } from 'vitest';
import { useApi } from '../helpers/api';

// DB kosong (hanya hasil `prisma migrate deploy`), kondisi yang sama dengan
// DAST ZAP di build.yml: setiap endpoint harus 200, tanpa NaN/Infinity.
// Fitur baru menambahkan path-nya ke daftar ini.
const ENDPOINTS = [
  '/dashboard/filters',
  '/dashboard/overview',
  '/dashboard/overview?year=2004&month=1&continent=Europe&country=Norway',
  '/dashboard/products',
  '/dashboard/products?productLine=Ships&productLine=Trains&year=2004&month=1',
  '/dashboard/growth',
  '/dashboard/growth?year=2004',
  '/dashboard/customers',
  '/dashboard/customers?year=2004&continent=Asia&country=Japan',
  '/dashboard/operations',
  '/dashboard/operations?year=2004&status=On%20Hold',
  '/dashboard/insights',
];

const get = useApi();

describe('DB kosong', () => {
  it.each(ENDPOINTS)('%s menjawab 200', async (path) => {
    const res = await get(path);
    expect(res.status).toBe(200);
    expect(JSON.stringify(res.body)).not.toMatch(/NaN|Infinity/);
  });

  it('insights = array kosong', async () => {
    expect((await get('/dashboard/insights')).body.data).toEqual([]);
  });
});
