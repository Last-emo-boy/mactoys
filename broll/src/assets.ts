// The app's exported UI (public/assets/app/<lang>/, written by `MacToys --export-assets`).
// Pure TypeScript: used by the compositions (through fetch) and by the node scripts (through fs).

export interface Shortcut {
  title: string;
  keys: string[];
}
export interface SceneInfo {
  name: string;
  width: number;
  height: number;
}
export interface ModuleInfo {
  id: string;
  name: string;
  summary: string;
  symbol: string;
  tint: string;
  category: string;
  categoryTitle: string;
  shortcuts: Shortcut[];
  scenes: SceneInfo[];
}
export interface SidebarEntry {
  kind: "item" | "header";
  id?: string;
  title: string;
  symbol?: string;
  tint?: string;
}
export interface Manifest {
  language: string;
  languageName: string;
  languages: string[];
  categories: { id: string; title: string }[];
  sidebar: SidebarEntry[];
  strings: Record<string, string>;
  modules: ModuleInfo[];
}

/** What exists on disk, resolved once per render and handed to the film as props. */
export interface AssetIndex {
  /** UI languages present, `en` first, then in the manifest's order. Never `eo`. */
  langs: string[];
  manifests: Record<string, Manifest>;
  /** `<lang>/<rel>` keys of the files that exist for languages other than `en`. */
  present: Record<string, true>;
}

export const APP_DIR = "assets/app";
export const APP_ICON = `${APP_DIR}/appicon.png`;

/** Files of one language the film reads (all relative to `<lang>/`). */
export function filesFor(m: Manifest, scenes: string[]): string[] {
  const out = new Set<string>();
  out.add("icons/app.png");
  for (const mod of m.modules) out.add(`icons/${mod.id}.png`);
  for (const e of m.sidebar) if (e.kind === "item" && e.id) out.add(`pages/${e.id}.png`);
  for (const s of scenes) out.add(s);
  out.add("ui/quickaccess.png");
  return [...out];
}

export interface AssetIO {
  exists(rel: string): Promise<boolean>;
  json(rel: string): Promise<unknown>;
}

/**
 * Discovers the exported languages and which of their files exist. `en` is required; every other
 * language listed in the `en` manifest is used when its manifest is present (per-file fallback to `en`).
 */
export async function resolveAssets(io: AssetIO, scenes: string[]): Promise<AssetIndex> {
  const en = (await io.json(`${APP_DIR}/en/manifest.json`)) as Manifest;
  const manifests: Record<string, Manifest> = { en };
  const langs = ["en"];
  const present: Record<string, true> = {};
  const candidates = (en.languages ?? []).filter((l) => l !== "en" && l !== "eo");
  await Promise.all(
    candidates.map(async (lang) => {
      if (!(await io.exists(`${APP_DIR}/${lang}/manifest.json`))) return;
      manifests[lang] = (await io.json(`${APP_DIR}/${lang}/manifest.json`)) as Manifest;
      const files = filesFor(en, scenes);
      const hits = await Promise.all(files.map((f) => io.exists(`${APP_DIR}/${lang}/${f}`)));
      files.forEach((f, i) => {
        if (hits[i]) present[`${lang}/${f}`] = true;
      });
    }),
  );
  for (const l of candidates) if (manifests[l]) langs.push(l);
  return { langs, manifests, present };
}

/** Path (relative to public/) of a UI file in `lang`, falling back to `en` when that language lacks it. */
export function appFile(index: AssetIndex, lang: string, rel: string): string {
  if (lang !== "en" && index.present[`${lang}/${rel}`]) return `${APP_DIR}/${lang}/${rel}`;
  return `${APP_DIR}/en/${rel}`;
}

/** The manifest for `lang` (falls back to `en`), with modules indexed by id. */
export function manifestFor(index: AssetIndex, lang: string): Manifest {
  return index.manifests[lang] ?? index.manifests.en;
}

export function moduleById(m: Manifest, id: string): ModuleInfo {
  const found = m.modules.find((x) => x.id === id);
  if (!found) throw new Error(`module ${id} missing from the ${m.language} manifest`);
  return found;
}
