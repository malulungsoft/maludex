declare module "*.mjs" {
  export function extractReleaseNotes(markdown: string, version: string): string;
}
