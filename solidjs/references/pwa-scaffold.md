# SolidJS PWA Scaffold — Implementation Notes

Real-world pitfalls for setting up a plain SolidJS + Vite + vite-plugin-pwa project. Read this before scaffolding a new PWA so these mistakes aren't repeated.

---

## Package names (critical)

The SolidJS Vite plugin npm package is **`vite-plugin-solid`**, not `vite-plugin-solidjs`. The latter does not exist on npm. The import path in code matches the package name:

```ts
import solid from 'vite-plugin-solid'
```

Install the latest stable versions of `vite-plugin-solid`, `vite`, `vite-plugin-pwa`, `@vite-pwa/assets-generator`, `solid-js`, and `typescript` unless the project pins specific versions — check each package's changelog if a pitfall below looks version-dependent.

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

## Scaffolding checklist

When scaffolding a new SolidJS PWA project:

- [ ] Determine app name, theme color, and any project-specific config (from the project plan or task arguments).
- [ ] Create the project directory with `package.json`, `vite.config.ts`, `tsconfig.json`, lint config, `index.html`, and a minimal `src/index.tsx` + `src/App.tsx`.
- [ ] Run `npm install`.
- [ ] Create `public/logo.svg` if it doesn't exist (placeholder is fine).
- [ ] Run the PWA asset generator to produce PNG/ICO files (see output naming table above).
- [ ] Update the `index.html` apple-touch-icon link to match the actual generated filename.
- [ ] Run the build — must pass.
- [ ] Run the linter — must pass with zero errors.
- [ ] Run the TypeScript checker (`tsc --noEmit`) — must pass.
- [ ] Add the project's `node_modules/`, `dist/`, `dev-dist/`, and `.vite/` to `.gitignore`.
