# 🧹 Clear Windows Caches

A powerful Windows cache cleanup utility written in PowerShell with a modern WPF GUI and command-line support.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell)
![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-blue)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

* 🗂️ Clean Windows Temp files
* 🔄 Clean Windows Update cache
* 🎮 Clean NVIDIA DXCache, GLCache & NV_Cache
* 🎯 Clean DirectX Shader Cache
* 🌐 Flush DNS Resolver Cache
* 🗑️ Empty Recycle Bin
* ⚡ Clean Windows Prefetch
* 🧠 Optimize RAM (Working Set Cleaner)
* 🛡️ Optional System Restore Point
* 🔍 Scan Only mode (estimate recoverable space)
* 🖥️ Modern WPF graphical interface
* 💻 Command-line automation support
* 🔒 Automatic Administrator elevation

---

## Screenshots

> Add screenshots here.

```
/screenshots/main.png
/screenshots/scan.png
```

---

## Requirements

* Windows 10 or Windows 11
* PowerShell 5.1 or newer
* Administrator privileges

---

## Installation

Clone the repository:

```powershell
git clone https://github.com/USERNAME/Clear-WindowsCaches.git
cd Clear-WindowsCaches
```

Or download the latest release from GitHub.

---

## Usage

### GUI Mode

Simply run:

```powershell
.\Clear-WindowsCaches.ps1
```

---

### Scan Only

Estimate recoverable disk space without deleting anything.

```powershell
.\Clear-WindowsCaches.ps1 -ScanOnly
```

---

### Silent Mode

```powershell
.\Clear-WindowsCaches.ps1 -Silent
```

---

### Skip Stopping Windows Update Services

```powershell
.\Clear-WindowsCaches.ps1 -NoServiceStop
```

---

### Memory Cleaner

```powershell
.\Clear-WindowsCaches.ps1 -MemoryClean
```

---

### Create Restore Point

```powershell
.\Clear-WindowsCaches.ps1 -CreateRestorePoint
```

---

## Parameters

| Parameter             | Description                               |
| --------------------- | ----------------------------------------- |
| `-ScanOnly`           | Performs a dry-run without deleting files |
| `-Silent`             | Suppresses the exit prompt                |
| `-NoServiceStop`      | Does not stop Windows Update services     |
| `-MemoryClean`        | Optimizes RAM working sets                |
| `-CreateRestorePoint` | Creates a restore point before cleaning   |

---

## What Gets Cleaned

* Windows Temp
* User Temp
* Windows Update Cache
* NVIDIA DXCache
* NVIDIA GLCache
* NVIDIA NV_Cache
* DirectX Shader Cache
* DNS Cache
* Recycle Bin
* Windows Prefetch

---

## Safety

The script:

* Never deletes Windows system files.
* Skips files currently in use.
* Can create a System Restore Point before cleaning.
* Requires Administrator privileges for protected locations.

---

## Author

**Chya Luqman**

Discord Server

https://discord.com/invite/YTeRSG8kER

---

## License

Released under the MIT License.

---

## Contributing

Pull requests are welcome.

For major changes, please open an issue first to discuss what you would like to change.

---

## Support

If you enjoy this project, consider giving it a ⭐ on GitHub.

It helps the project grow and reach more users.
