// 8 · End card: the icon, the name, free and open source, where to get it, the license, and the
// PowerToys credit. Fades to black with the last chord.

import React from "react";
import { AbsoluteFill } from "remotion";
import { REPO_URL, WIDTH } from "../config";
import { useFilm, useLocalFrame, useShot } from "../context";
import { glass } from "../components/Chrome";
import { clamp, ease, ep, mix, px, sp, SPRINGS } from "../motion";
import { FONT_MONO, fontFor } from "../theme";
import { cueFrame } from "../timeline";
import { AppIcon, Reveal, TitleBackdrop } from "./Title";

export const EndCard: React.FC = () => {
  const f = useLocalFrame();
  const shot = useShot();
  const { copy, lang } = useFilm();
  const font = fontFor(lang);
  const end = shot.frames;
  const nameAt = cueFrame(shot, "name");
  const lineAt = cueFrame(shot, "line");
  const urlAt = cueFrame(shot, "url");

  const icon = sp(f, -10, SPRINGS.land);
  const nameT = ep(f, nameAt - 6, nameAt + 24, ease.out);
  const url = sp(f, urlAt, SPRINGS.soft);
  const fine = ep(f, urlAt + 16, urlAt + 46, ease.out);
  const fadeOut = ep(f, end - 44, end - 2, ease.inOut);
  const drift = mix(0, -14, ep(f, 0, end, ease.inOut));
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <AbsoluteFill style={{ opacity: 1 - fadeOut }}>
        <TitleBackdrop glow={0.85} dim={0.26} />
        <div style={{ position: "absolute", inset: 0, transform: `translateY(${px(drift)}px)` }}>
          <div
            style={{
              position: "absolute",
              left: WIDTH / 2,
              top: 330,
              transform: `translate(-50%, -50%) scale(${mix(0.7, 1, icon)})`,
              opacity: clamp(icon * 2.5),
              filter: "drop-shadow(0 30px 60px rgba(10,0,40,0.55))",
            }}
          >
            <AppIcon size={176} />
          </div>
          <div style={{ position: "absolute", left: 0, width: WIDTH, top: 452, textAlign: "center", fontFamily: font, color: "#fff" }}>
            <div
              style={{
                fontSize: 112,
                fontWeight: 700,
                letterSpacing: "-0.045em",
                lineHeight: "130px",
                opacity: nameT,
                filter: `blur(${(1 - nameT) * 8}px)`,
                transform: `translateY(${px((1 - nameT) * 24)}px)`,
              }}
            >
              MacToys
            </div>
            <div style={{ marginTop: 10, fontSize: 40, fontWeight: 520, letterSpacing: "-0.015em", color: "rgba(255,255,255,0.86)" }}>
              <Reveal text={copy.endLine} f={f} at={lineAt} lang={lang} step={lang.startsWith("zh") ? 1.4 : 3} />
            </div>
          </div>
          <div
            style={{
              position: "absolute",
              left: WIDTH / 2,
              top: 720,
              transform: `translate(-50%, -50%) translateY(${px((1 - url) * 22)}px) scale(${mix(0.94, 1, url)})`,
              opacity: clamp(url * 1.6),
              padding: "16px 34px",
              display: "flex",
              alignItems: "center",
              fontFamily: FONT_MONO,
              fontSize: 31,
              fontWeight: 500,
              color: "#fff",
              whiteSpace: "nowrap",
              ...glass("dark", 999),
            }}
          >
            {REPO_URL}
          </div>
          <div
            style={{
              position: "absolute",
              left: 0,
              width: WIDTH,
              top: 900,
              textAlign: "center",
              fontFamily: font,
              color: "rgba(255,255,255,0.62)",
              opacity: fine,
              transform: `translateY(${px((1 - fine) * 10)}px)`,
            }}
          >
            <div style={{ fontSize: 24, fontWeight: 600, color: "rgba(255,255,255,0.8)", letterSpacing: "-0.005em" }}>{copy.license}</div>
            <div style={{ marginTop: 10, fontSize: 19, fontWeight: 450 }}>{copy.inspired}</div>
          </div>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
