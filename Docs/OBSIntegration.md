# OBS Integration

OBSPhoneCam usa obs-websocket v5.

## Comandos planeados

- GetVersion
- GetSceneList
- GetCurrentProgramScene
- SetCurrentProgramScene
- GetRecordStatus
- StartRecord
- StopRecord
- GetStreamStatus
- StartStream
- StopStream
- GetReplayBufferStatus
- StartReplayBuffer
- StopReplayBuffer
- SaveReplayBuffer
- GetInputList
- SetSceneItemEnabled
- GetSceneItemList
- TakeSourceScreenshot

## Proxy recomendado

El iPhone no debería guardar directamente el password de OBS si no hace falta. La Mac puede actuar como proxy:

iPhone -> Mac Hub -> OBS WebSocket

Esto centraliza autenticación, estado y logs.
