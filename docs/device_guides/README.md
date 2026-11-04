# Guías de inicialización de los dispositivos

Lo que abre el botón «i» junto a cada dispositivo en la sala de espera de
lab_protocol_timer. Una guía por tipo de sensor (la clave del tipo en el
editor de sensores):

| Tipo | Guía |
|---|---|
| `ax3`, `ax6` | [axivity.md](axivity.md) |
| `matrix` | [matrix.md](matrix.md) |
| `sens` | [sens.md](sens.md) |
| `polar_h10` | [polar_h10.md](polar_h10.md) |
| `verity_sense` | [verity_sense.md](verity_sense.md) |
| `senswear` | [senswear.md](senswear.md) |

Cada estudio puede usar las suyas sin recompilar: un archivo
`guias_dispositivos/<tipo>.md` dentro de la carpeta madre de las sesiones
(por ejemplo `guias_dispositivos/ax6.md`) sustituye a la guía de la app
para ese tipo.

Se escriben en Markdown sencillo: títulos (`#`, `##`, `###`), párrafos,
listas numeradas (`1.`) y con guiones (`-`, también sangradas) y
**negrita**. Basadas en los protocolos 14 a 17 de RUN4HEALTH (versión 13,
03/11/2026); lo que el fabricante no confirma va como [PENDIENTE].
