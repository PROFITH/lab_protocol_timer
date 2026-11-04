# Axivity AX3 y AX6: inicializar

Se programan con **OmGui** en el ordenador del laboratorio. El sensor copia la hora del ordenador al programarlo.

## Antes de empezar

1. Comprueba que el ordenador está en hora y en la zona horaria del estudio (Madrid).
2. Batería: no entregues un sensor por debajo del 85 % (mejor por encima del 95 %). Los de vida libre, al 100 % justo antes de programarlos. Carga completa en unas 2 h.

## Programar la grabación

1. Conecta el sensor directamente al ordenador o a un hub USB con alimentación propia. El LED se queda en ámbar (cargando) o blanco (cargado) pulsando despacio y el sensor aparece en el **Device Browser** de OmGui.
   - Si el LED queda verde fijo, el ordenador no lo reconoce: prueba otro cable o puerto.
2. Mira la batería en el Device Browser. Si el sensor tiene datos, comprueba que ya están descargados y copiados y pulsa **Clear** (no se puede deshacer).
3. Pulsa **Record** y rellena:
   - **Recording Session ID:** el ID del participante.
   - **Sampling Frequency:** 100 Hz.
   - **Sampling Range:** AX3 ±8 g; AX6 ±16 g.
   - **Gyro (± dps), solo AX6:** 2000.
   - **Cuándo:** desmarca «Immediately on Disconnect» y usa **Interval** con Start y Stop (inicio 1 h antes de la cita; fin 8 h después en el juego de laboratorio; los AX6 de vida libre, hasta el día 8 más un día).
   - **Study y Subject Meta Data:** estudio, visita y ubicación (por ejemplo «D0 muñeca no dominante»). Sin nombre ni datos personales.
   - **Flash during recording:** activado, para ver con el LED verde que graba.
   - **Unpacked data:** desactivado.
4. Lee los avisos de la zona **Notes** (por ejemplo, si la duración no cabe) y pulsa **OK**.
5. Espera a que OmGui termine antes de desconectar. Programa los sensores de uno en uno. No desconectes nunca durante una descarga, un borrado o una actualización de firmware.
6. Escribe su número de serie aquí, en la sala de espera, y mételo en su bolsa etiquetada.

## Comprobar que graba

1. Con «Flash during recording», a partir de la hora de inicio el LED parpadea en verde.
2. Sin esa opción el LED está apagado mientras espera y mientras graba: es normal. La comprobación es el intervalo que muestra el Device Browser antes de desconectar.
3. Un destello azul muy breve: sin configurar o grabación terminada. Un destello rojo muy breve: batería baja o grabación cortada; apúntalo como incidencia.

## A tener en cuenta

- AX6 con giroscopio a 100 Hz: entre 7 y 9 días de batería. Del día 0 al día 8 puede no llegar.
- El reloj no cambia con el horario de verano y se desvía unos ±2 s al día: por eso hay saltos de sincronización al principio y al final de cada visita.
- No cambies nunca el ID del dispositivo en OmGui: anula la garantía.
