import AdvancedPaste
import AlwaysOnTop
import AppVolume
import AutoTiling
import Awake
import CameraMirror
import ChargeLimit
import ClipboardHistory
import ColorPicker
import CommandNotFound
import CommandPalette
import CropAndLock
import EnvironmentVariables
import FancyZones
import FileLocksmith
import FileShelf
import FinderAddons
import FocusDimmer
import GrabAndMove
import HostsEditor
import ImageResizer
import KeyboardManager
import KeystrokeOverlay
import LightSwitch
import MenuBarCalendar
import MenuBarManager
import MouseUtilities
import MouseWithoutBorders
import NewPlus
import Optimizer
import Peek
import PlistPreview
import PowerDisplay
import PowerRename
import PrivacyScreen
import QuickAccent
import QuickSwitches
import ScreenRuler
import Screenshot
import ShortcutGuide
import TextActions
import TextExtractor
import WindowControls
import WindowGestures
import WindowHopper
import Workspaces
import ZoomIt
import MacToysCore

@MainActor
public enum AllModules {
    /// Every utility, in no particular order (Settings sorts by category and name).
    public static func make() -> [any ToyModule] {
        [
        AdvancedPasteModule(),
        AlwaysOnTopModule(),
        AppVolumeModule(),
        AutoTilingModule(),
        AwakeModule(),
        CameraMirrorModule(),
        ChargeLimitModule(),
        ClipboardHistoryModule(),
        ColorPickerModule(),
        CommandNotFoundModule(),
        CommandPaletteModule(),
        CropAndLockModule(),
        EnvironmentVariablesModule(),
        FancyZonesModule(),
        FileLocksmithModule(),
        FileShelfModule(),
        FinderAddonsModule(),
        FocusDimmerModule(),
        GrabAndMoveModule(),
        HostsEditorModule(),
        ImageResizerModule(),
        KeyboardManagerModule(),
        KeystrokeOverlayModule(),
        LightSwitchModule(),
        MenuBarCalendarModule(),
        MenuBarManagerModule(),
        MouseUtilitiesModule(),
        MouseWithoutBordersModule(),
        NewPlusModule(),
        OptimizerModule(),
        PeekModule(),
        PlistPreviewModule(),
        PowerDisplayModule(),
        PowerRenameModule(),
        PrivacyScreenModule(),
        QuickAccentModule(),
        QuickSwitchesModule(),
        ScreenRulerModule(),
        ScreenshotModule(),
        ShortcutGuideModule(),
        TextActionsModule(),
        TextExtractorModule(),
        WindowControlsModule(),
        WindowGesturesModule(),
        WindowHopperModule(),
        WorkspacesModule(),
        ZoomItModule(),
        ] + CommandPaletteModule.companions
    }
}
