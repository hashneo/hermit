-- =============================================================================
-- HermitNative UI Test Suite
-- =============================================================================
-- Each test:
--   1. Performs an action via the accessibility tree
 --   2. Captures a screenshot (window-specific, never full screen)
--   3. Asserts expected UI elements are present
--   4. Reports PASS / FAIL with the screenshot path
--
-- Usage:
--   osascript hermit-native/tests/ui_tests.applescript
--
-- Screenshots land in /tmp/hermit-tests/<timestamp>/
-- =============================================================================

global gPassCount
global gFailCount
global gResultLog
global gScreenshotDir
global gAppName

set gPassCount to 0
set gFailCount to 0
set gResultLog to {}
set gAppName to "HermitNative"

set gTimestamp to do shell script "date +%Y%m%d_%H%M%S"
set gScreenshotDir to "/tmp/hermit-tests/" & gTimestamp
do shell script "mkdir -p " & quoted form of gScreenshotDir

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

on pass(testName, screenshotPath)
	global gPassCount, gResultLog
	set gPassCount to gPassCount + 1
	set end of gResultLog to "[PASS] " & testName & " -> " & screenshotPath
	log "[PASS] " & testName
end pass

on fail(testName, reason, screenshotPath)
	global gFailCount, gResultLog
	set gFailCount to gFailCount + 1
	set end of gResultLog to "[FAIL] " & testName & " | " & reason & " -> " & screenshotPath
	log "[FAIL] " & testName & " | " & reason
end fail

-- Capture screenshot of a specific app window by partial title match.
-- Falls back to capturing the app's frontmost window by owner name if title not found.
-- Never falls back to full screen to avoid capturing unrelated content.
on captureWindow(windowTitle, label)
	global gScreenshotDir, gAppName
	set safeName to do shell script "echo " & quoted form of label & " | tr ' /:' '___'"
	set outFile to gScreenshotDir & "/" & safeName & ".png"
	set windowID to ""
	try
		set windowID to do shell script "python3 -c \"
import Quartz, sys
wl = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
target = sys.argv[1]
for w in wl:
    if w.get('kCGWindowOwnerName','') == 'HermitNative' and target in w.get('kCGWindowName',''):
        print(w['kCGWindowNumber'])
        break
\" " & quoted form of windowTitle & " 2>/dev/null"
	end try
	if windowID is not "" then
		do shell script "screencapture -l " & windowID & " " & quoted form of outFile
	else
		-- Fall back to first visible HermitNative window
		set windowID to ""
		try
			set windowID to do shell script "python3 -c \"
import Quartz
wl = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
for w in wl:
    if w.get('kCGWindowOwnerName','') == 'HermitNative' and w.get('kCGWindowLayer',999) == 0:
        print(w['kCGWindowNumber'])
        break
\" 2>/dev/null"
		end try
		if windowID is not "" then
			do shell script "screencapture -l " & windowID & " " & quoted form of outFile
		else
			-- Last resort: capture app by owner name bounds only (no full screen)
			do shell script "python3 -c \"
import Quartz, subprocess, sys
wl = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
ids = [str(w['kCGWindowNumber']) for w in wl if w.get('kCGWindowOwnerName','') == 'HermitNative']
if ids:
    subprocess.run(['screencapture', '-l', ids[0], sys.argv[1]])
\" " & quoted form of outFile & " 2>/dev/null || true"
		end if
	end if
	return outFile
end captureWindow

-- Capture the app window even when no specific window title is known (e.g. closed-state checks).
-- Uses the HermitNative menu bar extra / status item window as reference.
on captureAppWindow(label)
	global gScreenshotDir, gAppName
	return my captureWindow("", label)
end captureAppWindow

-- Ensure HermitNative is running; launch from debug build if not.
on ensureAppRunning()
	global gAppName
	set isRunning to false
	tell application "System Events"
		set isRunning to (exists process gAppName)
	end tell
	if not isRunning then
		set appPath to do shell script "find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name 'HermitNative.app' -path '*/Debug/HermitNative.app' 2>/dev/null | head -1"
		if appPath is "" then error "HermitNative.app not found in DerivedData — run make native-build-macos first"
		do shell script "open " & quoted form of appPath
		delay 4
	end if
	tell application "System Events"
		tell process gAppName
			set frontmost to true
		end tell
	end tell
	delay 0.5
end ensureAppRunning

-- Close all RFC detail windows (not Hermit popover, not Settings).
on closeAllRFCWindows()
	global gAppName
	try
		tell application "System Events"
			tell process gAppName
				set allWins to every window
				repeat with w in allWins
					set wTitle to title of w
					if wTitle is not "Hermit" and wTitle is not "Settings" and wTitle is not "" then
						try
							perform action "AXRaise" of w
							keystroke "w" using {command down}
							delay 0.3
						end try
					end if
				end repeat
			end tell
		end tell
	end try
end closeAllRFCWindows

-- Open an RFC window by partial title. Returns true on success.
on openRFCWindow(rfcTitle)
	global gAppName
	-- First close popover if open
	try
		tell application "System Events"
			tell process gAppName
				key code 53
			end tell
		end tell
	end try
	delay 0.3
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 1.0
				-- Walk all menu items; open first repo submenu; find RFC
				set topItems to every menu item of menu 1 of menu bar item 1 of menu bar 2
				repeat with mi in topItems
					-- Each repo item has a submenu
					try
						set rfcItems to every menu item of menu 1 of mi
						repeat with ri in rfcItems
							if (name of ri) contains rfcTitle then
								click ri
								delay 2.0
								return true
							end if
							-- Try one level deeper (grouped by status)
							try
								set nested to every menu item of menu 1 of ri
								repeat with ni in nested
									if (name of ni) contains rfcTitle then
										click ni
										delay 2.0
										return true
									end if
								end repeat
							end try
						end repeat
					end try
				end repeat
				key code 53
			end tell
		end tell
	end try
	return false
end openRFCWindow

-- =============================================================================
-- TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. APP LAUNCH
-- ---------------------------------------------------------------------------

on test_01_appRunning()
	my ensureAppRunning()
	set shot to my captureAppWindow("01_1_app_running")
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				set found to (exists menu bar item 1 of menu bar 2)
			end tell
		end tell
	end try
	if found then
		my pass("1.1 App running – menu bar extra present", shot)
	else
		my fail("1.1 App running – menu bar extra present", "menu bar 2 item 1 not found", shot)
	end if
end test_01_appRunning

on test_02_menuBarPopoverOpens()
	my ensureAppRunning()
	-- Open, screenshot while open, then close — all in one tell block
	set shot to ""
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 0.8
				-- Screenshot while menu is open
				set shot to my captureWindow("Hermit", "01_2_menubar_popover")
				-- Check menu has items
				try
					set cnt to count of every menu item of menu 1 of menu bar item 1 of menu bar 2
					if cnt > 0 then set found to true
				end try
				key code 53
				delay 0.3
			end tell
		end tell
	end try
	if shot is "" then set shot to my captureAppWindow("01_2_menubar_popover_fallback")
	if found then
		my pass("1.2 Menu bar popover opens and has items", shot)
	else
		my fail("1.2 Menu bar popover opens and has items", "no menu items found", shot)
	end if
end test_02_menuBarPopoverOpens

-- ---------------------------------------------------------------------------
-- 2. MENU BAR CONTENT
-- ---------------------------------------------------------------------------

on test_03_repoSubmenuPresent()
	my ensureAppRunning()
	set shot to ""
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 0.8
				set shot to my captureWindow("Hermit", "02_1_repo_submenu")
				set topItems to every menu item of menu 1 of menu bar item 1 of menu bar 2
				repeat with mi in topItems
					try
						if exists menu 1 of mi then
							set found to true
							exit repeat
						end if
					end try
				end repeat
				key code 53
				delay 0.3
			end tell
		end tell
	end try
	if shot is "" then set shot to my captureAppWindow("02_1_repo_submenu_fallback")
	if found then
		my pass("2.1 Repo submenu present in menu bar popover", shot)
	else
		my fail("2.1 Repo submenu present in menu bar popover", "no submenu-bearing item found", shot)
	end if
end test_03_repoSubmenuPresent

on test_04_settingsMenuItemPresent()
	my ensureAppRunning()
	set shot to ""
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 0.8
				set shot to my captureWindow("Hermit", "02_2_settings_item")
				set topItems to every menu item of menu 1 of menu bar item 1 of menu bar 2
				repeat with mi in topItems
					if name of mi contains "Settings" then
						set found to true
						exit repeat
					end if
				end repeat
				key code 53
				delay 0.3
			end tell
		end tell
	end try
	if shot is "" then set shot to my captureAppWindow("02_2_settings_item_fallback")
	if found then
		my pass("2.2 Settings… item present in menu bar popover", shot)
	else
		my fail("2.2 Settings… item present in menu bar popover", "Settings item not found", shot)
	end if
end test_04_settingsMenuItemPresent

on test_05_refreshAllPresent()
	my ensureAppRunning()
	set shot to ""
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 0.8
				set shot to my captureWindow("Hermit", "02_3_refresh_all")
				set topItems to every menu item of menu 1 of menu bar item 1 of menu bar 2
				repeat with mi in topItems
					if name of mi contains "Refresh" then
						set found to true
						exit repeat
					end if
				end repeat
				key code 53
				delay 0.3
			end tell
		end tell
	end try
	if shot is "" then set shot to my captureAppWindow("02_3_refresh_all_fallback")
	if found then
		my pass("2.3 Refresh All item present in menu bar popover", shot)
	else
		my fail("2.3 Refresh All item present in menu bar popover", "Refresh item not found", shot)
	end if
end test_05_refreshAllPresent

-- ---------------------------------------------------------------------------
-- 3. RFC WINDOW
-- ---------------------------------------------------------------------------

on test_06_rfcWindowOpens()
	my ensureAppRunning()
	my closeAllRFCWindows()
	delay 0.5
	set opened to my openRFCWindow("RFC-001")
	delay 1.0
	set shot to my captureWindow("RFC-001", "03_1_rfc_window_opens")
	if not opened then
		my fail("3.1 RFC window opens", "openRFCWindow returned false", shot)
		return
	end if
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "RFC-001" then
						set found to true
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	if found then
		my pass("3.1 RFC window opens with correct title", shot)
	else
		my fail("3.1 RFC window opens with correct title", "no window with RFC-001 in title", shot)
	end if
end test_06_rfcWindowOpens

on test_07_rfcContentScrollArea()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "03_2_rfc_scroll_area")
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					-- Check group 1 contains a scroll area
					try
						set found to (exists scroll area 1 of group 1 of rfcWin)
					end try
				end if
			end tell
		end tell
	end try
	if found then
		my pass("3.2 RFC content scroll area present", shot)
	else
		my fail("3.2 RFC content scroll area present", "scroll area 1 of group 1 not found", shot)
	end if
end test_07_rfcContentScrollArea

on test_08_toolbarShareButton()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "03_3_toolbar_share_button")
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					try
						set found to (exists menu button "Share" of group 1 of toolbar 1 of rfcWin)
					end try
				end if
			end tell
		end tell
	end try
	if found then
		my pass("3.3 Toolbar Share/Export menu button present", shot)
	else
		my fail("3.3 Toolbar Share/Export menu button present", "menu button Share not found in toolbar", shot)
	end if
end test_08_toolbarShareButton

on test_08b_rfcTextAreasRendered()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "03_4_rfc_text_areas")
	set blockCount to 0
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					try
						set blockCount to (count of every text area of scroll area 1 of group 1 of rfcWin)
					end try
				end if
			end tell
		end tell
	end try
	if blockCount > 0 then
		my pass("3.4 RFC renders " & blockCount & " text area blocks", shot)
	else
		my fail("3.4 RFC text area blocks rendered", "0 text areas found in scroll area", shot)
	end if
end test_08b_rfcTextAreasRendered

-- ---------------------------------------------------------------------------
-- 4. EXPORT ACTIONS
-- ---------------------------------------------------------------------------

on test_09_exportMenuItems()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "04_1_export_menu_open")
	set hasPDF to false
	set hasRTF to false
	set hasPrint to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					perform action "AXPress" of menu button "Share" of group 1 of toolbar 1 of rfcWin
					delay 0.5
					set shot to my captureWindow("RFC-001", "04_1_export_menu_open")
					try
						set shareMenu to menu "Share" of group 1 of toolbar 1 of rfcWin
						set hasPDF to (exists menu item "Export as PDF…" of shareMenu)
						set hasRTF to (exists menu item "Export as RTF…" of shareMenu)
						set hasPrint to (exists menu item "Print…" of shareMenu)
					end try
					key code 53
					delay 0.3
				end if
			end tell
		end tell
	end try
	if hasPDF and hasRTF and hasPrint then
		my pass("4.1 Export menu shows PDF, RTF, and Print items", shot)
	else
		my fail("4.1 Export menu items", "PDF:" & hasPDF & " RTF:" & hasRTF & " Print:" & hasPrint, shot)
	end if
end test_09_exportMenuItems

on test_10_exportPDFSavePanel()
	my ensureAppRunning()
	set panelAppeared to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					perform action "AXPress" of menu button "Share" of group 1 of toolbar 1 of rfcWin
					delay 0.5
					click menu item "Export as PDF…" of menu "Share" of group 1 of toolbar 1 of rfcWin
					delay 2.0
				end if
			end tell
		end tell
	end try
	set shot to my captureWindow("Save", "04_2_export_pdf_panel")
	try
		tell application "System Events"
			tell process gAppName
				-- Sheet on RFC window
				repeat with w in every window
					if title of w contains "RFC-001" then
						try
							if (count of every sheet of w) > 0 then set panelAppeared to true
						end try
						exit repeat
					end if
				end repeat
				-- Standalone save panel
				if not panelAppeared then
					repeat with w in every window
						set wt to title of w
						if wt is "" or wt contains "Save" or wt contains "Export" then
							set panelAppeared to true
							exit repeat
						end if
					end repeat
				end if
				-- Dismiss
				key code 53
				delay 0.5
			end tell
		end tell
	end try
	if panelAppeared then
		my pass("4.2 Export as PDF shows save panel", shot)
	else
		my fail("4.2 Export as PDF shows save panel", "no save panel appeared", shot)
	end if
end test_10_exportPDFSavePanel

on test_11_exportRTFSavePanel()
	my ensureAppRunning()
	set panelAppeared to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					perform action "AXPress" of menu button "Share" of group 1 of toolbar 1 of rfcWin
					delay 0.5
					click menu item "Export as RTF…" of menu "Share" of group 1 of toolbar 1 of rfcWin
					delay 2.0
				end if
			end tell
		end tell
	end try
	set shot to my captureWindow("Save", "04_3_export_rtf_panel")
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "RFC-001" then
						try
							if (count of every sheet of w) > 0 then set panelAppeared to true
						end try
						exit repeat
					end if
				end repeat
				if not panelAppeared then
					repeat with w in every window
						set wt to title of w
						if wt is "" or wt contains "Save" or wt contains "Export" then
							set panelAppeared to true
							exit repeat
						end if
					end repeat
				end if
				key code 53
				delay 0.5
			end tell
		end tell
	end try
	if panelAppeared then
		my pass("4.3 Export as RTF shows save panel", shot)
	else
		my fail("4.3 Export as RTF shows save panel", "no save panel appeared", shot)
	end if
end test_11_exportRTFSavePanel

-- ---------------------------------------------------------------------------
-- 5. LIFECYCLE TOOLBAR BUTTONS
-- ---------------------------------------------------------------------------

on test_12_lifecycleButtons()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "05_1_lifecycle_buttons")
	set foundApprove to false
	set foundImplemented to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					set tb to toolbar 1 of rfcWin
					-- Flatten toolbar elements one level deep
					set elems to {}
					repeat with grp in every group of tb
						repeat with el in every UI element of grp
							set end of elems to el
						end repeat
					end repeat
					repeat with el in every UI element of tb
						set end of elems to el
					end repeat
					repeat with el in elems
						set lbl to ""
						try
							set lbl to description of el
						end try
						if lbl is "" then
							try
								set lbl to title of el
							end try
						end if
						if lbl contains "Approve" then set foundApprove to true
						if lbl contains "Implement" or lbl contains "Mark" then set foundImplemented to true
					end repeat
				end if
			end tell
		end tell
	end try
	if foundApprove or foundImplemented then
		my pass("5.1 Lifecycle toolbar button(s) present", shot)
	else
		my fail("5.1 Lifecycle toolbar button(s) present", "no Approve or Mark Implemented button found", shot)
	end if
end test_12_lifecycleButtons

-- ---------------------------------------------------------------------------
-- 6. SETTINGS WINDOW
-- ---------------------------------------------------------------------------

on test_13_settingsWindowOpens()
	my ensureAppRunning()
	set found to false
	try
		tell application "System Events"
			tell process gAppName
				click menu bar item 1 of menu bar 2
				delay 0.8
				set topItems to every menu item of menu 1 of menu bar item 1 of menu bar 2
				repeat with mi in topItems
					if name of mi contains "Settings" then
						click mi
						delay 1.2
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	set shot to my captureWindow("Settings", "06_1_settings_window")
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "Settings" then
						set found to true
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	if found then
		my pass("6.1 Settings window opens", shot)
	else
		my fail("6.1 Settings window opens", "no Settings window found", shot)
	end if
end test_13_settingsWindowOpens

on test_14_settingsTabsPresent()
	my ensureAppRunning()
	set shot to my captureWindow("Settings", "06_2_settings_tabs")
	set tabCount to 0
	try
		tell application "System Events"
			tell process gAppName
				set settingsWin to missing value
				repeat with w in every window
					if title of w contains "Settings" then
						set settingsWin to w
						exit repeat
					end if
				end repeat
				if settingsWin is not missing value then
					try
						set tabCount to count of every tab group of settingsWin
					end try
					if tabCount = 0 then
						try
							set tabCount to count of every radio button of settingsWin
						end try
					end if
					if tabCount = 0 then
						-- SwiftUI toolbar tabs sometimes appear as buttons
						try
							set tabCount to count of every button of toolbar 1 of settingsWin
						end try
					end if
				end if
			end tell
		end tell
	end try
	if tabCount >= 2 then
		my pass("6.2 Settings window has " & tabCount & " tab controls", shot)
	else
		my fail("6.2 Settings tabs present", "found " & tabCount & ", expected ≥ 2", shot)
	end if
end test_14_settingsTabsPresent

on test_15_settingsWindowCloses()
	my ensureAppRunning()
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "Settings" then
						perform action "AXRaise" of w
						keystroke "w" using {command down}
						delay 0.5
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	set shot to my captureAppWindow("06_3_settings_closed")
	set stillOpen to false
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "Settings" then
						set stillOpen to true
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	if not stillOpen then
		my pass("6.3 Settings window closes with ⌘W", shot)
	else
		my fail("6.3 Settings window closes with ⌘W", "Settings window still present", shot)
	end if
end test_15_settingsWindowCloses

-- ---------------------------------------------------------------------------
-- 7. DIAGRAM POPOUT (opportunistic)
-- ---------------------------------------------------------------------------

on test_16_diagramPopout()
	my ensureAppRunning()
	set shot to my captureWindow("RFC-001", "07_1_before_diagram_click")
	set foundDiagram to false
	try
		tell application "System Events"
			tell process gAppName
				set rfcWin to missing value
				repeat with w in every window
					if title of w contains "RFC-001" then
						set rfcWin to w
						exit repeat
					end if
				end repeat
				if rfcWin is not missing value then
					try
						repeat with grp in every group of group 1 of scroll area 1 of group 1 of rfcWin
							set desc to description of grp
							if desc contains "diagram" or desc contains "mermaid" or desc contains "Diagram" then
								click grp
								set foundDiagram to true
								delay 1.0
								exit repeat
							end if
						end repeat
					end try
				end if
			end tell
		end tell
	end try
	if not foundDiagram then
		my pass("7.1 Diagram popout – skipped (no diagram block in RFC-001)", shot)
		return
	end if
	set shot to my captureWindow("Diagram", "07_1_diagram_window")
	set foundWin to false
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "Diagram" or title of w contains "diagram" then
						set foundWin to true
						exit repeat
					end if
				end repeat
				if foundWin then
					keystroke "w" using {command down}
					delay 0.3
				end if
			end tell
		end tell
	end try
	if foundWin then
		my pass("7.1 Diagram popout window opens", shot)
	else
		my fail("7.1 Diagram popout window opens", "no Diagram window appeared", shot)
	end if
end test_16_diagramPopout

-- ---------------------------------------------------------------------------
-- 8. RFC WINDOW CLOSES
-- ---------------------------------------------------------------------------

on test_17_rfcWindowCloses()
	my ensureAppRunning()
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "RFC-001" then
						perform action "AXRaise" of w
						keystroke "w" using {command down}
						delay 0.5
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	set shot to my captureAppWindow("08_1_rfc_closed")
	set stillOpen to false
	try
		tell application "System Events"
			tell process gAppName
				repeat with w in every window
					if title of w contains "RFC-001" then
						set stillOpen to true
						exit repeat
					end if
				end repeat
			end tell
		end tell
	end try
	if not stillOpen then
		my pass("8.1 RFC window closes with ⌘W", shot)
	else
		my fail("8.1 RFC window closes with ⌘W", "RFC-001 window still present", shot)
	end if
end test_17_rfcWindowCloses

-- =============================================================================
-- RUNNER
-- =============================================================================

log "========================================"
log "HermitNative UI Test Suite"
log "Screenshots: " & gScreenshotDir
log "========================================"

my test_01_appRunning()
my test_02_menuBarPopoverOpens()
my test_03_repoSubmenuPresent()
my test_04_settingsMenuItemPresent()
my test_05_refreshAllPresent()
my test_06_rfcWindowOpens()
my test_07_rfcContentScrollArea()
my test_08_toolbarShareButton()
my test_08b_rfcTextAreasRendered()
my test_09_exportMenuItems()
my test_10_exportPDFSavePanel()
my test_11_exportRTFSavePanel()
my test_12_lifecycleButtons()
my test_13_settingsWindowOpens()
my test_14_settingsTabsPresent()
my test_15_settingsWindowCloses()
my test_16_diagramPopout()
my test_17_rfcWindowCloses()

log ""
log "========================================"
log "RESULTS"
log "========================================"
repeat with r in gResultLog
	log r
end repeat
log ""
log "PASSED: " & gPassCount & "  FAILED: " & gFailCount
log "Screenshots: " & gScreenshotDir
log "========================================"
