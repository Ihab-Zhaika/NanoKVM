# Virtual Audio Setup Guide

## Overview
NanoKVM supports virtual USB audio devices allowing audio streaming between the KVM and remote host. This feature enables you to hear audio from the remote computer through your local speakers or send audio to the remote computer.

## Kernel Requirements

The virtual audio feature requires the UAC2 (USB Audio Class 2) kernel module support:

- `CONFIG_USB_CONFIGFS_F_UAC2=m` - UAC2 function driver for configfs
- `CONFIG_USB_F_UAC2=m` - UAC2 gadget function module
- `CONFIG_SND_USB_AUDIO=m` - USB Audio Class support
- ALSA support (`CONFIG_SND=y`)

## Enabling Virtual Audio

### 1. Enable Audio Devices

Create marker files on the boot partition to enable virtual audio:

```bash
# Enable audio input (microphone from remote host's perspective)
touch /boot/usb.audio_in

# Enable audio output (speaker from remote host's perspective)
touch /boot/usb.audio_out

# Enable both
touch /boot/usb.audio_in /boot/usb.audio_out
```

### 2. Restart USB Gadget

After creating the marker files, restart the USB gadget configuration:

```bash
/etc/init.d/S03usbdev stop_start
```

Or reboot the device:

```bash
reboot
```

### 3. Verify on Remote Host

**Windows:**
- Open Sound Settings → Verify "NanoKVM Audio Input/Output" devices appear
- Right-click volume icon → "Open Sound settings"
- Check both "Output" and "Input" device lists

**Linux:**
```bash
# List USB audio devices
lsusb | grep -i audio

# List capture devices (audio input)
arecord -l

# List playback devices (audio output)
aplay -l
```

**macOS:**
- System Preferences → Sound
- Check Input and Output tabs for "NanoKVM Audio" devices

## Troubleshooting

### "No such file or directory" when creating UAC2 functions

**Symptoms:**
```
mkdir: can't create directory '/sys/kernel/config/usb_gadget/g0/functions/uac2.usb0': No such file or directory
```

**Cause:** UAC2 kernel module not available

**Solution:**

1. Check if module exists:
```bash
ls /lib/modules/$(uname -r)/kernel/drivers/usb/gadget/function/usb_f_uac2.ko
```

2. Load module manually:
```bash
modprobe usb_f_uac2
```

3. Verify module loaded:
```bash
lsmod | grep uac2
```

4. If module is missing, the kernel needs to be rebuilt with UAC2 support. Contact support or rebuild firmware with UAC2 enabled.

### "failed to set mute state" errors

**Symptoms:**
```
[error] [virtual-device.go:353] failed to set mute state: exit status 1
```

**Cause:** USB audio devices not initialized or amixer cannot find audio cards

**Solution:**

1. Verify UAC2 devices are configured:
```bash
ls /sys/kernel/config/usb_gadget/g0/configs/c.1/ | grep uac2
# Should show: uac2.usb0 and uac2.usb1 (if both enabled)
```

2. Check ALSA cards:
```bash
cat /proc/asound/cards
# Should show UAC2 audio cards
```

3. Test amixer:
```bash
amixer -c 0 scontrols
# Should not error
```

4. Restart USB gadget:
```bash
/etc/init.d/S03usbdev stop_start
```

### No audio interface appears on remote host

**Possible causes and solutions:**

1. **Marker files not created:**
   - Verify: `ls -la /boot/usb.audio*`
   - Create: `touch /boot/usb.audio_in /boot/usb.audio_out`

2. **USB gadget not restarted:**
   - Run: `/etc/init.d/S03usbdev stop_start`

3. **UAC2 module not loaded:**
   - Check: `lsmod | grep uac2`
   - Load: `modprobe usb_f_uac2`

4. **USB cable issue:**
   - Ensure using a proper USB data cable (not charge-only)
   - Try a different USB port on the remote host

5. **Remote host driver issue:**
   - Windows: Install latest USB drivers
   - Linux: Ensure `snd-usb-audio` module is loaded on host
   - macOS: Usually works automatically

### Audio quality issues

**Choppy or distorted audio:**

1. Check sample rate configuration (default is 48kHz):
```bash
grep srate /etc/init.d/S03usbdev
```

2. Verify network bandwidth is sufficient for video + audio

3. Check CPU load on NanoKVM:
```bash
top
```

**Audio delay/latency:**

- Virtual audio has inherent latency (typically 100-200ms)
- This is normal for USB audio gadgets over KVM
- Consider using direct audio connection for real-time applications

## Advanced Configuration

### Changing Audio Parameters

Edit `/etc/init.d/S03usbdev` to modify audio settings:

```bash
# Sample rate (default: 48000 Hz)
echo 48000 > functions/uac2.usb0/c_srate

# Channel mask (default: 3 = stereo)
# 1 = mono, 3 = stereo (channels 0+1)
echo 3 > functions/uac2.usb0/c_chmask

# Sample size (default: 2 = 16-bit)
# 2 = 16-bit, 3 = 24-bit, 4 = 32-bit
echo 2 > functions/uac2.usb0/c_ssize
```

After changes, restart the USB gadget:
```bash
/etc/init.d/S03usbdev stop_start
```

### Testing Audio Capture (Input)

On NanoKVM:
```bash
# Record 5 seconds of audio from UAC2 device
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav

# Play back
aplay test.wav
```

On remote host, speak into microphone or play audio while recording on NanoKVM.

### Testing Audio Playback (Output)

On remote host:
```bash
# Linux
aplay -D "NanoKVM Audio Output" test.wav

# Test tone
speaker-test -D "NanoKVM Audio Output" -c 2 -t wav
```

## Verification Checklist

Use this checklist to verify virtual audio is working correctly:

- [ ] Kernel module exists: `find /lib/modules/$(uname -r) -name usb_f_uac2.ko`
- [ ] Module is loaded: `lsmod | grep uac2`
- [ ] Marker files created: `ls /boot/usb.audio*`
- [ ] UAC2 functions configured: `ls /sys/kernel/config/usb_gadget/g0/functions/ | grep uac2`
- [ ] Functions linked: `ls /sys/kernel/config/usb_gadget/g0/configs/c.1/ | grep uac2`
- [ ] ALSA cards present: `cat /proc/asound/cards`
- [ ] amixer works: `amixer scontrols`
- [ ] Audio devices appear on remote host

## Technical Details

### USB Audio Class 2.0

NanoKVM uses UAC2 (USB Audio Class 2.0) which offers:
- Higher sample rates (up to 192kHz)
- Better audio quality
- Lower latency than UAC1
- Native support in modern operating systems

### Audio Configuration

**Audio Input (uac2.usb0):**
- Appears as microphone on remote host
- Actually captures audio FROM remote host TO NanoKVM
- Configuration: 48kHz, stereo, 16-bit

**Audio Output (uac2.usb1):**
- Appears as speaker on remote host  
- Actually plays audio FROM NanoKVM TO remote host
- Configuration: 48kHz, stereo, 16-bit

### Init Script Execution Order

1. `S02modules` - Loads kernel modules (including usb_f_uac2)
2. `S03usbdev` - Configures USB gadget functions (including UAC2 devices)
3. `S95nanokvm` - Starts NanoKVM application

## References

- [Linux USB Gadget UAC2 Documentation](https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html)
- [ALSA Project](https://www.alsa-project.org/)
- [USB Audio Class 2.0 Specification](https://www.usb.org/document-library/audio-devices-rev-30-and-adopters-agreement)

## Support

If you encounter issues not covered in this guide:

1. Check system logs: `dmesg | grep -i uac2`
2. Check USB gadget logs: `dmesg | grep -i gadget`
3. Visit [NanoKVM FAQ](https://wiki.sipeed.com/hardware/en/kvm/NanoKVM/faq.html)
4. Join [Discord Community](https://discord.gg/V4sAZ9XWpN)
5. Contact: support@sipeed.com
