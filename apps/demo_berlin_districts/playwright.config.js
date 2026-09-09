const { defineConfig, devices } = require("@playwright/test")

const baseURL = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4001"

module.exports = defineConfig({
  baseURL,
  testDir: "./tests",
  timeout: 30_000,
  retries: 0,
  reporter: "html",
  use: {
    trace: "on-first-retry",
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
