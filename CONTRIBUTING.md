# Contributing

## Setup

```bash
npm install
npm run build
node dist/server/standalone.js
```

## Guidelines

- TypeScript with strict mode
- Use `spawn()` instead of shell execution
- Keep changes focused

## Testing

```bash
curl http://localhost:3456/health
curl http://localhost:3456/v1/models
```
