import { login, punch } from "./api";
import { getCredentials, updateState } from "./config";

const direction = process.argv[2] as "in" | "out";

if (direction !== "in" && direction !== "out") {
  console.error("Usage: bun run src/punch.ts <in|out>");
  process.exit(1);
}

try {
  const credentials = getCredentials();
  console.log("Logging in...");
  const session = await login(credentials);
  console.log(`Logged in as: ${session.employeeName}`);

  console.log(`Clocking ${direction}...`);
  const result = await punch(session, direction);

  console.log(`Clocked ${direction}! Status: ${result.status}`);
  await updateState({
    lastPunch: { type: direction, timestamp: new Date().toISOString() },
  });
} catch (error) {
  console.error("Error:", (error as Error).message);
  process.exit(1);
}
