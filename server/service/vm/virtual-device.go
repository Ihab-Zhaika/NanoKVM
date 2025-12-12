package vm

import (
	"errors"
	"fmt"
	"os"
	"os/exec"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"

	"NanoKVM-Server/proto"
	"NanoKVM-Server/service/hid"
)

const (
	virtualNetwork    = "/boot/usb.rndis0"
	virtualMedia      = "/boot/usb.disk0"
	virtualDisk       = "/boot/usb.disk1"
	virtualAudioIn    = "/boot/usb.audio_in"
	virtualAudioOut   = "/boot/usb.audio_out"
	virtualAudioFile  = "/boot/usb.audio"
)

var (
	mountNetworkCommands = []string{
		"touch /boot/usb.rndis0",
		"/etc/init.d/S03usbdev stop",
		"/etc/init.d/S03usbdev start",
	}

	unmountNetworkCommands = []string{
		"/etc/init.d/S03usbdev stop",
		"rm -rf /sys/kernel/config/usb_gadget/g0/configs/c.1/rndis.usb0",
		"rm /boot/usb.rndis0",
		"/etc/init.d/S03usbdev start",
	}

	mountMediaCommands = []string{
		"touch /boot/usb.disk0",
		"/etc/init.d/S03usbdev stop",
		"/etc/init.d/S03usbdev start",
	}

	unmountMediaCommands = []string{
		"/etc/init.d/S03usbdev stop",
		"rm -rf /sys/kernel/config/usb_gadget/g0/configs/c.1/mass_storage.disk0",
		"rm /boot/usb.disk0",
		"/etc/init.d/S03usbdev start",
	}

	mountDiskCommands = []string{
		"touch /boot/usb.disk1",
		"/etc/init.d/S03usbdev stop",
		"/etc/init.d/S03usbdev start",
	}

	unmountDiskCommands = []string{
		"/etc/init.d/S03usbdev stop",
		"rm -rf /sys/kernel/config/usb_gadget/g0/configs/c.1/mass_storage.disk1",
		"rm /boot/usb.disk1",
		"/etc/init.d/S03usbdev start",
	}

	// Virtual Audio Input (NanoInput) - microphone from remote host's perspective
	mountAudioInCommands = []string{
		"touch /boot/usb.audio_in",
		"/etc/init.d/S03usbdev stop",
		"/etc/init.d/S03usbdev start",
	}

	unmountAudioInCommands = []string{
		"/etc/init.d/S03usbdev stop",
		"rm -rf /sys/kernel/config/usb_gadget/g0/configs/c.1/uac2.usb0",
		"rm /boot/usb.audio_in",
		"/etc/init.d/S03usbdev start",
	}

	// Virtual Audio Output (NanoOutput) - speaker from remote host's perspective
	mountAudioOutCommands = []string{
		"touch /boot/usb.audio_out",
		"/etc/init.d/S03usbdev stop",
		"/etc/init.d/S03usbdev start",
	}

	unmountAudioOutCommands = []string{
		"/etc/init.d/S03usbdev stop",
		"rm -rf /sys/kernel/config/usb_gadget/g0/configs/c.1/uac2.usb1",
		"rm /boot/usb.audio_out",
		"/etc/init.d/S03usbdev start",
	}
)

func (s *Service) GetVirtualDevice(c *gin.Context) {
	var rsp proto.Response

	network, _ := isDeviceExist(virtualNetwork)
	media, _ := isDeviceExist(virtualMedia)
	disk, _ := isDeviceExist(virtualDisk)
	audioEnabled, _ := isDeviceExist(virtualAudioFile)
	audioIn, _ := isDeviceExist(virtualAudioIn)
	audioOut, _ := isDeviceExist(virtualAudioOut)

	rsp.OkRspWithData(c, &proto.GetVirtualDeviceRsp{
		Network:      network,
		Media:        media,
		Disk:         disk,
		AudioEnabled: audioEnabled,
		AudioIn:      audioIn,
		AudioOut:     audioOut,
	})
	log.Debugf("get virtual device success")
}

func (s *Service) UpdateVirtualDevice(c *gin.Context) {
	var req proto.UpdateVirtualDeviceReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid argument")
		return
	}

	var device string
	var commands []string

	switch req.Device {
	case "network":
		device = virtualNetwork

		exist, _ := isDeviceExist(device)
		if !exist {
			commands = mountNetworkCommands
		} else {
			commands = unmountNetworkCommands
		}
	case "media":
		device = virtualMedia

		exist, _ := isDeviceExist(device)
		if !exist {
			commands = mountMediaCommands
		} else {
			commands = unmountMediaCommands
		}
	case "disk":
		device = virtualDisk

		exist, _ := isDeviceExist(device)
		if !exist {
			commands = mountDiskCommands
		} else {
			commands = unmountDiskCommands
		}
	case "audioIn":
		device = virtualAudioIn

		exist, _ := isDeviceExist(device)
		if !exist {
			commands = mountAudioInCommands
		} else {
			commands = unmountAudioInCommands
		}
	case "audioOut":
		device = virtualAudioOut

		exist, _ := isDeviceExist(device)
		if !exist {
			commands = mountAudioOutCommands
		} else {
			commands = unmountAudioOutCommands
		}
	default:
		rsp.ErrRsp(c, -2, "invalid arguments")
		return
	}

	h := hid.GetHid()
	h.Lock()
	h.CloseNoLock()
	defer func() {
		h.OpenNoLock()
		h.Unlock()
	}()

	for _, command := range commands {
		err := exec.Command("sh", "-c", command).Run()
		if err != nil {
			rsp.ErrRsp(c, -3, "operation failed")
			return
		}
	}

	on, _ := isDeviceExist(device)
	rsp.OkRspWithData(c, &proto.UpdateVirtualDeviceRsp{
		On: on,
	})

	log.Debugf("update virtual device %s success", req.Device)
}

func isDeviceExist(device string) (bool, error) {
	_, err := os.Stat(device)

	if err == nil {
		return true, nil
	}

	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}

	log.Errorf("check file %s err: %s", device, err)
	return false, err
}

func (s *Service) EnableVirtualAudio(c *gin.Context) {
	var rsp proto.Response

	// Enable audio feature by creating marker file
	file, err := os.Create(virtualAudioFile)
	if err != nil {
		log.Errorf("failed to create audio file: %s", err)
		rsp.ErrRsp(c, -1, "failed to enable virtual audio")
		return
	}
	file.Close()

	rsp.OkRsp(c)
	log.Debug("enable virtual audio")
}

func (s *Service) DisableVirtualAudio(c *gin.Context) {
	var rsp proto.Response

	h := hid.GetHid()
	h.Lock()
	h.CloseNoLock()
	defer func() {
		h.OpenNoLock()
		h.Unlock()
	}()

	// Disable audio feature - unmount devices if mounted and remove marker files
	audioInMounted, _ := isDeviceExist(virtualAudioIn)
	audioOutMounted, _ := isDeviceExist(virtualAudioOut)

	// Unmount audio devices if they are mounted
	if audioInMounted || audioOutMounted {
		for _, command := range unmountAudioInCommands {
			_ = exec.Command("sh", "-c", command).Run()
		}
		for _, command := range unmountAudioOutCommands {
			_ = exec.Command("sh", "-c", command).Run()
		}
	}

	if err := os.Remove(virtualAudioFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Warnf("failed to remove audio file: %s", err)
	}
	if err := os.Remove(virtualAudioIn); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Warnf("failed to remove audio_in file: %s", err)
	}
	if err := os.Remove(virtualAudioOut); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Warnf("failed to remove audio_out file: %s", err)
	}

	rsp.OkRsp(c)
	log.Debug("disable virtual audio")
}

func (s *Service) GetAudioLevels(c *gin.Context) {
	var rsp proto.Response

	audioInLevel := 0
	audioOutLevel := 0

	// Check if audio devices are mounted
	audioInMounted, _ := isDeviceExist(virtualAudioIn)
	audioOutMounted, _ := isDeviceExist(virtualAudioOut)

	// Get audio input level using amixer (capture)
	if audioInMounted {
		out, err := exec.Command("sh", "-c", "amixer -c 0 sget Capture 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%'").Output()
		if err == nil && len(out) > 0 {
			level := 0
			_, _ = fmt.Sscanf(string(out), "%d", &level)
			audioInLevel = level
		}
	}

	// Get audio output level using amixer (playback)
	if audioOutMounted {
		out, err := exec.Command("sh", "-c", "amixer -c 0 sget Master 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d '%'").Output()
		if err == nil && len(out) > 0 {
			level := 0
			_, _ = fmt.Sscanf(string(out), "%d", &level)
			audioOutLevel = level
		}
	}

	rsp.OkRspWithData(c, &proto.GetAudioLevelsRsp{
		AudioInLevel:  audioInLevel,
		AudioOutLevel: audioOutLevel,
	})
	log.Debugf("get audio levels: in=%d, out=%d", audioInLevel, audioOutLevel)
}
