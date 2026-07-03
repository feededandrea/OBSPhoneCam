# USB and Apple limitations

## Realidad técnica

iOS no ofrece una API pública general para que una app cualquiera abra un canal USB arbitrario directo hacia una app macOS como si fuera un socket privado.

Por eso este proyecto separa:

- `NetworkStreamTransport`: implementación real inicial por red local.
- `USBPreferredTransport`: abstracción para elegir la mejor ruta disponible.

## Rutas viables

1. Red local Wi-Fi/Ethernet con Bonjour.
2. Interfaz de red por USB/tethering si el sistema la expone.
3. Mac companion con detección/handshake y reconexión robusta.

## Lo que no se hace

- No se usan APIs privadas.
- No se promete soporte App Store con drivers USB custom no autorizados.
- No se bloquea la arquitectura en una ruta imposible.
