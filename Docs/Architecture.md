# Architecture

## Resumen

OBSPhoneCam usa tres capas:

1. **iOS Capture + Remote**: captura AVFoundation, codifica video y manda mensajes/control.
2. **macOS Hub**: recibe streams, mantiene sesiones por dispositivo, controla OBS y coordina cámara virtual/clips.
3. **Shared Protocol**: mensajes codificables, heartbeat, logs, estados y políticas de reconexión.

## Decisión principal

El camino inicial App Store safe usa `Network.framework` y Bonjour. El cable puede ayudar si el sistema expone una interfaz de red por USB/tethering, pero no se depende de APIs privadas.

## State machine

Cada iPhone se maneja como `DeviceSession` independiente:

- disconnected
- connecting
- handshaking
- streaming
- degraded
- reconnecting
- failed

No se mezclan sesiones entre dispositivos.
