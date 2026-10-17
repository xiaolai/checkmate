-- Dismisses the alerts Notification Center shows on the test host, before each gate, so a banner cannot cover a
-- pointer click (run-gates.py). Only each alert's own Close or Clear All action is used; nothing else is touched.
-- The `intel` gate launches the app under Rosetta, and macOS answers with an "App Update Required" alert that would
-- otherwise sit over the top-right corner of later gates' windows. Returns "dismissed <count>".
-- Every element of the window is searched: the nesting differs between one alert and a stack of them.
-- A failure it cannot get past ends the script with an error, so osascript exits non-zero and run-gates.py prints its
-- warning: no assistive access (-1719, -25211) or no permission to control System Events (-1743) at once; a window
-- that still cannot be read, or an alert whose own action still fails, once the passes run out.
set n to 0
set permissionCodes to {-1719, -25211, -1743}
set readFailure to ""
set actionFailure to ""
tell application "System Events" to tell process "NotificationCenter"
	repeat 20 times
		set acted to false
		set readFailure to ""
		try
			-- Only the alerts' own window: desktop widgets are windows of this process too, and are never touched.
			if not (exists window "Notification Center") then exit repeat
			-- The list is read first: iterating `entire contents` in place yields references that are not elements.
			set elements to entire contents of window "Notification Center"
			repeat with k in elements
				-- An element without actions, or one gone since the list was read, has no names to read and is skipped;
				-- a permission error is never skipped.
				try
					set names to name of every action of (contents of k)
				on error message number code
					if code is in permissionCodes then error message number code
					set names to {}
				end try
				repeat with i from 1 to count of names
					set nm to item i of names
					if nm contains "Name:Close" or nm contains "Name:Clear All" then
						try
							perform action i of (contents of k)
							set n to n + 1
							set acted to true
							set actionFailure to ""
						on error message number code
							if code is in permissionCodes then error message number code
							-- Kept, and tried again on the next pass; reported if it never succeeds.
							set actionFailure to message
						end try
						exit repeat
					end if
				end repeat
				if acted then exit repeat
			end repeat
		on error message number code
			if code is in permissionCodes then error message number code
			-- The window changed while it was read: read it again on the next pass, and report it if it never settles.
			set readFailure to message
		end try
		if readFailure is "" and actionFailure is "" and not acted then exit repeat
		delay 1
	end repeat
	if readFailure is not "" then error "Notification Center could not be read: " & readFailure number 1
	if actionFailure is not "" and (exists window "Notification Center") then error "an alert could not be dismissed after " & n & " dismissed: " & actionFailure number 2
end tell
return "dismissed " & n
