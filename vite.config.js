import { defineConfig } from "vite";
import fs from "node:fs";

const skredVersion = fs.readFileSync(new URL("./SKRED_VERSION", import.meta.url), "utf-8").trim();

export default defineConfig({
  base: "./",
  define: {
    __SKRED_VERSION__: JSON.stringify(skredVersion)
  },
  plugins: [
    {
      name: "html-skred-version",
      transformIndexHtml(html) {
        return html.replaceAll("__SKRED_VERSION__", skredVersion);
      }
    }
  ],
  server: {
    host: "0.0.0.0",
    port: 3000,
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp"
    }
  },
  preview: {
    host: "0.0.0.0",
    port: 3000,
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp"
    }
  }
});
