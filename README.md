# vt-puncher

VisualTime clock in/out automation.

## Setup

```sh
git clone <repo-url> && cd vt-puncher
bun install
cp config.example.json config.json  # edit punch times
cp .env.example .env                # add credentials
```

### `.env`

These can be found by inspecting the /Authenticate request in your browser's developer tools.

```sh
VT_USER=your_vat_number
VT_PASSWORD=your_base64_password # in request payload
VT_COMPANY_ID=your_company_id    # in request headers
```

### `config.json`

```json
{
  "timezone": "Europe/Lisbon",
  "punches": [
    { "time": "07:00", "type": "in" },
    { "time": "12:00", "type": "out" },
    { "time": "13:00", "type": "in" },
    { "time": "16:00", "type": "out" }
  ]
}
```

## Usage

```sh
bun run start             # run scheduler — punches in/out at configured times
bun run in                # manual clock in
bun run out               # manual clock out
bun run backfill 6/3/2026  # retroactively submit a full day for the given date
```

`bun run start` runs in the foreground. Start it in the morning, Ctrl+C at end of day.

`bun run backfill <date>` logs in once and submits all punches from `config.json` against the specified past date using the **SaveRequestForbiddenPunch** API. Accepts `D/M/YYYY` (e.g. `6/3/2026` or `06/03/2026`).
