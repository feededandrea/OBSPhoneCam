# Reconnection Strategy

## Objetivo

Evitar que una desconexión física parcial deje el sistema colgado.

## Reglas

- Heartbeat periódico.
- Timeout corto.
- Cierre explícito de sockets viejos.
- Rehandshake completo.
- Backoff exponencial con jitter.
- Sesiones independientes por deviceID.
- Cancelación de tasks antes de crear nuevas.
- Logs de cada transición.

## Casos cubiertos

- Se desconecta el iPhone.
- Se desconecta Lightning/USB-C.
- Se desconecta alargue USB.
- Se desconecta hub.
- OBS se cierra.
- Mac Hub queda activo con otros teléfonos.
