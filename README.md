# OBSPhoneCam

Base de proyecto Swift/SwiftUI para convertir un iPhone en cámara/control remoto profesional para OBS usando una app iOS, una app macOS companion y módulos compartidos.

> Estado del ZIP: arquitectura inicial funcional/sólida para iterar. La parte de cámara virtual CoreMediaIO y la automatización de Instagram están incluidas como skeleton realista porque requieren entitlements, configuración de Apple Developer/Meta y validación específica del entorno.

## Qué incluye

- App iOS `OBSPhoneCam iOS`
  - Captura de cámara con `AVFoundation`.
  - Preview local.
  - Estado de conexión.
  - Pantalla de control OBS.
  - Transporte por `Network.framework` preparado para baja latencia.
  - Reconexión por state machine.

- App macOS `OBSCameraHub Mac`
  - Dashboard SwiftUI.
  - Gestión de múltiples dispositivos.
  - Sesiones independientes por iPhone.
  - OBS WebSocket client base.
  - Clips con Replay Buffer.
  - Biblioteca de clips local.
  - Skeleton de cámara virtual.
  - Skeleton de Instagram publishing.

- Shared
  - Modelos compartidos.
  - Protocolo de mensajes.
  - Logger.
  - Codec JSON/binario simple.
  - Reconnect policy.

- Docs
  - Arquitectura.
  - Estrategia de reconexión.
  - Limitaciones USB/iOS.
  - Integración OBS.
  - Cámara virtual.
  - Instagram.
  - Roadmap.

- Tests
  - Codec.
  - Reconnect policy.
  - State machine.
  - OBS request encoding.

## Generar proyecto Xcode

Este ZIP usa `project.yml` para no incluir un `.xcodeproj` gigante generado a mano.

```bash
brew install xcodegen
cd OBSPhoneCam
xcodegen generate
open OBSPhoneCam.xcodeproj
```

## Setup rápido OBS

1. Abrir OBS.
2. Ir a `Tools > WebSocket Server Settings`.
3. Habilitar WebSocket server.
4. Usar puerto `4455`.
5. Configurar password.
6. En la app macOS, poner host `127.0.0.1`, puerto `4455` y el password.

## MVP recomendado

Primero correr:

1. App macOS.
2. Conectar a OBS.
3. App iOS.
4. Probar control de escenas/grabación/replay vía Mac Hub.
5. Recién después activar captura/streaming iPhone → Mac.

## Notas importantes

- No se usan APIs privadas de Apple.
- El transporte USB directo app-to-app por cable no está implementado con APIs privadas. El módulo `USBPreferredTransport` está como abstracción para elegir la mejor ruta disponible y documentar alternativas.
- El camino App Store safe inicial es red local/Bonjour/Network.framework, y si el iPhone expone una interfaz por USB/tethering, puede viajar por esa ruta de red.
- La cámara virtual en macOS requiere CoreMediaIO Camera Extension, signing y entitlements.
- Instagram no se trata como “API mágica de live”. El módulo se limita a publicar/preparar clips usando APIs oficiales o fallback manual.
