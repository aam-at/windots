-- Starship prompt for Clink (cmd.exe), as in Starship's docs. Skipped when
-- starship isn't installed, so cmd still works on a bare machine.
local init = io.popen('starship init cmd 2>nul'):read('*a')
if init ~= '' then load(init)() end
