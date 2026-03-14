# Design System Rules

## Notion reference
- **Permission & Security Model** (design system section): `323c6ebc177f81b8a55afa5378182fa3`

## Purpose
The design system is the contract between OpenClaw's UI generator and the Flutter renderer. Without it, LLM-generated UIs produce inconsistent results.

## Tech stack
- **Token format**: YAML (`design-system/tokens.yaml`)
- **Component definitions**: YAML (`design-system/components.yaml`)
- **Icons**: ~60 Material Symbols, SVG format
- **Tooling**: Python CLI tools

## Files
```
design-system/
├── tokens.yaml        # Color, typography, spacing tokens
├── components.yaml    # 13 UI component primitives
├── icons/             # SVG icon set
└── tools/             # design-lint, design-preview, design-export
```

## Component library (exhaustive list)
The UI generator can ONLY compose from these primitives:
TextBlock, Card, ListItem, Badge, ActionButton, MapView, ImageView,
ChartView, Timeline, CodeBlock, ConfirmPrompt, PaginatedText, CaptionStream

Do NOT add new component types without updating both `components.yaml` and the Flutter `UIRenderer`.

## Dark UI elevation system

Cervos uses a **dark-first UI**. Elevation is expressed through surface lightness, NOT shadows.
Shadows are ineffective on dark backgrounds — instead, higher elevation = lighter surface color.

### Core principles
1. **No pure black** — never use `#000000` as a base. It creates harsh contrast and eye strain. Use an "eerie black" like `#1E1F22` (HSL 225, 5, 15).
2. **Elevation = lightness** — each step up lightens the base by 4-5%. Higher surfaces appear "closer" to the user, like objects illuminated in a dimly lit room.
3. **No shadows for depth** — in dark mode, use surface color differences to create visual hierarchy instead of drop shadows.
4. **Hue tinting** — elevation colors can carry a subtle hue shift to align with the brand. Keep it subtle so it doesn't overwhelm.

### Elevation levels (5 levels, 0dp–8dp)

| Level | dp | Color | Lightness shift | Use case |
|-------|-----|---------|----------------|----------|
| 0 (Base) | 0dp | `#1E1F22` | — | Primary background, large non-interactive surfaces |
| 1 | 1dp | `#252629` | +4% | Buttons, cards, small elevated containers |
| 2 | 3dp | `#2C2D32` | +6% | Elevated cards, secondary containers |
| 3 | 6dp | `#323438` | +8% | Modals, dialogs, primary interactive elements |
| 4 | 8dp | `#393C41` | +10% | Hover states, focus indicators, highly interactive elements |

### Component-to-elevation mapping (mobile app + console)

| Component | Elevation level |
|-----------|----------------|
| App background, scaffold | Level 0 |
| Card, ListItem, Timeline entries | Level 1 |
| ActionButton, Badge, elevated Card | Level 2 |
| ConfirmPrompt, modal dialogs, bottom sheets | Level 3 |
| Hover/focus states, active interactive elements | Level 4 |
| Navigation bar, app bar | Level 1 |
| Action journal entries | Level 1 |
| Console dashboard panels | Level 1–2 |
| Console modals (kill switch, request replay) | Level 3 |

### Accent & primary colors on dark surfaces
- Primary and accent colors must contrast well against all elevation levels
- Vibrant accents (muted blue, amber) stand out best against dark elevated surfaces
- Model badge colors (green/amber/blue) are designed to pop on Level 0–2 backgrounds
- Test all accent colors at every elevation level for WCAG AA contrast (4.5:1 minimum for text)

### Applying to Cervos surfaces

**Mobile app (Flutter):**
- Use `ThemeData.dark()` with custom `ColorScheme` based on the elevation palette
- `Card` widget: Level 1 surface by default, Level 2 when elevated
- `Dialog` / `BottomSheet`: Level 3 surface
- `AppBar` / `NavigationBar`: Level 1 surface
- Hover/pressed states: shift to Level 4

**Console (web app):**
- CSS custom properties for each elevation level
- Panel backgrounds: Level 1
- Modal overlays: Level 3
- Interactive controls hover: Level 4

## Color tokens
- Model badges: green `#34A853` (on-device), amber `#F9AB00` (local), blue `#4285F4` (cloud)
- Permission tiers: green (always), amber (confirm), red (unlock)
- Standard: primary, secondary, surface, accent, warning, error
- Elevation surfaces: Level 0–4 as defined above

## Typography
- Font: Inter
- Scale: h1, h2, h3, body, caption, badge, glasses_mono
- Glasses use monospace at ~15 chars wide
- Text on dark surfaces: use `#E0E0E0` for body text (not pure white `#FFFFFF` — reduces glare)

## Spacing
- Scale: 4, 8, 12, 16, 24, 32, 48 dp

## Conventions
- Every UI template must validate against `design-lint` before merge
- New components require: YAML definition + Flutter widget + design-lint rule
- Template scores tracked in SQLite — feedback loop updates them
- Glasses display always goes through text-downgrade formatter
- **Dark mode is the only mode** — there is no light theme for mobile or console
- Never use shadows for elevation in dark UI — only surface color lightness
- Always verify accent color contrast against the elevation level it sits on
