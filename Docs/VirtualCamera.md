# Virtual Camera

El módulo está preparado para CoreMediaIO Camera Extension.

## Por qué skeleton

Una cámara virtual real en macOS requiere:

- Target de System Extension/Camera Extension.
- Signing correcto.
- Entitlements.
- Instalación/autorización del usuario.
- Integración con `CMIOExtensionProvider` y fuentes de sample buffers.

## Plan

1. Crear target desde template oficial de Xcode.
2. Implementar provider/device/source.
3. Conectar `SampleBufferProvider` del Mac Hub.
4. Exponer `OBS Phone Cam 1`, `OBS Phone Cam 2`, etc.
