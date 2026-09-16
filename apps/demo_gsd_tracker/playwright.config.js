// @ts-check
const { defineConfig, devices } = require('@playwright/test');

const port = process.env.GSD_PORT || '4002';
const baseURL = `http://127.0.0.1:${port}`;
// Config is also loaded in workers, whose argv does not contain CLI flags.
// Propagate the headed choice so worker launches keep the requested display.
if (process.argv.includes('--headed') || process.env.PWDEBUG) {
  process.env.GSD_PLAYWRIGHT_HEADED = '1';
}
const browserEnv = { ...process.env };
// ANGLE may try the forwarded X display even in headless mode. The container
// cannot authenticate to that display; headless rendering needs no X server.
if (process.env.GSD_PLAYWRIGHT_HEADED !== '1') {
  delete browserEnv.DISPLAY;
}

module.exports = defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: 'line',
  use: {
    baseURL,
    trace: 'on-first-retry',
    launchOptions: { args: ['--enable-unsafe-swiftshader'], env: browserEnv },
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: {
    command: 'MIX_ENV=dev mix phx.server',
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    cwd: '../..',
  },
});
