# xTool Studio on Fedora (Wine)

An interactive installer and configurator that runs **xTool Studio** on Fedora
through system Wine. The first run installs everything; later runs let you
change settings, update the app, or uninstall, without rebuilding anything you
do not have to.

Tested on Fedora 44 (KDE Plasma).

## Before you start

1. Fedora (the installer uses `dnf`).
2. The xTool Studio installer `.exe`. Download it from
   [xtool.com/pages/software](https://www.xtool.com/pages/software) and save it
   to `~/Downloads`.

## Install

Put the installer in `~/Downloads`, then run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bod09/xtool-studio-fedora/main/install.sh)"
```

This opens an interactive menu.

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

* `gl` (default): stable and hardware accelerated.
* `vulkan`: can be faster, but sometimes shows visual glitches.
* `disable-gpu`: software rendering, slowest but most compatible.

The installer detects your GPU and defaults to `gl`. You can switch and relaunch
to compare. Nvidia cards are pickier, so `gl` is strongly recommended there.

### DPI (display scaling)

The app can look tiny on a high-resolution screen. The installer detects your
desktop scale and suggests a matching DPI, for example "150% gives DPI 144". You
can accept it or type your own value. If it cannot detect your scale, it uses 96
(100%) and asks you to set it.

The launcher does not change your system power profile. That is your own
preference, so it is left exactly as you set it.

### Thread-sync accelerators (ntsync/fsync)

`auto` (default) enables them when `/dev/ntsync` exists, or you can force them
`on` or `off`.

## First run

1. Choose your region and sign in or create an account.
2. Connect your engraver. It needs a one-time USB connection on any computer
   (such as a Windows PC) to save its Wi-Fi credentials. After that it joins your
   network and Studio finds it over Wi-Fi, with no USB needed on Linux.
3. Make sure your computer and the engraver are on the same network.

On first launch the app may pop up **Install driver** boxes for RNDIS and CH340.
You do not need to click Install. Tick **No more reminders** and close them. They
will otherwise reappear on every launch: the CH340 driver cannot install under
Wine (Linux provides it instead), so clicking Install does nothing. Dismissing
them is harmless. If you want a USB cable connection, see Connecting over USB
below.

## Connecting over USB

Most people set the engraver up over Wi-Fi (see First run). If you do not have a
second computer for the Wi-Fi onboarding, you can connect over a USB cable.

Run the script and choose **Set up USB device connection (CH340 serial)**. It
sets up the Linux side for you. You may be asked for your password, and you will
need to log out and back in once afterwards. Then plug the engraver in over USB
and it should appear in xTool Studio.

## Performance

The editor works but can feel a little sluggish. This is the cost of running a
Chromium-based app through Wine, and it is more noticeable on lower-powered or
integrated graphics. The defaults already use the fastest stable setup. For heavy
design work, you may prefer to edit on a Windows machine and use the Fedora
install to send jobs.

## Window titlebar

The installer takes care of the window titlebar so you do not get a doubled or
clipped one. When the window is maximised you may see a thin white border around
it; that is harmless and cosmetic. If you would rather avoid it, use the window
at a large size instead of fully maximised.

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
       ~/.local/share/icons/hicolor/512x512/apps/xtool-studio.png \
       ~/.config/xtool-studio
```

## Disclaimer

This is an unofficial installer. xTool does not officially support Linux. Use at
your own risk.
