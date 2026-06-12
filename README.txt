Phone Mirror Portable Launcher
==============================

Run:
  Phone Mirror Menu.cmd

Keep these files together in one folder:
  Phone Mirror Menu.cmd
  start-phone-mirror.ps1
  Saved Wireless Devices.ps1
  phone-mirror-devices.json

The saved devices file is optional. If it is missing, the scripts create it again.
If you move this folder to a new PC or a new network, you can delete
phone-mirror-devices.json to start fresh.

Tools:
  adb and scrcpy can be installed normally on Windows, or placed beside these files.

Portable tool layouts supported:
  adb.exe
  platform-tools\adb.exe
  tools\adb.exe
  tools\platform-tools\adb.exe
  scrcpy.exe
  scrcpy-win64\scrcpy.exe
  scrcpy-win32\scrcpy.exe
  tools\scrcpy.exe
  tools\scrcpy-win64\scrcpy.exe
  tools\scrcpy-win32\scrcpy.exe

Menu:
  1. USB Mirror
  2. Wireless Mirror
  3. Pair Wireless Mirror
  4. USB Mirror Dim Phone Screen
  5. Wireless Mirror Dim Phone Screen
  6. Pair Wireless Dim Phone Screen
  7. Saved Wireless Devices
  8. Exit

Wireless sessions disconnect automatically when the mirror window closes.

Privacy note:
  Normal scrcpy mirrors the same display shown on the phone. Showing a cover
  image on the phone would also show that cover image on the PC mirror. The
  screen-off mode is intentionally not included here because it can leave some
  phones with a dark display after disconnecting.

  The dim screen options are safer: they keep the phone display on, lower the
  phone brightness while mirroring, then restore the previous brightness when
  the mirror closes. This makes the phone harder to read nearby, but it is not a
  complete privacy cover.
