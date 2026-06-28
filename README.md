# xTool Studio on Fedora (Wine)

An interactive installer and configurator that runs **xTool Studio** on Fedora
through system Wine. The first run installs everything; later runs let you
change settings, update the app, or uninstall, without rebuilding anything you
do not have to.

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

The script is interactive and still works through `curl ... | bash`: it
reattaches your terminal so the menu can read your answers.

Or clone and run it locally:

```bash
git clone https://github.com/bod09/xtool-studio-fedora.git
cd xtool-studio-fedora
./install.sh
```

On the first run, choose **Full install / repair**. You can also pass an
installer path directly:

```bash
./install.sh ~/Downloads/xTool-Studio-x64-1.7.30.exe
```

When it finishes, launch **xTool Studio** from your application menu.

## The menu

Every run shows a menu. It is safe to run the script as many times as you like.

1. **Full install / repair.** Installs dependencies, builds the Wine prefix,
   extracts the app, sets the icon, and writes the launcher and desktop entry.
   Reuses an existing prefix if one is already there.
2. **Reconfigure settings only.** Re-asks your settings and rewrites just the
   launcher and desktop entry (and reapplies DPI to the existing prefix). No
   reinstall, no re-extraction.
3. **Update app.** Re-extracts the app from a newer installer into your existing
   prefix and keeps all your settings.
4. **Uninstall.** Removes the app, prefix, launcher, desktop entry, and icon,
   and optionally your saved settings.

## Settings

Your choices are saved to `~/.config/xtool-studio/config` and pre-filled the
next time you run the script. Each has a sensible detected or default value.

### GPU rendering backend

* `gl` (default): stable, hardware accelerated.
* `vulkan`: faster, but can show visual glitches.
* `disable-gpu`: software rendering, slowest but safest.

The script detects your GPU (via `lspci`, falling back to `glxinfo`) and shows
it. It does **not** try to auto-pick `gl` versus `vulkan`. Whether the canvas
renders correctly cannot be detected in software: it depends on the exact
GPU, driver, ANGLE, and DXVK combination and only shows up visually. So you get
the safe `gl` default and can switch and judge for yourself. After reconfiguring
you can choose to relaunch the app to compare backends side by side.

If an Nvidia GPU is detected, the script warns you that ANGLE under Wine is
fussier on Nvidia and that `gl` is the safest choice.

### DPI (display scaling)

Wine renders at 96 DPI by default, which looks tiny on a HiDPI screen. The
script detects your desktop scale and suggests a DPI of `round(96 x scale)`:

* On KDE it reads the scale from `kscreen-doctor`, then `~/.config/kdeglobals`,
  then the kscreen config cache.
* On GNOME it reads `text-scaling-factor` from `gsettings` combined with the
  per-monitor (Mutter) scale from `~/.config/monitors.xml`.

It shows what it found, for example `Detected display scale 170% -> suggested
DPI 163`, and lets you accept it or enter your own value. If detection genuinely
fails, it falls back to a neutral **96** (100%, no scaling) and tells you to set
it manually. No DPI value is ever assumed silently.

The launcher does not change your system power profile. That is your own
preference, so it is left exactly as you set it.

### Thread-sync accelerators (ntsync/fsync)

`auto` (default) enables them when `/dev/ntsync` exists, or you can force them
`on` or `off`.

## First run

1. Choose your region and sign in or create an account.
2. Connect your F2. It needs a one-time USB connection on any computer (such as
   a Windows PC) to save its Wi-Fi credentials. After that it joins your network
   and Studio finds it over Wi-Fi, with no USB needed on Linux.
3. Make sure your computer and the F2 are on the same network.

On first launch the app may pop up **Install driver** boxes for RNDIS and CH340.
You do not need to click Install. Tick **No more reminders** and close them. They
will otherwise reappear on every launch: the CH340 driver cannot install under
Wine (Linux provides it instead), so clicking Install does nothing. Dismissing
them is harmless. If you want a USB cable connection, see Connecting over USB
below.

## Connecting over USB

Most people set the engraver up over Wi-Fi (see First run). If you do not have a
second computer to do the Wi-Fi onboarding, you can connect over a USB cable
instead.

On first launch the app may offer to install two drivers, RNDIS and CH340:

* RNDIS is USB networking. The Linux kernel handles it automatically, so the
  USB connection uses the same network path as Wi-Fi with no setup needed.
* CH340 is a USB-to-serial adapter. The driver the app offers to install does
  nothing under Wine (there is no Windows driver model to install into, which is
  why its box never clears). On Linux the kernel is the driver, so just tick
  "No more reminders" on that box and close it.

To prepare the serial connection on Linux, run the script and choose
**Set up USB device connection (CH340 serial)**. It:

* checks the `ch341` kernel module is present,
* detects and offers to disable `brltty` if it is claiming CH340 devices (a
  common cause of the port disappearing on some distros),
* adds you to the `dialout` group so you can access the port (log out and back
  in afterwards),
* installs a udev rule that gives the adapter a stable `/dev/xtool` name with
  the right permissions and keeps ModemManager away from it,
* maps Wine `COM1` to that device.

Then plug the engraver in over USB and it should be available in xTool Studio.

## Performance

The editor works but can feel a little sluggish. This is the cost of running a
Chromium-based app through Wine on an integrated GPU. The defaults already use
the fastest stable setup. For heavy design work, you may prefer to edit on a
Windows machine and use the Fedora install to send jobs.

## Window titlebar

xTool Studio draws its own titlebar. The installer sets `Decorated=N` in the Wine
prefix so the window manager never adds a second titlebar over the app's own,
and so the app's titlebar is not clipped when maximised. This is applied
automatically during a full install and when you choose **Reconfigure settings
only**, and works on any desktop. If you ever see a stray bar, fully close and
relaunch the app.

When the window is maximised you may notice a thin white border around it (the
app's own maximise padding). It is purely cosmetic and left alone; if it bothers
you, run the window at a large size instead of maximised.

## Updating

The app's built-in updater may not work on Linux. To update, download the newer
installer, run the script, and choose **Update app**. It reuses your existing
prefix and settings and just swaps in the new app files.

## Uninstall

Run the script and choose **Uninstall**, or remove everything by hand:

```bash
rm -rf ~/.local/share/xtool-studio \
       ~/.local/bin/xtool-studio.sh \
       ~/.local/share/applications/xtool-studio.desktop \
       ~/.local/share/icons/hicolor/256x256/apps/xtool-studio.png \
       ~/.config/xtool-studio
```

## Disclaimer

This is an unofficial installer. xTool does not officially support Linux. Use at
your own risk.
