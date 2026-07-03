# Setup

## Requisitos

- macOS 14+
- iOS 17+
- Xcode 15+
- OBS Studio con WebSocket habilitado
- XcodeGen

## Comandos

```bash
brew install xcodegen
cd OBSPhoneCam
xcodegen generate
open OBSPhoneCam.xcodeproj
```

## OBS

- Puerto recomendado: 4455
- Host local desde Mac: 127.0.0.1
- Habilitar password.

## iOS

- Aceptar permisos de cámara, micrófono y red local.
- Configurar IP/host de la Mac.

## macOS

- Iniciar app Mac Hub.
- Conectar OBS.
- Iniciar listener de dispositivos en la siguiente iteración si no se autoejecuta.
