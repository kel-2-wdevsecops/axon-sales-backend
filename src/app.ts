import express, { Request, Response, NextFunction } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import { env } from './config/env';
import { prisma } from './config/database';
import { ApiResponse } from './utils/apiResponse';
import { asyncHandler } from './utils/asyncHandler';
import { clientIp } from './utils/clientIp';
import { apiLimiter, healthLimiter } from './middleware/rateLimit.middleware';

// ── Route imports ─────────────────────────────────────────────────────────────
// Satu router per modul di src/modules/<nama>/<nama>.routes.ts (lihat README).
import filtersRoutes from './modules/filters/filters.routes';
import overviewRoutes from './modules/overview/overview.routes';
import productsRoutes from './modules/products/products.routes';
import growthRoutes from './modules/growth/growth.routes';
import customersRoutes from './modules/customers/customers.routes';
import operationsRoutes from './modules/operations/operations.routes';
import insightsRoutes from './modules/insights/insights.routes';

// ── Error middleware ──────────────────────────────────────────────────────────
import { errorMiddleware } from './middleware/error.middleware';

const app = express();

// Rate limiter mengidentifikasi client lewat IP — kalau app ini jalan di
// belakang reverse proxy, IP asli cuma ada di header X-Forwarded-For.
// TRUST_PROXY berisi jumlah hop proxy tepercaya.
if (env.TRUST_PROXY) app.set('trust proxy', env.TRUST_PROXY);

// ── Security & Logging ────────────────────────────────────────────────────────
app.use(helmet());
// Origin yang tidak diizinkan cukup tidak diberi header CORS (browser yang
// memblokir), bukan dilempar sebagai error 500. FE produksi memanggil API
// lewat nginx-nya sendiri (origin yang sama), jadi CORS hanya untuk dev.
// API ini hanya-baca: cuma GET.
app.use(cors({
  origin: (origin, cb) => {
    cb(null, !origin || env.CORS_ORIGINS.includes(origin) || env.isDev);
  },
  methods:        ['GET', 'OPTIONS'],
  allowedHeaders: ['Content-Type'],
}));
morgan.token('remote-addr', (req) => clientIp(req));
app.use(morgan(env.isDev ? 'dev' : 'combined'));

// Tidak ada body parser: semua endpoint GET, dan tanpa parser body request
// apa pun tidak pernah dibaca.

// ── Health check ──────────────────────────────────────────────────────────────
app.get('/', healthLimiter, (_req: Request, res: Response) => {
  res.json({
    name:    env.APP_NAME,
    version: env.APP_VERSION,
    status:  'running',
    docs:    `${env.APP_URL}/api/v1`,
  });
});

// ── API Routes ────────────────────────────────────────────────────────────────
const api = express.Router();

// Dicek CI/CD (.github/workflows/staging.yml, deploy.yml & update_env.yml) setelah tiap
// deploy — sengaja publik (tanpa auth) dan ikut cek koneksi DB, bukan cuma
// "server hidup". `version` menunjukkan rilis mana yang sedang berjalan;
// deploy menganggap rilis gagal kalau versinya tidak sama.
api.get('/health', healthLimiter, asyncHandler(async (_req: Request, res: Response) => {
  await prisma.$queryRaw`SELECT 1`;
  ApiResponse.success(res, { status: 'ok', version: env.APP_VERSION, uptime: process.uptime() }, 'Healthy');
}));

api.use(apiLimiter);

// Dashboard publik, hanya-baca (GET), tanpa login. Satu endpoint per halaman.
api.use('/dashboard/filters', filtersRoutes);
api.use('/dashboard/overview', overviewRoutes);
api.use('/dashboard/products', productsRoutes);
api.use('/dashboard/growth', growthRoutes);
api.use('/dashboard/customers', customersRoutes);
api.use('/dashboard/operations', operationsRoutes);
api.use('/dashboard/insights', insightsRoutes);

app.use('/api/v1', api);

// ── 404 handler ───────────────────────────────────────────────────────────────
app.use((_req: Request, res: Response) => {
  res.status(404).json({ success: false, message: 'Endpoint not found.', data: null });
});

// ── Global error handler ──────────────────────────────────────────────────────
app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
  errorMiddleware(err, req, res, next);
});

export default app;
