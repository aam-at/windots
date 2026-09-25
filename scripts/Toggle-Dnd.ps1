<#
Toggles Windows 11 Do Not Disturb and prints the new state (On or Off).
Bound to Win+Shift+N in shells\Niri-Common.ahk.

Windows has no API for it (the old quiet-hours WNF state no longer drives the
button), so this presses the notification centre's own Do Not Disturb button
through UI Automation. Windows PowerShell 5.1 ships UIAutomationClient; pwsh
may not, so run it with powershell.exe.
#>

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

$center = 'Notification Center'
$buttonId = [Windows.Automation.PropertyCondition]::new(
    [Windows.Automation.AutomationElement]::AutomationIdProperty, 'DoNotDisturbButton')

# The centre is a shell window, not a child of the desktop root; find it from
# the focused element once it has opened.
function Find-DndButton {
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    $element = [Windows.Automation.AutomationElement]::FocusedElement
    while ($element -and $element.Current.Name -ne $center) { $element = $walker.GetParent($element) }
    if ($element) { $element.FindFirst([Windows.Automation.TreeScope]::Descendants, $buttonId) }
}

# ms-actioncenter: toggles the centre, so only open it when it isn't already.
if (-not ($button = Find-DndButton)) { Start-Process 'ms-actioncenter:' }
foreach ($attempt in 1..30) {
    if ($button = Find-DndButton) { break }
    Start-Sleep -Milliseconds 100
}
if (-not $button) { Write-Output 'unavailable'; exit 1 }

$toggle = $button.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
$toggle.Toggle()
Write-Output $toggle.Current.ToggleState
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')   # close the centre again
