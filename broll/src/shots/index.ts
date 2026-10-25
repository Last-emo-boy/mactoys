import type React from "react";
import type { ShotId } from "../timeline";
import { AdvancedPaste } from "./AdvancedPaste";
import { Awake } from "./Awake";
import { CmdPal } from "./CmdPal";
import { ColdOpen } from "./ColdOpen";
import { ColorPicker } from "./ColorPicker";
import { EndCard } from "./EndCard";
import { FancyZones } from "./FancyZones";
import { KeyboardManager } from "./KeyboardManager";
import { Languages } from "./Languages";
import { MouseUtils } from "./MouseUtils";
import { Peek } from "./Peek";
import { PowerRename } from "./PowerRename";
import { Settings } from "./Settings";
import { Terminal } from "./Terminal";
import { TextExtractor } from "./TextExtractor";
import { Title } from "./Title";
import { Wall } from "./Wall";
import { Workspaces } from "./Workspaces";
import { ZoomIt } from "./ZoomIt";

export const SHOT_COMPONENTS: Record<ShotId, React.FC> = {
  cold: ColdOpen,
  title: Title,
  wall: Wall,
  cmdpal: CmdPal,
  fancyzones: FancyZones,
  colorpicker: ColorPicker,
  textextractor: TextExtractor,
  zoomit: ZoomIt,
  advancedpaste: AdvancedPaste,
  powerrename: PowerRename,
  keyboardmanager: KeyboardManager,
  mouseutils: MouseUtils,
  peek: Peek,
  awake: Awake,
  workspaces: Workspaces,
  settings: Settings,
  languages: Languages,
  terminal: Terminal,
  end: EndCard,
};

export { SCENE_FILES } from "./files";
