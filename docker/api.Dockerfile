# The same API code, run as a container instead of on Cloudflare's servers.
# Inside: workerd (the open-source runtime Cloudflare Workers run on) and a SQLite file for the database.
# This is the container side of the serverless-against-containers comparison (report, goal 1).
FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY wrangler.toml ./
COPY migrations ./migrations
COPY src ./src
COPY functions ./functions
COPY public ./public
RUN npx wrangler d1 migrations apply countonce --local
EXPOSE 8788
# COUNTONCE_STAFF_KEY, when given, becomes the staff key the API asks for.
CMD ["sh", "-c", "exec npx wrangler pages dev --ip 0.0.0.0 --port 8788 ${COUNTONCE_STAFF_KEY:+--binding \"STAFF_KEY=$COUNTONCE_STAFF_KEY\"}"]
