---
name: solidjs
description: SolidJS frontend development conventions and patterns, plus SolidJS + Vite PWA project scaffolding. Use when creating or editing SolidJS components, CSS modules, layouts, or styling, or when scaffolding a new SolidJS PWA project. Covers component decomposition, CSS module requirements, layout preferences (CSS Grid then Flexbox), CSS custom property usage for design tokens and runtime values, Vite CSS module class name configuration, and PWA scaffold pitfalls (package names, tsconfig conflicts, asset generation).
---

# SolidJS Frontend Conventions

## Components
- Decompose UI into small, focused SolidJS components liberally. Prefer one component per file.
- Co-locate a component's CSS module alongside it: `ComponentName.tsx` + `ComponentName.module.css`.

## CSS Modules
- Every component that has styles **must** use a CSS module (`*.module.css`). No inline `style` attributes unless there is a strong, documented justification (e.g., a value that is only known at runtime and cannot be expressed via a CSS custom property).
- In JS, toggle visual states by switching CSS classes (e.g., via `classList`), never by building `style` strings.
- When a runtime value must influence styling and it can be expressed as a quantity (width, color, offset…), set it as a CSS custom property on the element and reference it in the module CSS:
  ```tsx
  <div style={{ '--offset': `${x}px` }} class={styles.container} />
  ```
  ```css
  .container { transform: translateX(var(--offset)); }
  ```

## Layout
- Prefer **CSS Grid** for two-dimensional or page-level layouts.
- Prefer **Flexbox** for one-dimensional alignment within a component.
- Avoid `position: absolute/fixed` unless there is no layout-flow alternative.

## CSS Custom Properties (variables)
- Define **global design tokens** in `app/src/index.css` (or a dedicated `tokens.css` imported there) for values shared across components: border colors, border widths, spacing scale, font sizes, z-index layers, transition durations, brand colors, etc.
- In a component's CSS module, define **local defaults** for any custom properties the component exposes to parents for overriding:
  ```css
  /* Button.module.css */
  .root {
    --btn-bg: var(--color-primary);   /* parent can override --btn-bg */
    background: var(--btn-bg);
  }
  ```
- Never hard-code a value that is already expressed as a global token.

## Dev-Friendly Class Names
Configure Vite to generate readable CSS module class names in development (`[name]__[local]`) and short hashed names in production. Do not change this behavior once set.

## PWA Scaffold
When scaffolding a SolidJS + Vite + PWA project, read [references/pwa-scaffold.md](references/pwa-scaffold.md) first — it documents package-name pitfalls, tsconfig conflicts, and asset-generator output naming that are easy to get wrong.
