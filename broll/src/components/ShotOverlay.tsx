// Keycaps and lower thirds of a shot, straight from its timeline entry (screen space, over the camera).

import React from "react";
import { moduleById } from "../assets";
import { BEAT } from "../config";
import { useFilm, useShot } from "../context";
import { keyTaps } from "../timeline";
import { Keycaps, LowerThird } from "./Chrome";

export const ShotOverlay: React.FC<{ captionLeaveEarly?: number }> = ({ captionLeaveEarly = 10 }) => {
  const shot = useShot();
  const { manifest, copy } = useFilm();
  const keys = shot.keys ?? [];
  const caps = shot.captions ?? [];
  const end = shot.beats * BEAT;
  return (
    <>
      {keys.map((k, i) => {
        const sc = moduleById(manifest, k.module).shortcuts[k.shortcut];
        if (!sc) return null;
        const taps = keyTaps(k, sc.keys.length).map((list) => list.map((b) => b * BEAT));
        const nextAt = keys[i + 1]?.at;
        const leave = (k.until ?? (nextAt !== undefined ? nextAt - 0.3 : undefined) ?? shot.beats) * BEAT - (k.until || nextAt !== undefined ? 0 : captionLeaveEarly + 4);
        return <Keycaps key={`${k.module}${k.shortcut}${i}`} keys={sc.keys} appear={k.at * BEAT - 8} taps={taps} leave={leave} />;
      })}
      {caps.map((c, i) => {
        const leave = c.until !== undefined ? c.until * BEAT - 4 : end - captionLeaveEarly - 14;
        return <LowerThird key={`${c.module}${i}`} module={c.module} line={copy.captions[c.copy] ?? ""} appear={c.at * BEAT} leave={leave} />;
      })}
    </>
  );
};
