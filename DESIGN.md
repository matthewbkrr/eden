# Design

Visual system for **eden**. Source of truth for tokens; the implementation lives
in `assets/css/app.css` (CSS custom properties, `--ed-*`) and is demonstrated at
the dev-only style guide route `/dev/ui`. Strategy: **Restrained** (tinted dark
neutrals + one cobalt accent ≤10% of surface). Three themes: dark (default),
light, and system (`prefers-color-scheme`).

## Theme

Calm, precise, dark-first messenger. Dark theme is a deep cool blue-gray (Telegram
/ Linear lineage), not pure black; light theme is a near-white cool neutral, not
harsh white. Accent is a single cobalt (hue ≈261°, the brand seed). Color is used
only for actions, links, your own messages, and state — never decoration.

Theme switching: `data-theme="light|dark"` on `<html>` (set by the inline manager
in `root.html.heex` via the `phx:set-theme` event); "system" removes the attribute
and falls back to `@media (prefers-color-scheme: dark)`.

## Color (OKLCH)

Tokens are semantic, not literal. Same names in both themes; values differ.

### Dark (default)
| Token | Value | Use |
|---|---|---|
| `--ed-bg` | `oklch(0.18 0.012 261)` | app background |
| `--ed-surface` | `oklch(0.225 0.014 261)` | panels, incoming bubbles |
| `--ed-surface-2` | `oklch(0.27 0.016 261)` | raised/hover surface |
| `--ed-border` | `oklch(0.32 0.014 261)` | hairline borders, dividers |
| `--ed-ink` | `oklch(0.96 0.005 261)` | primary text (≥7:1) |
| `--ed-muted` | `oklch(0.68 0.012 261)` | secondary text (≥4.5:1) |
| `--ed-primary` | `oklch(0.62 0.16 261)` | actions, links, own bubble |
| `--ed-primary-strong` | `oklch(0.68 0.16 261)` | hover/active |
| `--ed-on-primary` | `oklch(0.99 0.01 261)` | text on cobalt fills |
| `--ed-online` | `oklch(0.72 0.15 150)` | presence / success |
| `--ed-danger` | `oklch(0.65 0.19 25)` | destructive / error |
| `--ed-warning` | `oklch(0.78 0.14 75)` | warning |

### Light
| Token | Value |
|---|---|
| `--ed-bg` | `oklch(0.995 0.001 261)` |
| `--ed-surface` | `oklch(0.975 0.003 261)` |
| `--ed-surface-2` | `oklch(0.955 0.004 261)` |
| `--ed-border` | `oklch(0.90 0.006 261)` |
| `--ed-ink` | `oklch(0.24 0.012 261)` |
| `--ed-muted` | `oklch(0.50 0.012 261)` |
| `--ed-primary` | `oklch(0.55 0.16 261)` |
| `--ed-primary-strong` | `oklch(0.50 0.17 261)` |
| `--ed-on-primary` | `oklch(0.99 0.01 261)` |
| `--ed-online` | `oklch(0.62 0.15 150)` |
| `--ed-danger` | `oklch(0.55 0.20 25)` |
| `--ed-warning` | `oklch(0.70 0.14 75)` |

White (near-`--ed-on-primary`) text on every cobalt fill (Helmholtz-Kohlrausch).

## Typography

One family: a system sans stack (`system-ui, -apple-system, "Segoe UI", Roboto,
…`) — zero network cost, native feel, "earned familiarity". Mono stack for
timestamps/code. Fixed rem scale, ratio ≈1.2 (product, not fluid).

| Step | Size / weight | Use |
|---|---|---|
| display | 1.75rem / 700 | rare, screen titles |
| h1 | 1.375rem / 650 | section headers |
| h2 | 1.125rem / 600 | sub-headers |
| body | 0.9375rem / 400 | messages, content |
| label | 0.875rem / 550 | buttons, labels |
| meta | 0.75rem / 500 | timestamps, captions (muted) |

## Radii & spacing

Moderate, not playful. `--ed-radius-sm` 6px (inputs/small), `--ed-radius` 10px
(buttons/cards), `--ed-radius-lg` 16px (message bubbles), `--ed-radius-full`
(avatars, pills, online dot). Spacing on a 4px base; **Comfortable** density
(roomy tap targets, ≥36px controls) per Telegram/Instagram.

## Motion

150–250ms, ease-out. Conveys state only (hover, send, reconnect, reveal). No
page-load choreography, no bounce/elastic. Every transition has a
`prefers-reduced-motion: reduce` fallback (crossfade/instant).

## Components

Each interactive component ships default / hover / focus / disabled (and
loading/error where relevant). Inventory (see `/dev/ui`):

- **Buttons**: primary (cobalt), secondary (surface), ghost, danger, icon.
- **Inputs**: text, search (with icon), message composer (textarea + attach + send).
- **Avatars**: image, initials fallback; sizes; with online dot.
- **Badges/pills**: unread count, presence, label tag.
- **Message bubbles**: incoming (surface), outgoing (cobalt) with timestamp +
  delivery/read ticks; grouped; with photo attachment; system message.
- **Conversation list item**: avatar, name, preview, time, unread, online, selected.
- **Typing indicator**, **empty state**, **toasts** (info/success/error).
