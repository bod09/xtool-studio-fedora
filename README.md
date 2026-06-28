# xTool Studio on Fedora (Wine)

Run **xTool Studio** on Fedora with a single command. The installer prepares
Wine, installs the app, and adds **xTool Studio** to your application menu,
ready to launch.

Tested on Fedora 44 (KDE Plasma) with an AMD Radeon 890M and an xTool F2
connected over Wi-Fi.

## Before you start

1. Fedora (the installer uses `dnf`).
2. The xTool Studio installer `.exe`. Download it from
   [xtool.com/pages/software](https://www.xtool.com/pages/software) and save it
   to `~/Downloads`.

## Install

Put the installer in `~/Downloads`, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/bod09/xtool-studio-fedora/main/install.sh | bash
```

The installer picks up the newest `xTool-Studio*.exe` in `~/Downloads`
automatically.

To point it at a specific file:

```bash
curl -fsSL https://raw.githubusercontent.com/bod09/xtool-studio-fedora/main/install.sh \
  | bash -s -- /path/to/xTool-Studio-x64-1.7.30.exe
```

Or clone and run it locally:

```bash
git clone https://github.com/bod09/xtool-studio-fedora.git
cd xtool-studio-fedora
./install.sh ~/Downloads/xTool-Studio-x64-1.7.30.exe
```

When it finishes, launch **xTool Studio** from your application menu.

## Display scaling (DPI)

On a HiDPI screen the app can look small. The installer sets a DPI of **163**,
which matches a 170% desktop scale.

If your desktop uses a different scale, edit the `DPI=` line near the top of
`install.sh` before running it, using `96 × (your scale ÷ 100)`. For example:
125% is 120, 150% is 144, 200% is 192.

## First run

1. Choose your region and sign in or create an account.
2. Connect your F2. It needs a one-time USB connection on any computer (such as
   a Windows PC) to save its Wi-Fi credentials. After that it joins your network
   and Studio finds it over Wi-Fi, with no USB needed on Linux.
3. Make sure your computer and the F2 are on the same network.

## Performance

The editor works but can feel a little sluggish. This is the cost of running a
Chromium-based app through Wine on an integrated GPU. The installer already
applies the fastest stable settings, including hardware-accelerated rendering
and the performance power profile.

For heavy design work, you may prefer to edit on a Windows machine and use the
Fedora install to send jobs.

## Updating

The app's built-in updater may not work on Linux. To update, download the newer
installer and run the script again. It keeps your existing setup and just
updates the app:

```bash
./install.sh ~/Downloads/xTool-Studio-x64-NEWVERSION.exe
```

## Uninstall

```bash
rm -rf ~/.local/share/xtool-studio \
       ~/.local/bin/xtool-studio.sh \
       ~/.local/share/applications/xtool-studio.desktop \
       ~/.local/share/icons/hicolor/256x256/apps/xtool-studio.png
```

## Disclaimer

This is an unofficial installer. xTool does not officially support Linux. Use at
your own risk.
