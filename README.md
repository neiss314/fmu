# Factorio Mod Updater (FMU)

## Description

**Factorio Mod Updater (FMU)** is a command-line tool that automatically updates your **Factorio** mods and downloads missing dependencies.

The program scans the current folder for `.zip` mod files, checks the **Factorio Mod Portal** for newer versions, downloads updates from a mirror, and recursively resolves all required dependencies.

---

## Features

### Automatic Mod Updates

FMU scans the current directory for installed mods and checks whether newer versions are available.

If an update is found, the tool automatically downloads and replaces the outdated mod archive.

---

### Dependency Resolution

Many Factorio mods depend on other mods.

FMU automatically:

- detects required dependencies
- downloads missing ones
- resolves dependencies **recursively**

This ensures the mod set is always complete and compatible.

---

### Mirror-Based Downloads

Instead of downloading directly from the mod portal, the updater retrieves files from a **mirror server**, allowing faster and more reliable downloads.

---

### Clear Console Output

The program uses coloured console output to clearly show what is happening:

- **Cyan** — section headers and progress information  
- **Green** — mod is up to date or update successful  
- **Yellow** — update available  
- **Red** — errors or failed downloads  

---

## Usage

1. Place **`fmu.exe`** (or the compiled binary) in your **Factorio mods folder** — the directory that contains all `.zip` mod files.
2. Run the program:
   - from the command line, or
   - by double-clicking the executable.
3. Watch the console output as FMU checks mods and downloads updates.
4. After completion, press **Enter** to close the program.

## Parameters
  - /P=<path> - path to the Factorio mods folder. ( Default: folder where fmu.exe is located.
  - /R - download recommended mods (marked with ? in dependencies).
  - /V' - display program version.
  - /H' - help. 
   Examples:
  -  fmu.exe
  -  fmu.exe /P="C:\Games\Factorio\mods"
  -  fmu.exe /P="C:\Games\Factorio\mods" /R  
    
---

## Requirements

- **Windows** (uses WinInet for HTTP requests)

---

## Building From Source

The project can be compiled with:

- **Free Pascal Compiler (FPC)**
- **Lazarus**

---

## Dependencies

The project uses the **Json Tools Pascal Unit**:

https://github.com/sysrpl/JsonTools
