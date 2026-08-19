# PizzaScript

Herramienta en Lua para [Cherax](https://cherax.online), un mod menu de
GTA V. Un solo archivo (`src/PizzaScript.lua`) que va creciendo por
apartados con el tiempo — por ahora, un menú de perfil de jugador.

## Apartado actual: perfil de jugador

- **Modo historia**: personaje que estás jugando ahora (Michael/Franklin/
  Trevor), % de historia completada, desglose de misiones/minijuegos/tareas
  secundarias, estadísticas por personaje.
- **Cuenta online**: si has iniciado sesión, apodo de Social Club, si tienes
  cuenta de Social Club, si eres host de la sesión.
- Guarda todo en `PizzaScript_Profiles\perfil_<tu_apodo_online>.txt`.

**Qué NO muestra, a propósito**: no existe forma verificada de leer un flag
de "personaje desbloqueado" ni una lista de misiones concretas completadas
ni el dinero/rango de GTA Online. Ver la cabecera de
[`PizzaScript.lua`](src/PizzaScript.lua) para el detalle de qué está
confirmado y qué no — se prefiere decir "no disponible" antes que inventar
un dato o un hash sin verificar.

## Instalación

Descarga sólo
[`PizzaScript.lua`](https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/src/PizzaScript.lua)
(clic derecho → Guardar como) y colócalo en `Documentos\Cherax\Lua\`. Ábrelo
y ejecútalo desde la pestaña **Lua Editor** de Cherax (dentro de *Lua
Content*). Busca la pestaña **PizzaScript**:

1. **Cargar perfil (modo historia)** — mientras estás en modo offline.
2. **Cargar perfil (cuenta online)** — una vez unido a GTA Online.
3. **Guardar perfil** — combina lo capturado y lo escribe a disco.

El toggle **Mostrar panel en pantalla** dibuja un panel con la información
capturada. El archivo se autoactualiza (comprueba versión, descarga,
verifica con `load()` antes de sustituirse, guarda copia de seguridad) — ver
la categoría "Actualizador" en la propia pestaña.

## Desarrollo

`sim/` es un simulador mínimo de la API de Cherax para probar fuera del
juego con un Lua 5.4 normal:

```bash
lua sim/run_tests.lua
```

Comprueba que `PizzaScript.lua` compila y ejercita el auto-actualizador
completo (descarga, verificación con `load()`, respaldo, los dos frenos de
las esperas de red) sin tocar disco real ni red real. El workflow de
`.github/workflows/validate.yml` corre lo mismo en cada push.

Reglas de fondo del proyecto, para cualquier apartado nuevo que se añada:

- Nada de hashes o nombres de natives inventados — si algo no está
  verificado contra una fuente real, se dice claro en vez de suponerlo.
- Las natives sólo se llaman una vez armado el script (barrera de hilo):
  tocarlas antes cierra GTA sin dejar rastro en el log.
- Toda espera de red lleva dos frenos independientes (tiempo + tope de
  iteraciones), nunca uno solo.
- Nunca se sustituye un archivo en disco sin verificar antes que el
  contenido nuevo compila.

## Créditos

Los hashes de las natives de GTA V vienen de
[`SATTY91/Cherax-Lua-API-Documentation`](https://github.com/SATTY91/Cherax-Lua-API-Documentation)
y de [LCPDFR NativeDB](https://www.lcpdfr.com/resources/nativedb/index/).
