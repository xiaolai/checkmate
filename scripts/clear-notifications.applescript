-- Dismisses the alerts Notification Center shows on the test host, before each gate, so a banner cannot cover a
-- pointer click (run-gates.py). Only each alert's own Close or Clear All action is used; nothing else is touched.
-- The `intel` gate launches the app under Rosetta, and macOS answers with an "App Update Required" alert that would
-- otherwise sit over the top-right corner of later gates' windows. Returns "dismissed <count>".
-- Every element of the window is searched: the nesting differs between one alert and a stack of them.
set n to 0
tell application "System Events" to tell process "NotificationCenter"
	repeat 20 times
		set acted to false
		try
			-- Only the alerts' own window: desktop widgets are windows of this process too, and are never touched.
			if not (exists window "Notification Center") then exit repeat
			-- The list is read first: iterating `entire contents` in place yields references that are not elements.
			set elements to entire contents of window "Notification Center"
			repeat with k in elements
				-- An element without actions, or one gone since the list was read, is skipped; that is all this try allows.
				try
					set names to name of every action of (contents of k)
					repeat with i from 1 to count of names
						set nm to item i of names
						if nm contains "Name:Close" or nm contains "Name:Clear All" then
							perform action i of (contents of k)
							set n to n + 1
							set acted to true
							exit repeat
						end if
					end repeat
				end try
				if acted then exit repeat
			end repeat
		on error message number code
			-- No assistive access (-1719, -25211) or no permission to control System Events (-1743) is a failure the
			-- caller must see, not "dismissed 0": the error ends the script, so osascript exits non-zero and run-gates.py
			-- prints its warning. Anything else is the window changing while it is read; the next pass reads it again.
			if code is in {-1719, -25211, -1743} then error message number code
		end try
		if not acted then exit repeat
		delay 1
	end repeat
end tell
return "dismissed " & n
