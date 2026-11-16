-- OpenConnect Proxy Login: a background helper for the openconnect-ocproxy container on macOS.
-- Every minute it asks the container for its state. When a login is needed (first start, expired or
-- dropped session) or the session is about to expire, it shows a notification that says why and
-- asks to click it; the click opens the default terminal with `docker exec -it <container> vpn-login`.
-- It stores no credentials. Build with build.sh (stay-open applet without a Dock icon). Opening the
-- app also starts a due login; otherwise it shows the state, with a button to quit the helper.
-- Settings (optional):
--   defaults write io.github.matteosecli.openconnect-ocproxy.login-helper containerName <name>
--   defaults write io.github.matteosecli.openconnect-ocproxy.login-helper reminderMinutes -int 30
--   defaults write io.github.matteosecli.openconnect-ocproxy.login-helper terminalApp iTerm

use AppleScript version "2.4"
use framework "Foundation"
use framework "AppKit"
use scripting additions

property appTitle : "OpenConnect Proxy"
property bundleId : "io.github.matteosecli.openconnect-ocproxy.login-helper"
property checkInterval : 60 -- seconds between checks
property expiryWarningSeconds : 900 -- matches the container's default reminder

global containerName, reminderMinutes, terminalApp, snoozeUntil, warnedExpiry, lastState

on run
	set containerName to my readSetting("containerName", "openconnect-ocproxy")
	set reminderMinutes to (my readSetting("reminderMinutes", "30")) as integer
	set terminalApp to my readSetting("terminalApp", "")
	set snoozeUntil to current date
	set warnedExpiry to ""
	set lastState to ""
	-- Notifications are posted through NSUserNotificationCenter with this script as the delegate,
	-- so a click on one reaches the helper.
	current application's NSUserNotificationCenter's defaultUserNotificationCenter()'s setDelegate:me
	my checkNow("auto")
end run

on idle
	my checkNow("auto")
	return checkInterval
end idle

-- Opening the app while it runs (Finder, Spotlight, Launchpad).
on reopen
	my checkNow("open")
end reopen

on quit
	continue quit
end quit

-- mode: "auto" (the periodic check), "click" (a login notification was clicked) or "open" (the app
-- was opened). For a click or an open, a due login starts right away; otherwise a click is answered
-- with a notification (the reminder was out of date) and an open with the state.
on checkNow(mode)
	set stateWords to my splitWords(my vpnState())
	set state to item 1 of stateWords
	-- Confirm a login that just went through (from this helper's terminal window or anywhere else).
	if state is "ok" and lastState is in {"login", "busy"} then
		my removeNotifications()
		my postNotification("VPN connected", "The login succeeded.", "none")
	end if
	set lastState to state
	if state is "login" then
		if mode is not "auto" then
			my startLogin()
		else if (current date) >= snoozeUntil then
			set reason to ""
			if (count of stateWords) > 1 then set reason to item 2 of stateWords
			my notifyLogin("VPN login needed", my reasonText(reason) & "Click to log in.")
		end if
	else if state is "expiring" then
		set minutesLeft to item 2 of stateWords
		set expiryId to item 3 of stateWords
		if mode is not "auto" then
			my startLogin()
		else if expiryId is not warnedExpiry and (current date) >= snoozeUntil then
			set warnedExpiry to expiryId
			my notifyLogin("VPN session ends in " & minutesLeft & " min", "Click to log in again now.")
		end if
	else if mode is "click" then
		if state is "busy" then
			my postNotification("No action needed", "A login is already in progress.", "none")
		else if state is "ok" then
			my postNotification("No action needed", "The VPN is already connected.", "none")
		else
			my postNotification("VPN not available", "The container or Docker is not running.", "none")
		end if
	else if mode is "open" then
		if state is "busy" then
			my showStatus("A login is already in progress in a terminal window.")
		else if state is "ok" then
			my showStatus("The VPN is connected (or starting). Nothing to do.")
		else
			my showStatus("The container " & quoted form of containerName & " is not running, or Docker is not running.")
		end if
	end if
end checkNow

-- A notification only, so it never takes focus; a click on it starts the login. Repeated every
-- reminderMinutes while a login is still needed; each one replaces the previous.
on notifyLogin(headline, message)
	my removeNotifications()
	my postNotification(headline, message, "login")
	set snoozeUntil to (current date) + reminderMinutes * minutes
end notifyLogin

-- clickAction: "login" makes a click on the notification start the login; "none" does nothing.
-- Kept to a headline and one short line, so a banner can be read before it slides away. No
-- buttons: macOS would only show them on hover.
on postNotification(headline, message, clickAction)
	set theNote to current application's NSUserNotification's alloc()'s init()
	theNote's setTitle:appTitle
	theNote's setSubtitle:headline
	theNote's setInformativeText:message
	theNote's setHasActionButton:false
	theNote's setUserInfo:{action:clickAction}
	current application's NSUserNotificationCenter's defaultUserNotificationCenter()'s deliverNotification:theNote
end postNotification

on removeNotifications()
	current application's NSUserNotificationCenter's defaultUserNotificationCenter()'s removeAllDeliveredNotifications()
end removeNotifications

-- NSUserNotificationCenter delegate: a click on a notification.
on userNotificationCenter:aCenter didActivateNotification:theNote
	try
		set actionName to ((theNote's userInfo())'s objectForKey:"action") as text
		if actionName is "login" then my checkNow("click")
	on error errText number errNum
		-- Visible with: log show --last 1h --predicate 'process == "logger"'
		do shell script "logger -t ocproxy-notifier " & quoted form of ("click failed (" & errNum & "): " & errText)
	end try
end userNotificationCenter:didActivateNotification:

-- Show notifications even while the helper is the active app (it is, right after a click).
on userNotificationCenter:aCenter shouldPresentNotification:theNote
	return true
end userNotificationCenter:shouldPresentNotification:

-- Why a login is needed, from the container's reason (see vpn-state.sh). Ends with a space.
on reasonText(reason)
	if reason is "login-required" then return "The VPN container started. "
	if reason starts with "tunnel-exited" then return "The VPN session ended. "
	if reason is "startup-failed" then return "The last login did not connect. "
	if reason is "health-check-failed" then return "The VPN stopped working. "
	return ""
end reasonText

on startLogin()
	my openLogin()
	-- Grace period while the terminal starts; afterwards vpn-login's lock reports "busy".
	set snoozeUntil to (current date) + 2 * minutes
end startLogin

on showStatus(message)
	activate
	set answer to display dialog message with title appTitle buttons {"Quit Helper", "OK"} default button "OK" giving up after 120 with icon note
	if button returned of answer is "Quit Helper" then quit
end showStatus

-- Runs vpn-login in the default terminal app: the one macOS uses for executable scripts
-- (public.unix-executable: Terminal on a stock Mac, iTerm2 after "Make iTerm2 Default Term"),
-- or the app named in the terminalApp setting. The login runs from a private temporary script
-- that deletes itself. On success it exits at once; on failure it keeps the error visible until
-- a key is pressed. Both exit cleanly, so the terminal closes the window.
-- iTerm2 is asked over AppleScript for a dedicated window running the script: opening the file
-- instead would add a tab to an existing window, after iTerm2's "run this file?" confirmation.
-- Other terminals get the file with `open`, which in Terminal is a new window.
on openLogin()
	set scriptText to "#!/bin/bash" & linefeed & ¬
		"# Opened by OpenConnect Proxy Login; deletes itself." & linefeed & ¬
		"rm -rf -- \"$(dirname \"$0\")\"" & linefeed & ¬
		"PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.docker/bin\"" & linefeed & ¬
		"printf '\\033]0;%s\\007' 'OpenConnect Proxy Login'" & linefeed & ¬
		"clear" & linefeed & ¬
		"docker exec -it " & quoted form of containerName & " vpn-login && exit 0" & linefeed & ¬
		"echo" & linefeed & ¬
		"read -rsn1 -p 'Login did not complete. Press any key to close this window.'" & linefeed & ¬
		"exit 0" & linefeed
	set scriptPath to do shell script "d=$(mktemp -d -t openconnect-proxy-login) && f=\"$d/vpn-login\" && " & ¬
		"printf '%s' " & quoted form of scriptText & " > \"$f\" && chmod 700 \"$f\" && printf '%s' \"$f\""
	set appId to my terminalAppId(scriptPath)
	if appId is "com.googlecode.iterm2" then
		-- Compiled at run time, so building the app does not need iTerm2 installed.
		set iTermScript to "on run {commandLine}" & linefeed & ¬
			"tell application id \"com.googlecode.iterm2\"" & linefeed & ¬
			"create window with default profile command commandLine" & linefeed & ¬
			"activate" & linefeed & ¬
			"end tell" & linefeed & ¬
			"end run"
		try
			run script iTermScript with parameters {quoted form of scriptPath}
			return
		on error errorText number errorNumber
			-- e.g. -1743: control of iTerm2 not allowed in Privacy & Security → Automation.
			log "iTerm2 scripting failed (" & errorNumber & "): " & errorText
		end try
	end if
	if appId is "" then
		do shell script "open " & quoted form of scriptPath
	else
		do shell script "open -b " & quoted form of appId & " " & quoted form of scriptPath
	end if
end openLogin

-- Bundle ID of the terminal to use: the terminalApp setting, else the app macOS would open the
-- script with. "" lets `open` decide.
on terminalAppId(scriptPath)
	if terminalApp is not "" then
		try
			return id of application terminalApp
		end try
	end if
	try
		set appURL to current application's NSWorkspace's sharedWorkspace()'s URLForApplicationToOpenURL:(current application's NSURL's fileURLWithPath:scriptPath)
		if appURL is missing value then return ""
		return (current application's NSBundle's bundleWithURL:appURL)'s bundleIdentifier() as text
	on error
		return ""
	end try
end terminalAppId

on vpnState()
	set stateScript to POSIX path of (path to resource "vpn-state.sh")
	try
		return do shell script quoted form of stateScript & " " & quoted form of containerName & " " & expiryWarningSeconds
	on error
		return "unavailable"
	end try
end vpnState

on readSetting(settingKey, defaultValue)
	try
		return do shell script "defaults read " & bundleId & " " & quoted form of settingKey
	on error
		return defaultValue
	end try
end readSetting

on splitWords(textValue)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to " "
	set parts to text items of textValue
	set AppleScript's text item delimiters to savedDelimiters
	return parts
end splitWords
