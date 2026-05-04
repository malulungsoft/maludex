import { describe, expect, test } from "vitest";

import { pairingUriFor } from "../src/pairing-uri.js";

describe("pairingUriFor", () => {
  test("encodes local WebSocket pairing by default", () => {
    const uri = pairingUriFor({
      host: "100.75.40.51",
      port: 8765,
      token: "secret capability",
      name: "Studio Mac",
      tls: false
    });

    expect(uri).toBe(
      "maludex://pair?host=100.75.40.51&port=8765&token=secret+capability&tls=0&name=Studio+Mac"
    );
  });

  test("encodes TLS pairing for an Nginx endpoint", () => {
    const uri = pairingUriFor({
      host: "maludex.example.com",
      port: 443,
      token: "secret capability",
      name: "Studio Mac",
      tls: true
    });

    expect(uri).toBe(
      "maludex://pair?host=maludex.example.com&port=443&token=secret+capability&tls=1&name=Studio+Mac"
    );
  });
});
