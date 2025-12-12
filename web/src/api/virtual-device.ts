import { http } from '@/lib/http.ts';

// get virtual devices status
export function getVirtualDevice() {
  return http.get('/api/vm/device/virtual');
}

// mount/unmount virtual device
export function updateVirtualDevice(device: string) {
  const data = {
    device
  };

  return http.post('/api/vm/device/virtual', data);
}

// enable virtual audio feature
export function enableVirtualAudio() {
  return http.post('/api/vm/device/virtual/audio/enable');
}

// disable virtual audio feature
export function disableVirtualAudio() {
  return http.post('/api/vm/device/virtual/audio/disable');
}

// get audio levels
export function getAudioLevels() {
  return http.get('/api/vm/device/virtual/audio/levels');
}
