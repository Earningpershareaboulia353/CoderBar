# CoderBar website

The product site for CoderBar. It uses vinext and produces a Cloudflare Worker-compatible build.

## Local development

```bash
npm install
npm run dev
npm run build
npm test
```

Node.js 22.13 or newer is required.

Product content lives in `app/page.tsx`, visual tokens and responsive layouts live in `app/globals.css`, and downloadable product assets live in `public/`.
