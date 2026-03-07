Factorio Mod Updater (FMU)
is a command-line tool that automatically updates your Factorio mods and downloads missing dependencies.
It scans the current folder for .zip mod files, checks the Factorio mod portal for newer versions, downloads updates from a mirror, and recursively resolves all required dependencies.

Usage:
Place fmu.exe (or the compiled binary) in your Factorio mods folder (where all your .zip mods are located).
Run the program from the command line or by double-clicking.
Follow the coloured console output:
Cyan headers,
Green for success / up‑to‑date,
Yellow for updates available,
Red for errors.
After completion, press Enter to close.

Requirements:
Windows (uses WinInet for HTTP requests)

Use Lazarus or the Free Pascal compiler (fpc).
Uses Json Tools Pascal Unit: http://www.getlazarus.org/json
