import { useEffect, useState } from 'react';
import { Switch, Tooltip } from 'antd';
import { CircleAlertIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/virtual-device.ts';

export const VirtualAudio = () => {
  const { t } = useTranslation();

  const [isEnabled, setIsEnabled] = useState(false);
  const [isAudioInOn, setIsAudioInOn] = useState(false);
  const [isAudioOutOn, setIsAudioOutOn] = useState(false);
  const [loading, setLoading] = useState(''); // '' | 'enabled' | 'audioIn' | 'audioOut'

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

  function toggleEnabled() {
    if (loading) return;
    setLoading('enabled');

    api
      .setVirtualAudio(!isEnabled)
      .then((rsp) => {
        if (rsp.code !== 0) {
          return;
        }

        setIsEnabled(rsp.data.enabled);
        setIsAudioInOn(rsp.data.audioIn);
        setIsAudioOutOn(rsp.data.audioOut);
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
            <div className="flex flex-col">
              <span>{t('settings.device.virtualAudio.nanoInput')}</span>
              <span className="text-xs text-neutral-500">
                {t('settings.device.virtualAudio.nanoInputDesc')}
              </span>
            </div>

            <Switch
              checked={isAudioInOn}
              loading={loading === 'audioIn'}
              onChange={() => updateDevice('audioIn')}
            />
          </div>

          <div className="flex items-center justify-between pl-4">
            <div className="flex flex-col">
              <span>{t('settings.device.virtualAudio.nanoOutput')}</span>
              <span className="text-xs text-neutral-500">
                {t('settings.device.virtualAudio.nanoOutputDesc')}
              </span>
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
