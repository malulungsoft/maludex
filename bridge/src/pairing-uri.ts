export type PairingUriOptions = {
  host: string;
  port: number;
  token: string;
  name: string;
  tls: boolean;
};

export function pairingUriFor(options: PairingUriOptions): string {
  const query = new URLSearchParams({
    host: options.host,
    port: String(options.port),
    token: options.token,
    tls: options.tls ? "1" : "0",
    name: options.name
  });
  return `maludex://pair?${query.toString()}`;
}
