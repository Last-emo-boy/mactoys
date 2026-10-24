import AdvancedPaste
import AlwaysOnTop
import Awake
import ColorPicker
import CommandNotFound
import CommandPalette
import CropAndLock
import EnvironmentVariables
import FancyZones
import FinderAddons
import FileLocksmith
import GrabAndMove
import HostsEditor
import ImageResizer
import KeyboardManager
import LightSwitch
import MouseUtilities
import MouseWithoutBorders
import NewPlus
import Peek
import PowerDisplay
import PowerRename
import QuickAccent
import PlistPreview
import ScreenRuler
import ShortcutGuide
import TextExtractor
import WindowHopper
import Workspaces
import ZoomIt
import MacToysCore

@MainActor
enum AllModules {
    /// Every utility, in no particular order (Settings sorts by category and name).
    static func make() -> [any ToyModule] {
        [
        AdvancedPasteModule(),
        AlwaysOnTopModule(),
        AwakeModule(),
        ColorPickerModule(),
        CommandNotFoundModule(),
        CommandPaletteModule(),
        CropAndLockModule(),
        EnvironmentVariablesModule(),
        FancyZonesModule(),
        FinderAddonsModule(),
        FileLocksmithModule(),
        GrabAndMoveModule(),
        HostsEditorModule(),
        ImageResizerModule(),
        KeyboardManagerModule(),
        LightSwitchModule(),
        MouseUtilitiesModule(),
        MouseWithoutBordersModule(),
        NewPlusModule(),
        PeekModule(),
        PowerDisplayModule(),
        PowerRenameModule(),
        QuickAccentModule(),
        PlistPreviewModule(),
        ScreenRulerModule(),
        ShortcutGuideModule(),
        TextExtractorModule(),
        WindowHopperModule(),
        WorkspacesModule(),
        ZoomItModule(),
        ] + CommandPaletteModule.companions
    }
}
