import { useEffect, useState, useRef } from 'react';
import { Switch, Tooltip, Progress } from 'antd';
import { CircleAlertIcon, Mic, Volume2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/virtual-device.ts';

export const VirtualAudio = () => {
  const { t } = useTranslation();

  const [isEnabled, setIsEnabled] = useState(false);
  const [isAudioInOn, setIsAudioInOn] = useState(false);
  const [isAudioOutOn, setIsAudioOutOn] = useState(false);
  const [loading, setLoading] = useState(''); // '' | 'enabled' | 'audioIn' | 'audioOut'
  const [audioInLevel, setAudioInLevel] = useState(0);
  const [audioOutLevel, setAudioOutLevel] = useState(0);
  const intervalRef = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    api.getVirtualDevice().then((rsp) => {
      if (rsp.code !== 0) {
        return;
      }

      setIsEnabled(rsp.data.audioEnabled);
      setIsAudioInOn(rsp.data.audioIn);
      setIsAudioOutOn(rsp.data.audioOut);
    });
  }, []);

  // Poll audio levels when devices are active
  useEffect(() => {
    if (isAudioInOn || isAudioOutOn) {
      // Start polling audio levels
      const fetchLevels = () => {
        api.getAudioLevels().then((rsp) => {
          if (rsp.code === 0) {
            setAudioInLevel(rsp.data.audioInLevel);
            setAudioOutLevel(rsp.data.audioOutLevel);
          }
        });
      };
      
      fetchLevels(); // Fetch immediately
      intervalRef.current = setInterval(fetchLevels, 500); // Poll every 500ms
    } else {
      // Stop polling and reset levels
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
      setAudioInLevel(0);
      setAudioOutLevel(0);
    }

    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
      }
    };
  }, [isAudioInOn, isAudioOutOn]);

  function toggleEnabled() {
    if (loading) return;
    setLoading('enabled');

    const func = isEnabled ? api.disableVirtualAudio() : api.enableVirtualAudio();

    func
      .then((rsp) => {
        if (rsp.code !== 0) {
          return;
        }

        setIsEnabled(!isEnabled);
        if (isEnabled) {
          // When disabling, also reset the sub-device states
          setIsAudioInOn(false);
          setIsAudioOutOn(false);
        }
      })
      .finally(() => {
        setLoading('');
      });
  }

  function updateDevice(device: 'audioIn' | 'audioOut') {
    if (loading) return;
    setLoading(device);

    api
      .updateVirtualDevice(device)
      .then((rsp) => {
        if (rsp.code !== 0) {
          return;
        }

        switch (device) {
          case 'audioIn':
            setIsAudioInOn(rsp.data.on);
            break;
          case 'audioOut':
            setIsAudioOutOn(rsp.data.on);
            break;
        }
      })
      .finally(() => {
        setLoading('');
      });
  }

  return (
    <>
      <div className="flex items-center justify-between">
        <div className="flex flex-col">
          <div className="flex items-center space-x-2">
            <span>{t('settings.device.virtualAudio.title')}</span>

            <Tooltip
              title={t('settings.device.virtualAudio.tip')}
              className="cursor-pointer"
              placement="bottom"
              overlayStyle={{ maxWidth: '300px' }}
            >
              <CircleAlertIcon size={15} />
            </Tooltip>
          </div>
          <span className="text-xs text-neutral-500">
            {t('settings.device.virtualAudio.description')}
          </span>
        </div>

        <Switch
          checked={isEnabled}
          loading={loading === 'enabled'}
          onChange={toggleEnabled}
        />
      </div>

      {isEnabled && (
        <>
          <div className="flex items-center justify-between pl-4">
            <div className="flex flex-col flex-1 mr-4">
              <div className="flex items-center space-x-2">
                <Mic size={14} className="text-neutral-400" />
                <span>{t('settings.device.virtualAudio.nanoInput')}</span>
              </div>
              <span className="text-xs text-neutral-500">
                {t('settings.device.virtualAudio.nanoInputDesc')}
              </span>
              {isAudioInOn && (
                <div className="mt-2">
                  <Progress
                    percent={audioInLevel}
                    size="small"
                    showInfo={false}
                    strokeColor={audioInLevel > 80 ? '#ff4d4f' : audioInLevel > 50 ? '#faad14' : '#52c41a'}
                  />
                </div>
              )}
            </div>

            <Switch
              checked={isAudioInOn}
              loading={loading === 'audioIn'}
              onChange={() => updateDevice('audioIn')}
            />
          </div>

          <div className="flex items-center justify-between pl-4">
            <div className="flex flex-col flex-1 mr-4">
              <div className="flex items-center space-x-2">
                <Volume2 size={14} className="text-neutral-400" />
                <span>{t('settings.device.virtualAudio.nanoOutput')}</span>
              </div>
              <span className="text-xs text-neutral-500">
                {t('settings.device.virtualAudio.nanoOutputDesc')}
              </span>
              {isAudioOutOn && (
                <div className="mt-2">
                  <Progress
                    percent={audioOutLevel}
                    size="small"
                    showInfo={false}
                    strokeColor={audioOutLevel > 80 ? '#ff4d4f' : audioOutLevel > 50 ? '#faad14' : '#52c41a'}
                  />
                </div>
              )}
            </div>

            <Switch
              checked={isAudioOutOn}
              loading={loading === 'audioOut'}
              onChange={() => updateDevice('audioOut')}
            />
          </div>
        </>
      )}
    </>
  );
};
