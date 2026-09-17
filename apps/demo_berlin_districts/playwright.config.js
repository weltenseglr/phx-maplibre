const { defineConfig, devices } = require("@playwright/test")

const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4001"

// Headless ANGLE must not try the container's forwarded X display.
if (process.argv.includes("--headed") || process.env.PWDEBUG) process.env.BERLIN_PLAYWRIGHT_HEADED = "1"
const browserEnv = {...process.env}
if (process.env.BERLIN_PLAYWRIGHT_HEADED !== "1") delete browserEnv.DISPLAY

module.exports = defineConfig({
  baseURL,
  testDir: "./tests",
  timeout: 30_000,
  retries: 0,
  reporter: "html",
  use: {
    trace: "on-first-retry",
    launchOptions: {env: browserEnv, args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]},
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        channel: "chromium",
      },
    },
  ],
})
