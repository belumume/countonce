// Cloudflare Pages sends every /api/... request here; the API itself lives in src/index.ts.
import api from "../../src/index";

export const onRequest = (ctx: { request: Request; env: any }) => api.fetch(ctx.request, ctx.env);
