// Every line of film copy, per film language. Utility names come from the manifest; these lines are
// shortened from the manifest summaries (the source of truth) and say only what the utility does.
// Rules: English ≤ 8 words, Chinese ≤ 16 characters.

import type { FilmLang } from "./config";

export interface Copy {
  tagline: string;
  count: string; // "{n}" is replaced by the module count from the manifest
  countUnit: string;
  captions: Record<string, string>;
  settings: string;
  languages: string;
  terminal: string;
  endLine: string;
  license: string;
  inspired: string;
  /** Menu bar clock, matching the exported scenes (Sat 24 Oct 2026, 22:41). */
  clock: string;
  menus: string[];
}

export const COPY: Record<FilmLang, Copy> = {
  en: {
    tagline: "PowerToys, reimagined for the Mac.",
    count: "{n}",
    countUnit: "utilities · one menu bar",
    captions: {
      cmdpal: "Apps, files, commands. One box.",
      fancyzones: "Snap windows into your own layouts.",
      colorpicker: "Pick any color on screen.",
      textextractor: "Copy text from anywhere on screen.",
      zoomit: "Zoom, draw and present.",
      advancedpaste: "Paste as plain text, Markdown or JSON.",
      powerrename: "Bulk rename with regular expressions.",
      keyboardmanager: "Remap keys and shortcuts.",
      mouseutils: "Find your pointer. Jump across displays.",
      peek: "Preview files without opening an app.",
      finderaddons: "Quick Look for STL, G-code and more.",
      awake: "Keep your Mac awake on demand.",
      powerdisplay: "Brightness and volume for every display.",
      workspaces: "Launch apps into saved window positions.",
    },
    settings: "Every setting, one window.",
    languages: "Speaks your language.",
    terminal: "Scriptable from the command line.",
    endLine: "Free and open source · macOS 26",
    license: "MIT License",
    inspired: "Inspired by Microsoft PowerToys. Not affiliated with Microsoft.",
    clock: "Sat 24 Oct  22:41",
    menus: ["Finder", "File", "Edit", "View", "Go", "Window", "Help"],
  },
  "zh-Hans": {
    tagline: "为 Mac 重新打造的 PowerToys。",
    count: "{n}",
    countUnit: "款工具 · 一个菜单栏",
    captions: {
      cmdpal: "应用、文件、命令，一框搜尽。",
      fancyzones: "把窗口吸附进自定义布局。",
      colorpicker: "拾取屏幕上的任意颜色。",
      textextractor: "从屏幕任意位置复制文字。",
      zoomit: "放大、标注、演示。",
      advancedpaste: "粘贴为纯文本、Markdown 或 JSON。",
      powerrename: "用正则表达式批量重命名。",
      keyboardmanager: "重新映射按键与快捷键。",
      mouseutils: "找到指针，跨屏跳转。",
      peek: "无需打开应用即可预览文件。",
      finderaddons: "快速查看 STL、G-code 等文件。",
      awake: "按需让 Mac 保持唤醒。",
      powerdisplay: "调节每台显示器的亮度与音量。",
      workspaces: "一键把应用开到保存的位置。",
    },
    settings: "所有设置，尽在一处。",
    languages: "说你的语言。",
    terminal: "命令行里同样可用。",
    endLine: "免费开源 · macOS 26",
    license: "MIT 许可证",
    inspired: "灵感源自 Microsoft PowerToys，与微软公司无关联。",
    clock: "10月24日 周六  22:41",
    menus: ["访达", "文件", "编辑", "显示", "前往", "窗口", "帮助"],
  },
};

/** Visible length rule for captions: words in English, characters (Latin words count as 1) in Chinese. */
export function captionLength(lang: FilmLang, text: string): number {
  if (lang === "en") return text.split(/\s+/).filter(Boolean).length;
  return [...text.replace(/[A-Za-z0-9-]+/g, "x").replace(/\s+/g, "")].length;
}
