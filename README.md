# JBL EON Control (macOS)

Controla desde tu Mac, por Bluetooth, las bocinas JBL EON700 (EON710, EON712 y EON715).

> Proyecto personal no oficial. No está afiliado, patrocinado ni respaldado por JBL ni por HARMAN. JBL y EON son marcas de sus respectivos dueños. Úsalo bajo tu propio riesgo.

## Funciones

- Volumen y silencio de maestro, canal 1 y canal 2
- Ecualizador de 8 bandas (ganancia, frecuencia y Q), presets y bass boost
- Ganancia de entrada por canal
- Salida XLR: pass-thru, nivel, filtros, retardos y Pre/Post
- Localizar la bocina y bloquear sus controles físicos
- Varias bocinas a la vez y cuatro temas

La interfaz está en español.

## Requisitos

- macOS 13 o posterior (Apple Silicon o Intel)
- Herramientas de línea de comandos de Xcode (`xcode-select --install`)

## Compilar

```bash
./build.sh
```

Se crea `JBL EON Control.app` en la carpeta del proyecto y los paquetes en `dist/`. La primera vez, macOS pedirá permiso de Bluetooth. La app solo se conecta a las bocinas que elijas.

El registro de actividad se guarda en `~/Library/Logs/JBLEONControl.log`.

## Cómo funciona

Usa CoreBluetooth sobre el servicio GATT `FDDF` de las bocinas. El protocolo se obtuvo por ingeniería inversa y puede cambiar con actualizaciones de firmware. Todo el código está en `Sources/main.swift`.
