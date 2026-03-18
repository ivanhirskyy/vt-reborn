import cron from "node-cron";
import { login, punch } from "./api";
import { getConfig, getCredentials, updateState } from "./config";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function getJitterMs(maxMinutes: number): number {
  return Math.floor(Math.random() * maxMinutes * 60 * 1000);
}

async function executePunch(
  type: "in" | "out",
  jitterMinutes: number,
): Promise<void> {
  const jitterMs = getJitterMs(jitterMinutes);
  const jitterSecs = Math.round(jitterMs / 1000);
  console.log(
    `[${new Date().toISOString()}] Punch ${type.toUpperCase()} scheduled, waiting ${jitterSecs}s jitter...`,
  );
  await sleep(jitterMs);

  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] Executing punch: ${type.toUpperCase()}`);

  try {
    const credentials = getCredentials();
    const session = await login(credentials);
    const result = await punch(session, type);

    console.log(
      `[${timestamp}] Punch ${type.toUpperCase()} successful (status: ${result.status})`,
    );
    await updateState({ lastPunch: { type, timestamp } });
  } catch (error) {
    console.error(`[${timestamp}] Punch error:`, (error as Error).message);
  }
}

async function main(): Promise<void> {
  const config = await getConfig();

  console.log(`Timezone: ${config.timezone}`);
  console.log("Schedule:");

  const jitter = config.jitter ?? 5;
  console.log(`Jitter: up to ${jitter} min`);

  for (const p of config.punches) {
    const [hour, minute] = p.time.split(":").map(Number);
    const cronExpr = `${minute} ${hour} * * *`;

    console.log(`  ${p.type.toUpperCase().padEnd(3)} at ${p.time}`);

    cron.schedule(
      cronExpr,
      () => {
        executePunch(p.type, jitter);
      },
      {
        timezone: config.timezone,
      },
    );
  }

  console.log("\nRunning. Press Ctrl+C to stop.");

  process.on("SIGTERM", () => {
    console.log("Shutting down...");
    process.exit(0);
  });

  process.on("SIGINT", () => {
    console.log("Shutting down...");
    process.exit(0);
  });
}

main().catch((error) => {
  console.error("Scheduler error:", error);
  process.exit(1);
});
