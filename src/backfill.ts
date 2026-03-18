import { login, getMyPunches, saveForbiddenPunch } from "./api";
import { getConfig, getCredentials } from "./config";

const dateArg = process.argv[2];

if (!dateArg) {
  console.error("Usage: bun run backfill <date>");
  console.error("  date format: D/M/YYYY (e.g. 6/3/2026 or 06/03/2026)");
  process.exit(1);
}

function parseDate(input: string): { iso: string; dmy: string } {
  const match = input.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!match) {
    throw new Error(
      `Unrecognized date format: "${input}". Use D/M/YYYY (e.g. 6/3/2026 or 06/03/2026).`,
    );
  }
  const [, d, m, y] = match as [string, string, string, string];
  const dd = d.padStart(2, "0");
  const mm = m.padStart(2, "0");
  return { iso: `${y}-${mm}-${dd}`, dmy: `${dd}/${mm}/${y}` };
}

try {
  const { iso: dateStr, dmy: apiDate } = parseDate(dateArg);
  const config = await getConfig();
  const credentials = getCredentials();

  console.log(`Backfilling punches for ${dateStr}...`);
  console.log("Logging in...");
  const session = await login(credentials);
  console.log(`Logged in as: ${session.employeeName}`);

  // Check what's already registered for this date
  const existing = await getMyPunches(session, apiDate);

  if (existing.length > 0) {
    console.log(
      `Found ${existing.length} existing punch(es) — skipping first ${existing.length} config entry(ies).`,
    );
  }

  const remaining = config.punches.slice(existing.length);

  if (remaining.length === 0) {
    console.log("All punches already submitted. Nothing to do.");
    process.exit(0);
  }

  console.log(`Submitting ${remaining.length} missing punch(es)...`);

  const DELAY_MS = 5000;

  for (let i = 0; i < remaining.length; i++) {
    const p = remaining[i]!;
    const punchDateTime = `${dateStr} ${p.time}`;
    if (i > 0) {
      process.stdout.write(`  waiting ${DELAY_MS / 1000}s... `);
      await new Promise((resolve) => setTimeout(resolve, DELAY_MS));
    }
    process.stdout.write(`  [${p.type.toUpperCase()}] ${punchDateTime} ... `);
    const { requestId } = await saveForbiddenPunch(
      session,
      punchDateTime,
      p.type,
    );
    console.log(`OK (requestId: ${requestId})`);
  }

  console.log(`\nDone! All punches submitted for ${dateStr}.`);
} catch (error) {
  console.error("Error:", (error as Error).message);
  process.exit(1);
}
