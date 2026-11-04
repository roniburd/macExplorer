-- Out-of-process Accessibility smoke for macExplorer (run by scripts/ui-ax-smoke.sh; read-only, presses nothing).
-- Usage: osascript ui-ax-smoke.applescript <pid> <expected row count> <timeout seconds>
-- Prints "title=<window title>", "window=<AXIdentifier>", "rows=<row count of macx.details>" on success.
on run argv
	set targetPID to (item 1 of argv) as integer
	set wantRows to (item 2 of argv) as integer
	set deadline to (current date) + ((item 3 of argv) as integer)
	tell application "System Events"
		repeat
			set procs to (every process whose unix id is targetPID)
			if (count of procs) > 0 then
				if (count of windows of (item 1 of procs)) > 0 then exit repeat
			end if
			if (current date) > deadline then error "no window within the timeout" number 1001
			delay 0.2
		end repeat
		set w to window 1 of (item 1 of procs)
		set winTitle to name of w
		set winID to ""
		try
			set winID to value of attribute "AXIdentifier" of w
		end try
		set rowCount to -1
		repeat
			repeat with e in (entire contents of w)
				try
					if (value of attribute "AXIdentifier" of e) is "macx.details" then
						set rowCount to count of (UI elements of e whose role is "AXRow")
						exit repeat
					end if
				end try
			end repeat
			if rowCount is wantRows then exit repeat
			if (current date) > deadline then exit repeat
			delay 0.3
		end repeat
	end tell
	return "title=" & winTitle & linefeed & "window=" & winID & linefeed & "rows=" & rowCount
end run
