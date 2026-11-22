---
version: "alpha"
name: "FortiBar"
description: "Quiet macOS product page: system type, white or black canvas, light-gray 22px cards, one cobalt accent from the app icon, dark stages for product UI."
colors:
  light:
    bg: "#ffffff"
    surface: "#f5f5f7"
    fg: "#1d1d1f"
    body: "#424245"
    muted: "#6e6e73"
    border: "#d2d2d7"
    hairline: "rgba(0,0,0,0.08)"
    accent: "#1a62d6"
    accent-hover: "#1552b5"
    on-accent: "#ffffff"
    link: "#1a62d6"
    green: "#248a3d"
    secondary: "rgba(0,0,0,0.05)"
    stage: "#0c0e12"
  dark:
    bg: "#000000"
    surface: "#161617"
    fg: "#f5f5f7"
    body: "#a1a1a6"
    muted: "#86868b"
    border: "#424245"
    hairline: "rgba(255,255,255,0.10)"
    accent: "#1a62d6"
    accent-hover: "#2a72e6"
    on-accent: "#ffffff"
    link: "#4a9eff"
    green: "#30d158"
    secondary: "rgba(255,255,255,0.08)"
    stage: "#0c0e12"
typography:
  display:
    fontFamily: "-apple-system (SF Pro Display), Inter fallback"
    fontSize: "clamp(48px, 9vw, 88px)"
    fontWeight: 700
    lineHeight: 1.04
    letterSpacing: -0.04em
  headline:
    fontFamily: "-apple-system (SF Pro Display), Inter fallback"
    fontSize: "clamp(32px, 5vw, 48px)"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: -0.03em
  lede:
    fontFamily: "-apple-system (SF Pro Text), Inter fallback"
    fontSize: "clamp(21px, 2.6vw, 26px)"
    fontWeight: 400
    lineHeight: 1.38
    letterSpacing: -0.02em
  title:
    fontSize: 19px
    fontWeight: 600
    letterSpacing: -0.02em
  body:
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.53
    letterSpacing: -0.012em
  small:
    fontSize: 15px
    lineHeight: 1.5
  caption:
    fontSize: 13px
  mono:
    fontFamily: "ui-monospace, SF Mono, Menlo"
    fontSize: 13.5px
rounded:
  sm: 8px
  md: 14px
  lg: 22px
  xl: 28px
  pill: 980px
spacing:
  unit: 4px
  scale: [4, 8, 12, 16, 24, 32, 48, 64]
  section: 120px (88px under 760px)
  max-width: 1080px
  gutter: 24px (20px under 760px, 16px under 400px)
---

# FortiBar

> A native Mac utility presented the way Apple presents its own apps: one big icon, one big name, short sentences, lots of air.

Tokens live as CSS custom properties at the top of `docs/css/style.css`; keep the two in sync.

## Overview

FortiBar is a small menu bar VPN client, so the page is small too: hero, demo,
six features, screenshots, install, footer. The canvas is plain white (black in
dark mode); the only colour is the cobalt of the app icon, used for the primary
button, links and feature icons. Product UI (the panel GIF, the Settings
screenshots, all captured in dark appearance) always sits on a near-black
`stage` panel in both schemes, so the app looks the same as on a Mac with a dark
menu bar and the page never shows mismatched backgrounds.

The app follows the same language: system materials (Liquid Glass on macOS 26),
SF Symbols, the system accent, and a monochrome template shield in the menu bar
that adapts to the menu bar appearance and shows the number of connected
tunnels. Green means connected, orange means attention (no password,
reconnecting), red means error. No custom colours beyond that.

## Colors

- Scheme follows `prefers-color-scheme`; there is no toggle.
- Text contrast (WCAG): `body` on `bg` 10:1 light / 8:1 dark; `muted` on `bg` 5.1:1 / 5.8:1 and on `surface` 4.7:1 / 5.0:1; white on `accent` 5.6:1; `link` 5.1:1+ light, 6.6:1+ dark.
- `muted` is for captions and notes only (13–15px). Body copy uses `body`, headings `fg`.
- `accent` fills only the primary button. Everything else that is blue is `link` (the lighter `#4a9eff` in dark mode).
- `green` appears only as a state (the "Copied" check), never as decoration.
- One soft radial `glow` (accent at 10–12%) behind the hero; no other gradients.

## Typography

- System font first (`-apple-system` = SF Pro on Apple devices); Inter from Google Fonts is the fallback elsewhere. No other web fonts. Mono is `ui-monospace` (SF Mono).
- Headlines: weight 700, negative tracking, sentence case, short, end with a period ("Install in a minute."). `text-wrap: balance` on headings, `pretty` on paragraphs.
- Scale: 13 / 14 / 15 / 17 / 19 / 24 / 32–48 / 48–88.
- Never uppercase or letter-space labels.

## Layout

- Single centred column, max 1080px. Section heads are centred, max 720px wide.
- Section rhythm 120px (88px on phones); hero 96px top padding.
- Features: 3 columns → 2 under 900px → 1 under 560px. Install: 2 columns → 1 under 760px.
- Screenshots: 3 columns on desktop; under 760px a scroll-snapping row inside the stage (the page itself never scrolls sideways; checked at 360px).
- Hero buttons stack full width under 560px.

## Elevation & Depth

- Flat. Cards are `surface` fills with no border and no shadow.
- Hairlines (`hairline`) separate the sticky nav, footer and code blocks.
- The nav is translucent (`backdrop-filter: saturate(180%) blur(20px)`), like macOS toolbars.
- The only shadow is an accent-tinted `drop-shadow` under the hero app icon. Screenshots bring their own window shadows.

## Shapes

- 22px cards and panels, 28px stages, 14px code blocks and the GIF, 8px copy buttons, pill buttons.
- Icons: 24px grid, 1.75px stroke, round caps and joins, `currentColor`, drawn in the style of SF Symbols.

## Components

- Primary button: pill, 48px tall, `accent` fill, white 17px/500 text, optional 20px stroke icon.
- Secondary button: same shape, `secondary` translucent fill, `fg` text.
- Feature card: icon (32px, `link`), title 19px/600, body 15px.
- Code block: `bg`-coloured box with hairline border, mono 13.5px, a 32px icon-only copy button that turns into a green check; long commands scroll inside the block.
- Steps: 24px numbered discs (`fg` fill, `bg` text).
- Footer: 13px `muted` credits (GPL-3.0, OpenFortiMac by rempairamore, openfortivpn by Adrien Vergé, not affiliated with Fortinet), underlined links, year filled in by `main.js`.

## Do's and Don'ts

- Do keep one accent colour and let the product screenshots carry the visual interest.
- Do put app UI on the dark stage, whatever the page scheme.
- Do keep copy short and factual; claims must match the app (check the README).
- Don't add frameworks, external scripts, trackers or animation libraries. `main.js` only fills the year and handles copy buttons.
- Don't add borders or shadows to cards, gradients to buttons, or glow effects.
- Don't use Fortinet branding or colours; FortiBar is not affiliated with Fortinet.

## Motion

- 160ms `cubic-bezier(.25,.1,.25,1)` for button and link colour; buttons scale to 0.98 when pressed.
- Smooth anchor scrolling only without `prefers-reduced-motion`; reduced motion disables all transitions.
- The demo GIF is the only moving element.
