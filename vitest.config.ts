import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["bridge/test/**/*.test.ts"],
    testTimeout: 15000
  }
});
