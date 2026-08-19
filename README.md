# PizzaScript — PizzaGames

Framework de minijuegos en Lua para [Cherax](https://cherax.online), un mod
menu de GTA V. Cuatro minijuegos de un solo jugador, cada uno construye su
propio escenario con props:

| Categoría   | Minijuego            | Escenario                                     |
|-------------|-----------------------|------------------------------------------------|
| Conducción  | Circuito              | 4 trazados generados con calzada y vallas       |
| Combate     | Arena de oleadas      | Muro circular + oleadas de NPCs                 |
| Habilidad   | Parkour ascendente    | Torre de plataformas                            |
| Supervivencia | Rey de la colina    | Zona delimitada + generación periódica          |

Un solo jugador, siempre. Ver [`docs/PROYECTO.md`](docs/PROYECTO.md) sección
10 para el porqué.

## Instalación

**Opción rápida — un solo archivo.** Descarga sólo
[`PizzaGames.lua`](https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/src/PizzaGames.lua)
(clic derecho → Guardar como) y colócalo en `Documentos\Cherax\Lua\`. Ábrelo
y ejecútalo desde la pestaña **Lua Editor** de Cherax (dentro de *Lua
Content*): si no encuentra los demás módulos en disco, los descarga él solo
desde este repositorio antes de arrancar, verificando que cada uno compila
antes de guardarlo. Sólo tarda unos segundos y sólo pasa la primera vez —
después arranca directamente con lo que ya tiene en disco.

**Opción manual — todo el árbol.** Copia todo el contenido de
[`src/`](src) a `Documentos\Cherax\Lua\`, conservando la estructura:
- `src/PizzaGames.lua` → `Documentos\Cherax\Lua\PizzaGames.lua`
- `src/PizzaScript/*.lua` → `Documentos\Cherax\Lua\PizzaScript\*.lua`

En cualquiera de los dos casos, después:
1. Ejecuta **sólo** `PizzaGames.lua` desde el Lua Editor. Él carga el resto
   de módulos por su cuenta y registra cada intento en el log de Cherax.
2. Busca la pestaña **PizzaGames** en Lua Content.

Si el Lua Editor no lista scripts dentro de subcarpetas, `PizzaGames.lua`
puede ir suelto en `Lua\` con los módulos en `Lua\PizzaScript\`: el cargador
prueba varias ubicaciones automáticamente.

## Auto-actualización

La pestaña PizzaGames incluye una categoría **Actualizaciones**:

- **Buscar actualizaciones** — comprueba la versión publicada en este repo.
- **Actualizar ahora** — sólo aparece útil cuando hay una versión nueva.
  Descarga cada archivo y **comprueba que compila antes de tocar nada en
  disco**; si cualquiera falla, no se sustituye ningún archivo. Guarda una
  copia de la versión anterior.
- **Revertir a versión anterior** — restaura esa copia.
- El toggle **Buscar al iniciar** (activado por defecto) comprueba
  automáticamente al cargar el script.

Los cambios se aplican al disco; hace falta **recargar `PizzaGames.lua`**
desde el Lua Editor para que surtan efecto (no hay sustitución de código en
caliente).

Si no hay conexión, el script arranca igual con lo que ya tenga en disco.

## Si algo falla

Todo error queda en el log de Cherax con el prefijo `[PizzaGames]`. La
pestaña tiene un panel de salud (semáforo OK / AVISO / FALLO) y un botón
**Diagnóstico completo** que vuelca todo el estado al log para copiar y
pegar. Si el script se queda atascado, el botón **REINICIO DE EMERGENCIA**
lo desbloquea sin tener que recargar GTA.

## Desarrollo

`docs/PROYECTO.md` documenta la arquitectura completa, la API de Cherax
verificada y las trampas ya encontradas (crashes reales, no hipotéticos).
Antes de tocar código, léelo.

`sim/` es un simulador mínimo de la API de Cherax para probar fuera del
juego con un Lua 5.4 normal:

```bash
lua sim/run_tests.lua
```

Comprueba que los 9 archivos compilan y ejercita el auto-actualizador
completo (descarga, verificación, respaldo, reversión, los dos frenos de
las esperas de red) sin tocar disco real ni red real. El workflow de
`.github/workflows/validate.yml` corre lo mismo en cada push.

## Créditos

Los hashes de las natives de GTA V vienen de
[`SATTY91/Cherax-Lua-API-Documentation`](https://github.com/SATTY91/Cherax-Lua-API-Documentation).
