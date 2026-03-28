# HamingwaysDPSmate

A lightweight DPS meter addon for **World of Warcraft 1.12** (Vanilla / Turtle WoW), built around detailed combat tracking and a clean, themed UI.

![HamingwaysDPSmate Screenshot](images/Hamingway.tga)

---

## Features

- **Real-time DPS tracking** — tracks overall and per-spell DPS during combat
- **Spell breakdown** — min / max / average damage, crit vs. non-crit counts per spell
- **Boss history** — separate history for boss encounters
- **General history** — tracks all other combat segments
- **Class-coloured bars** — player bars are colour-coded by class, with persistence across sessions
- **Detail window** — click any bar to open a per-player spell breakdown
- **DPS reporting** — report your DPS to Say, Guild, or Whisper via the right-click menu
- **Settings panel** — in-game adjustable options (About + Display tabs)
  - Bar opacity
  - Background opacity
  - Row height
  - Font face (WoW Default / Arial Narrow / Skurri) and font size
- **Portrait + themed About panel** — a wee taste of Scottish flair

---

## Requirements

| Requirement | Details |
|---|---|
| WoW version | 1.12.x (Vanilla) or Turtle WoW |
| Interface | 11200 |

No external libraries are required.

---

## Installation

1. Download or clone this repository.
2. Copy the `HamingwaysDPSmate` folder into your WoW AddOns directory:
   ```
   World of Warcraft\Interface\AddOns\HamingwaysDPSmate\
   ```
3. Launch WoW and enable **HamingwaysDPSmate** in the AddOn list.

---

## Usage

| Action | Result |
|---|---|
| `/hdps` | Toggle the DPS meter window |
| `/hdps reset` | Reset current session data |
| `/hdps report say` | Report DPS to /say |
| `/hdps report guild` | Report DPS to /guild |
| Right-click any bar | Open context menu (report / whisper / settings) |
| Left-click any bar | Open spell detail window for that player |
| Drag title bar | Move the window |

### Settings

Open the settings panel via the right-click context menu on any bar and choose **Settings**, or type `/hdps config`.

---

## SavedVariables

Saved per-character as `HamingwaysDPSmateDB`. Contains:

- `bossHistory` — boss encounter records
- `generalHistory` — general combat records
- `classes` — cached class colours per player name
- `settings` — display preferences

---

## Version History

See [CHANGELOG](CHANGELOG.md) if present.

| Version | Notes |
|---|---|
| 0.0.4 | Settings panel (About + Display tabs), class colour persistence, detail window, DPS reporting |
| 0.0.1 | Initial release |

---

## Author

**Hamingway** — Turtle WoW player and addon tinkerer.

> *"Great tae meet ya!"*
