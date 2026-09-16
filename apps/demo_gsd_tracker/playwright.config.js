// @ts-check
const { defineConfig, devices } = require('@playwright/test');

const port = process.env.GSD_PORT || '4002';
const baseURL = `http://127.0.0.1:${port}`;

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
    launchOptions: { args: ['--enable-unsafe-swiftshader'] },
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
