# Build tu thu muc goc repo: docker build -t <image> app/
FROM node:20-alpine

WORKDIR /app

# Cai dependency truoc de tan dung Docker layer cache.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY db ./db
COPY public ./public

# Tao san thu muc tmp/shared; K8s se mount de len (emptyDir/PVC).
RUN mkdir -p /app/tmp /app/shared && chown -R node:node /app

USER node
EXPOSE 3000

# Web chay server.js. CronJob ghi de command thanh ["node", "src/worker.js"],
# Job migrate/init-db ghi de tuong tu — cung 1 image cho ca 4 vai tro.
CMD ["node", "src/server.js"]
