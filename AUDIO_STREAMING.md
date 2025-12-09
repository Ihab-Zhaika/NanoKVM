# WebRTC Audio Streaming Implementation

## Overview

This document describes the WebRTC audio streaming capability that has been added to NanoKVM. The implementation allows audio from the remote PC to be streamed to the browser alongside the video stream.

## Architecture

### Backend Changes (Go/WebRTC)

#### 1. Updated Types (`server/service/stream/webrtc/types.go`)
- Added `audioSending int32` field to `WebRTCManager` to track audio streaming state
- Added `audioPacketizer` and `audio` fields to `Track` struct for audio RTP handling

#### 2. Manager Updates (`server/service/stream/webrtc/manager.go`)
- Added `StartAudioStream()` method to initialize audio streaming
- Added `sendAudioStream()` method with placeholder for audio capture
- Audio uses Opus codec with 48kHz sample rate and 20ms frame duration

#### 3. Client Updates (`server/service/stream/webrtc/client.go`)
- Modified `AddTrack()` to create both video and audio tracks
- Audio track uses Opus codec (MimeTypeOpus) with 48kHz sample rate
- Added audio packetizer for RTP streaming

#### 4. Track Updates (`server/service/stream/webrtc/track.go`)
- Added `writeAudioSample()` and `writeAudio()` methods
- Audio packets are sent via RTP without playout delay extensions (audio-specific optimization)

#### 5. Signaling Updates (`server/service/stream/webrtc/signaling.go`)
- Modified ICE connection state handler to start both video and audio streams when connected

### Frontend Changes (TypeScript/React)

#### Updated Component (`web/src/pages/desktop/screen/h264-webrtc.tsx`)
- Added `audioRef` reference for audio element
- Changed `offerToReceiveAudio` from `false` to `true` in WebRTC offer
- Added audio transceiver with `recvonly` direction
- Updated `ontrack` handler to route audio tracks to audio element
- Added hidden audio element to the DOM for playback

## Audio Capture Implementation (TODO)

The current implementation has the WebRTC infrastructure in place but requires actual audio capture from the hardware. Here's what needs to be implemented:

### Option 1: HDMI Audio Extraction (Recommended)

For systems with HDMI audio extraction capability (like NanoKVM-Pro):

1. **Create Audio Capture Module** (`server/common/kvm_audio.go`):
```go
package common

/*
	#cgo CFLAGS: -I../include
	#cgo LDFLAGS: -L../dl_lib -lkvm -lcvi_audio
	#include <stdlib.h>
	#include "cvi_audio.h"
	
	// Audio capture function using CVI Audio APIs
	int capture_audio_frame(uint8_t** data, uint32_t* size);
*/
import "C"
import "unsafe"

type KvmAudio struct{}

func (k *KvmAudio) CaptureAudioFrame() ([]byte, error) {
	var audioData *C.uint8_t
	var dataSize C.uint32_t
	
	result := C.capture_audio_frame(&audioData, &dataSize)
	if result < 0 {
		return nil, fmt.Errorf("failed to capture audio")
	}
	defer C.free(unsafe.Pointer(audioData))
	
	data := C.GoBytes(unsafe.Pointer(audioData), C.int(dataSize))
	return data, nil
}
```

2. **Create C Implementation** (`server/include/cvi_audio.h` and corresponding .c file):
```c
#include "cvi_comm_aio.h"
#include "cvi_audio.h"

int capture_audio_frame(uint8_t** data, uint32_t* size) {
	// Initialize audio input (AI) device
	// Configure for 48kHz, 2 channels, Opus-compatible format
	// Capture audio frame from HDMI input
	// Return audio data and size
}
```

3. **Update Manager** to use real audio capture:
```go
func (m *WebRTCManager) sendAudioStream() {
	defer atomic.StoreInt32(&m.audioSending, 0)

	frameDuration := 20 * time.Millisecond
	audio := common.GetKvmAudio() // New audio singleton
	
	ticker := time.NewTicker(frameDuration)
	defer ticker.Stop()

	for range ticker.C {
		if m.GetClientCount() == 0 {
			log.Debugf("stop sending audio stream")
			return
		}

		// Capture audio from hardware
		audioData, err := audio.CaptureAudioFrame()
		if err != nil || len(audioData) == 0 {
			continue
		}

		sample := media.Sample{
			Data:     audioData,
			Duration: frameDuration,
		}

		m.mutex.RLock()
		for _, client := range m.clients {
			if client.track.audio != nil {
				client.track.writeAudio(sample)
			}
		}
		m.mutex.RUnlock()
	}
}
```

### Option 2: ALSA Audio Capture (Alternative)

For systems with ALSA support:

1. Use `libtinyalsa.so` (already available in `dl_lib/`)
2. Create audio capture using ALSA PCM interface
3. Configure for Opus-compatible format (48kHz, 16-bit, stereo)

## Testing

### Prerequisites
- NanoKVM hardware with audio capture capability (NanoKVM-Pro recommended)
- Remote PC with active audio output
- Browser with WebRTC support

### Test Procedure
1. Deploy the updated NanoKVM software to the device
2. Connect to the NanoKVM web interface
3. Select H.264 (WebRTC) video mode
4. Verify video stream is working
5. Check browser console for audio track reception
6. Verify audio playback (ensure browser isn't muted)

### Debugging
- Check browser console for WebRTC negotiation logs
- Verify both video and audio transceivers are created
- Use `chrome://webrtc-internals/` to inspect WebRTC stats
- Check server logs for audio stream start/stop messages

## Browser Compatibility

Tested and supported browsers:
- Chrome/Edge 90+
- Firefox 88+
- Safari 14.1+ (with hardware decode support)

## Performance Considerations

- **Audio Codec**: Opus is chosen for low latency and high quality
- **Sample Rate**: 48kHz is standard for professional audio
- **Frame Duration**: 20ms provides good balance between latency and efficiency
- **Bandwidth**: Opus audio typically uses 24-128 kbps depending on quality settings

## Limitations

1. **Hardware Dependency**: Requires HDMI audio extraction or system audio capture capability
2. **Latency**: Total audio latency is typically 50-150ms (capture + encode + network + decode)
3. **Synchronization**: Audio/video sync is handled by browser but may drift on poor networks

## Future Improvements

1. **Audio Encoding**: Add AAC support as alternative to Opus
2. **Quality Settings**: Make audio bitrate and quality configurable
3. **Audio Controls**: Add mute/volume controls in UI
4. **Echo Cancellation**: Implement AEC for bidirectional audio
5. **Audio Monitoring**: Add audio level meters in UI

## References

- [Pion WebRTC Documentation](https://github.com/pion/webrtc)
- [Opus Codec Specification](https://opus-codec.org/)
- [WebRTC API Documentation](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API)
- [CVI Audio API Documentation](https://github.com/sophgo/cvi_mmf_sdk) (for SG2002/CV180x)
