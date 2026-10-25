// SF Pro / PingFang come from the system on a Mac (where the film is rendered). On other machines
// Inter and Noto Sans SC are loaded from Google Fonts as fallbacks; on a Mac nothing is fetched.

import { loadFont as loadInter } from "@remotion/google-fonts/Inter";
import { loadFont as loadNotoSC } from "@remotion/google-fonts/NotoSansSC";

const isMac = typeof navigator !== "undefined" && /Mac/.test(navigator.platform || navigator.userAgent);
let loaded = false;

export function useFonts(lang: string): void {
  if (loaded || isMac) return;
  loaded = true;
  loadInter("normal", { weights: ["400", "500", "600", "700"], subsets: ["latin"] });
  if (lang.startsWith("zh")) loadNotoSC("normal", { weights: ["400", "500", "700"] });
}
