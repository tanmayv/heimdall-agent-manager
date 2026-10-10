/** Active reconfiguration already relaunches on the Hub; stopped PATCH only saves. */
export async function applyRuntimeConfiguration(
  stopped: boolean,
  reconfigure: () => Promise<unknown>,
  start: () => Promise<unknown>,
): Promise<void> {
  await reconfigure();
  if (stopped) await start();
}
