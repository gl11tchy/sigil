FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY server.mjs revision.mjs revision.json ./
COPY public ./public
RUN node --input-type=module -e "import { loadRevision } from './revision.mjs'; await loadRevision(undefined, { required: true });"
USER node
ENV PORT=3000 SIGIL_REQUIRE_REVISION=1
EXPOSE 3000
CMD ["node", "server.mjs"]
