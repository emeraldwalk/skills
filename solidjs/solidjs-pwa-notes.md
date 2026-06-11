# SolidJS PWA Scaffold — Implementation Notes

Written based on iot-garden project.

These notes capture real-world findings from setting up a plain SolidJS + Vite + vite-plugin-pwa project in this repo. A skill author should read this alongside the actual files in `pwa/` to understand what works and why.

---

## Package names (critical)

The SolidJS Vite plugin npm package is **`vite-plugin-solid`**, not `vite-plugin-solidjs`. The latter does not exist on npm. The import path in code matches the package name:

```ts
import solid from 'vite-plugin-solid'
```

Versions confirmed working (May 2026):

- `vite-plugin-solid`: `^2.11.12`
- `vite`: `^6.x`
- `vite-plugin-pwa`: `^0.21.x`
- `@vite-pwa/assets-generator`: `^0.2.6`
- `solid-js`: `^1.9.5`
- `oxlint`: `^0.16.x`
- `typescript`: `^5.8.x`

---

## tsconfig: do not include both DOM and WebWorker

Adding both `"DOM"` and `"WebWorker"` to `lib` causes TypeScript to error (TS6200) on hundreds of conflicting declarations between `lib.dom.d.ts` and `lib.webworker.d.ts`. This is a known upstream TypeScript issue.

**Fix:** omit `"WebWorker"` from the main tsconfig. For a scaffold with no custom service worker code, it isn't needed. vite-plugin-pwa's `autoUpdate`/`generateSW` strategy doesn't require it in the app tsconfig.

```json
"lib": ["ESNext", "DOM"]
```

Do **not** add `skipLibCheck: true` to paper over the conflict — fixing the lib array is the right solution.

If a future plan writes a custom service worker in TypeScript, it should get its own tsconfig (e.g. `tsconfig.sw.json`) that includes `"WebWorker"` and is referenced by vite-plugin-pwa's `injectManifest.srcDir` config.

---

## vite.config.ts: bracket notation for env access in strict mode

TypeScript strict mode flags `process.env.NODE_ENV` with a possible `undefined`. Use bracket notation and the non-null assertion isn't needed because the conditional handles it:

```ts
localIdentName: process.env['NODE_ENV'] === 'development'
  ? '[name]__[local]'
  : '[hash:base64:5]'
```

---

## vite-plugin-pwa: manifest: false

The project serves `manifest.webmanifest` as a static file from `public/`. Setting `manifest: false` in VitePWA tells the plugin not to generate or inject a manifest — it only handles the service worker. This lets the manifest be edited directly without rebuilding.

```ts
VitePWA({
  registerType: 'autoUpdate',
  manifest: false,
  devOptions: { enabled: true },
})
```

---

## PWA asset generator output names

Running `@vite-pwa/assets-generator` with `--preset minimal-2023` generates these files:

| File                           | Description            |
| ------------------------------ | ---------------------- |
| `pwa-64x64.png`                | Small transparent icon |
| `pwa-192x192.png`              | Standard manifest icon |
| `pwa-512x512.png`              | Large manifest icon    |
| `maskable-icon-512x512.png`    | Maskable icon          |
| `apple-touch-icon-180x180.png` | Apple touch icon       |
| `favicon.ico`                  | Favicon                |

Note: the apple touch icon is **`apple-touch-icon-180x180.png`**, not `apple-touch-icon.png`. The `<link rel="apple-touch-icon">` in `index.html` must match this exact filename.

The generator also logs suggested `<link>` tags and a PWA manifest icons entry to stdout — these are informational and were used to inform the manifest.

---

## OXC: ignorePatterns required for dist/

`oxlint .` from the project root lints everything including `dist/`. Minified files cause errors. Add `ignorePatterns` to `.oxlintrc.json`:

```json
{
  "ignorePatterns": ["dist/", "dev-dist/"]
}
```

Also include `"typescript"` in plugins for TypeScript-aware rules.

---

## What a skill should do

A SolidJS PWA scaffold skill should:

1. Read the project plan (or take arguments) to determine app name, theme color, and any project-specific config.
2. Create `pwa/` with the structure in `pwa/` of this repo as the canonical example.
3. Run `npm install` inside `pwa/`.
4. Create `public/logo.svg` if it doesn't exist (placeholder: green circle).
5. Run `npm run generate-pwa-assets` to produce PNG/ICO files.
6. Update `index.html` apple-touch-icon link to the actual generated filename (`apple-touch-icon-180x180.png` for minimal-2023 preset).
7. Run `npm run build` — must pass.
8. Run `npm run lint` — must pass with zero errors.
9. Run `npx tsc --noEmit` — must pass.
10. Append `pwa/node_modules/`, `pwa/dist/`, `pwa/dev-dist/`, `pwa/.vite/` to root `.gitignore`.

---

## Files to use as canonical references

All files are in `/workspaces/iot-garden/pwa/`. Read these before writing a skill:

- [pwa/package.json](../pwa/package.json) — exact deps and scripts
- [pwa/vite.config.ts](../pwa/vite.config.ts) — plugin config
- [pwa/tsconfig.json](../pwa/tsconfig.json) — strict TS config without WebWorker
- [pwa/.oxlintrc.json](../pwa/.oxlintrc.json) — OXC config with ignorePatterns
- [pwa/index.html](../pwa/index.html) — iOS meta tags + correct apple-touch-icon filename
- [pwa/src/index.tsx](../pwa/src/index.tsx) — render root
- [pwa/src/App.tsx](../pwa/src/App.tsx) — minimal root component
