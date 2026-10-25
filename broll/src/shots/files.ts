// Every scene image the film reads (relative to public/assets/app/<lang>/). No React here: the node
// scripts import it too.

import { SCENES } from "../scenes";
import { SHOTS } from "../timeline";

export const SCENE_FILES: string[] = [...new Set([...SHOTS.flatMap((s) => s.assets ?? []), ...Object.values(SCENES).map((g) => g.file)])];
