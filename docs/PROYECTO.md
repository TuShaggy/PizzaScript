# PizzaGames — Documento de traspaso

Contexto completo para retomar el proyecto en una sesión nueva (Claude Code).
Escrito para que quien lo lea no repita los errores que ya costaron varios
cierres del juego.

---

## 1. Qué es

Framework de minijuegos para **Cherax**, un mod menu de GTA V, escrito en Lua.
Cuatro minijuegos en un solo jugador, cada uno construye su escenario con props:

| Categoría | Minijuego | Escenario |
|---|---|---|
| Conducción | Circuito | 4 trazados generados con calzada y vallas (~212 props) |
| Combate | Arena de oleadas | Muro circular + oleadas de NPCs |
| Habilidad | Parkour ascendente | Torre de plataformas |
| Supervivencia | Rey de la colina | Zona delimitada + generación periódica |

**El autor no programa.** Las explicaciones deben ser claras y el código debe
diagnosticarse solo: cuando algo falla, el log tiene que decir qué y dónde.

---

## 2. Instalación

Los archivos van en `C:\Users\<usuario>\Documents\Cherax\Lua\PizzaScript\`.
Se ejecuta **sólo** `PizzaGames.lua` desde la pestaña *Lua Editor*; él carga el
resto. La pestaña aparece en *Lua Content*.

Si el Lua Editor no lista scripts en subcarpetas, `PizzaGames.lua` puede ir
suelto en `Lua\` y los módulos quedarse en `PizzaScript\`: el cargador prueba
seis ubicaciones y registra cada intento.

---

## 3. Arquitectura

```
PizzaGames.lua            Punto de entrada. Rutas absolutas, carga de módulos,
                           y si no encuentra nada instalado, se los descarga él
                           solo desde el repositorio antes de arrancar.
PizzaGames_Core.lua       Núcleo: log, registro, máquina de estados, adaptador.
PizzaGames_Natives.lua    56 natives por hash + barrera de hilo + punteros.
PizzaGames_Cherax.lua     ÚNICO archivo que conoce la API de Cherax.
PizzaGames_Cinema.lua     Director de cámara, títulos, curvas de aceleración.
PizzaGames_Scene.lua      Modelos, carga por lotes, rastreo de recursos.
PizzaGames_Prefabs.lua    Geometría pura: trazados, calzada, arenas. Lua puro.
PizzaGames_Games.lua      Los cuatro minijuegos.
PizzaGames_Updater.lua    Auto-actualizador: comprueba, descarga y aplica
                           versiones desde GitHub. Único archivo que conoce
                           Curl/FileMgr para ese propósito (misma regla de
                           aislamiento que PizzaGames_Cherax.lua).
```

Regla de oro: **todo lo específico de Cherax vive en `PizzaGames_Cherax.lua`**
(y las natives en `PizzaGames_Natives.lua`). El resto es Lua portable y se puede
probar fuera del juego. `PizzaGames_Updater.lua` sigue la misma regla para
red/disco: nada de eso se filtra a los demás módulos.

### Capas

1. **Diagnóstico** — log con niveles, buffer circular, `PG.try()` con traceback.
2. **Adaptador** — `API.call(capacidad, defecto, ...)`. Dos tablas separadas:
   `bound` (enlaces directos) y `resolved` (por ruta). `probe()` reconstruye
   `resolved` pero **nunca toca `bound`**.
3. **Recursos** — cada entidad creada se rastrea y se libera al parar.
4. **Runtime** — registro de minijuegos, estados IDLE/RUNNING/ENDING.

### Ciclo de un minijuego

```
MODELOS -> PROPS -> INTRO -> JUGANDO -> FIN
```

Ninguna fase bloquea. `on_tick` despacha según la fase.

### Versión del paquete

`PG._VERSION` (en `PizzaGames_Core.lua`) es el número de versión de **todo el
paquete** (los 9 archivos juntos), comparado por el auto-actualizador contra
`version.json` del repo. Antes de la sección 7 de este documento no existía:
cada archivo llevaba su propio número en la cabecera, sin relación entre sí.
Se sube en cada release junto con `version.json`.

---

## 4. API de Cherax: lo verificado

Fuentes: `Documentation.json` (API de clases), el repositorio
`SATTY91/Cherax-Lua-API-Documentation` (natives), y el wiki.

### Interfaz (ImGui de modo inmediato)

```lua
FeatureMgr.AddFeature(hash, nombre, eFeatureType.X, desc, callback, nativeThread)
  -- devuelve Feature, encadenable:
  :SetLimitValues(min,max) :SetDefaultValue(v) :SetSaveable(b)
  :SetNoCallbackOnPress(b) :Reset() :RegisterCallbackTrigger(eCallbackTrigger.OnTick)
  :GetIntValue() :IsToggled() :GetName()

ClickGUI.AddTab(titulo, funcionRender)
ClickGUI.BeginCustomChildWindow(etiqueta) / EndCustomChildWindow()
ClickGUI.RenderFeature(hash)
ImGui.Text(texto)
```

`eFeatureType`: Button, Toggle, SliderInt, SliderFloat, InputInt, InputText,
Combo, List, InputColor3/4, y variantes *Toggle*.

`eCallbackTrigger`: **OnTick**, OnPresent, OnPostPresent, OnPlayerJoin,
OnSessionChange, OnNewVehicle, OnWeaponChange…

### Otros namespaces útiles

```lua
Utils.Joaat(str)                    -- hash
Logger.LogInfo / LogError           -- NO existe LogWarning
GUI.AddToast(titulo, texto, ms, eToastPos.TOP_RIGHT)
Time.GetEpocheMs()                  -- reloj en milisegundos
Script.RegisterLooped(fn) / Script.Yield(ms) / Script.QueueJob(fn)
ShouldUnload() / SetShouldUnload()  -- ciclo de vida del script
FileMgr.GetMenuRootPath() / DoesFileExist / ReadFileContent / WriteFileContent
FileMgr.CreateDir / FindFiles / Unzip
Memory.AllocInt() / WriteInt / ReadInt / Free
GTA.GetLocalPed()                   -- CPed; .Position es un V3
GTA.PointerToHandle(ptr) / HandleToPointer(handle)
GTA.CreateObject(hash,x,y,z,dynamic,isNetworked)
GTA.CreatePed(hash,tipo,x,y,z,heading,isNetworked,autoCleanup)
GTA.SpawnVehicle(...) / GTA.GetGroundZ(x,y)
Natives.InvokeVoid/Int/Bool/Float/String/V3(hash, ...)
Curl.Easy()                         -- ver sección 7
```

**Cherax NO define los namespaces de natives** (`ENTITY`, `CAM`, `HUD`…). Los
crea el archivo `natives-*.lua` oficial, de 585 KB. `PizzaGames_Natives.lua`
incorpora sólo las 56 necesarias con sus hashes extraídos de esa misma fuente.

**Cherax tampoco define ningún parser JSON.** `version.json` (sección 7) se
interpreta con un extractor de patrones propio, no un parser JSON general:
el esquema es fijo (3 claves) y lo controlamos nosotros mismos, así que un
parser completo sería una capacidad que este proyecto no necesita.

---

## 5. Las cinco trampas que ya costaron crashes

Esto es lo más valioso del documento. Cada una viene de un fallo real.

### 5.1 Las natives sólo funcionan en el hilo de script

El cuerpo de un `.lua` se ejecuta al cargarlo, **en otro hilo**. Llamar ahí a
`PLAYER_PED_ID` o `CREATE_CAM` cierra GTA sin dejar rastro en el log.

Por eso `AddFeature` tiene el parámetro `nativeThreadExecution` (por defecto
`true`). Todo callback que toque natives debe pasarlo en `true`.

*Mitigación implementada:* `PizzaGames_Natives.lua` arranca **desarmado**. Hasta
que el bucle llama a `N.arm()`, toda invocación devuelve `nil` y se registra el
nombre. Un error de hilo produce una línea de log, no un cierre.

*El auto-actualizador (sección 7) no toca esta trampa:* `Curl` y `FileMgr` son
clases de Cherax, no natives crudas, y el propio cargador de `PizzaGames.lua`
ya las usa fuera del hilo de script sin problema. La comprobación de versión
puede lanzarse al cargar los módulos; sólo el sondeo de `GetFinished()` corre
dentro del bucle, y no porque lo exija el hilo, sino porque nada puede
bloquear un frame (ver 5.3).

### 5.2 Algunas natives reciben punteros, no valores

`DELETE_ENTITY(Entity*)` y `REMOVE_BLIP(Blip*)`. Pasarles el handle directo
provoca:

```
EXCEPTION_ACCESS_VIOLATION — Attempted to read from: 0x7D02
```

`0x7D02` es simplemente el número del handle interpretado como dirección.

*Solución:* `Memory.AllocInt()`, escribir el handle dentro y pasar la dirección.
Está en `N.delete_entity()` y `N.remove_blip()`. **Cualquier native nueva con
parámetro `Tipo*` necesita el mismo tratamiento.**

### 5.3 Lo que se dibuja hay que repintarlo cada frame

Marcadores, textos y rectángulos no persisten en GTA. La primera versión usaba
`Script.RegisterLooped` con `Script.Yield()` al final, así que dibujaba en
frames alternos: 30 Hz sobre 60 fps, con parpadeo visible.

*Solución:* el motor es una feature con `eCallbackTrigger.OnTick`, una pasada
completa por frame **sin ceder el control**. Consecuencia: nada dentro del frame
puede bloquear, por eso la carga de modelos va por pasos, y por eso el
auto-actualizador sondea `Curl` con `GetFinished()` en vez de esperar con un
bucle bloqueante.

El panel muestra la frecuencia real (`Motor: activo (60 Hz)`). Si baja a ~30,
alguien ha reintroducido un yield.

### 5.4 Los bucles no pueden depender de un solo freno

`Models.request` giraba esperando la carga con un plazo por reloj como única
salida. Si el reloj no avanza, **el juego se congela para siempre**.

*Regla:* todo bucle de espera lleva dos frenos independientes — plazo por tiempo
y tope de iteraciones. `PizzaGames_Updater.lua` la aplica en cada descarga
(`DOWNLOAD_TIMEOUT_S` + `DOWNLOAD_MAX_TICKS`): si `Curl` se queda colgado sin
avisar, el auto-actualizador se rinde solo y lo registra en vez de bloquear
el bucle principal para siempre.

### 5.5 `stop()` no puede fallar nunca

Una excepción a mitad de la parada dejaba el estado en `ENDING` para siempre:
recursos huérfanos y todos los `start()` posteriores rechazados. Un fallo
inutilizaba el script.

*Solución en tres capas:*
- `stop()` protege cada fase por separado; el retorno a IDLE está garantizado.
- Vigilante: si `ENDING` dura más de 5 s, fuerza el reinicio.
- Botón "REINICIO DE EMERGENCIA" para rescate manual.

*La misma filosofía se aplicó al auto-actualizador:* si escribir los archivos
nuevos falla a mitad de camino, `PizzaGames_Updater.lua` restaura
automáticamente desde el respaldo que acaba de crear, en vez de dejar una
mezcla de archivos viejos y nuevos en disco.

### Bonus: dos trampas de Lua

```lua
-- MAL: si faltan TODOS, la tabla queda vacía, pairs() no itera
-- y la comprobación pasa justo cuando debía fallar.
local req = { FeatureMgr = FeatureMgr, ClickGUI = ClickGUI }
for nombre, ref in pairs(req) do ... end

-- BIEN
local req = { "FeatureMgr", "ClickGUI" }
for _, nombre in ipairs(req) do if _G[nombre] == nil then ... end end
```

Y: **una función local usada antes de declararse se resuelve como global (nil)**
y revienta en ejecución. Ocurrió dos veces (`local API`, `start_intro`).

---

## 6. Modelos de props

`GTA.CreateObject` **no** hace streaming del modelo. Los props comunes funcionan
porque ya están cargados en el mundo; los raros devuelven handle 0 en silencio.

`PizzaGames_Scene.lua` valida con `IS_MODEL_VALID` + `IS_MODEL_IN_CDIMAGE` y
sustituye por recambios si el modelo no existe, avisando en el log.

**Sin verificar en juego** (pendiente): los nombres de `Prefabs.ROAD_MODELS`
(`stt_prop_stunt_track_stgt`, etc.). Si la calzada sale rara, es aquí.

---

## 7. Auto-actualización desde GitHub

**Implementado.** Repositorio: `https://github.com/TuShaggy/PizzaScript`.

Cherax expone Curl asíncrono:

```lua
local c = Curl.Easy()
c:Setopt(eCurlOption.CURLOPT_URL, "https://raw.githubusercontent.com/TuShaggy/PizzaScript/main/version.json")
c:Setopt(eCurlOption.CURLOPT_USERAGENT, "PizzaGames")
c:Perform()                      -- asíncrono
-- guardar 'c' en una variable persistente: si el recolector de basura lo
-- libera, la petición muere a medias
-- luego, por frame:  if c:GetFinished() then local code, body = c:GetResponse() end
-- code == eCurlCode.CURLE_OK
```

Y para escribir a disco: `FileMgr.WriteFileContent(ruta, contenido)`,
`FileMgr.CreateDir`, `FileMgr.Unzip(zip, dir)`.

### Diseño implementado

`PizzaGames_Updater.lua` (ver sección 3):

1. `version.json` en la raíz del repo: `{ "version": "...", "files": [...], "notas": "..." }`.
   La lista `files` usa rutas relativas a la raíz de instalación
   (`PizzaGames.lua`, `PizzaScript/PizzaGames_Core.lua`, …) — las mismas
   rutas sirven para construir la URL de descarga (`.../src/<ruta>`) y el
   destino local.
2. Al arrancar (si el toggle "Buscar al iniciar" está activo, por defecto sí),
   descarga `version.json` y compara contra `PG._VERSION` con un comparador
   semver simplificado (sólo números, sin sufijos `-beta` etc.).
3. Si hay novedad: toast + botón "Actualizar ahora" habilitado en la pestaña.
4. Al pulsarlo, descarga cada archivo (secuencial, un `Curl.Easy()` a la vez)
   y **lo verifica con `load(contenido)` antes de tocar nada en disco** — la
   misma técnica que ya usa `PizzaGames.lua` para cargar módulos. Si
   cualquiera falla, se aborta el lote entero sin sustituir nada.
5. Sólo si todos verifican: copia el contenido actual de cada archivo a
   `PizzaScript\_backup\<versión-anterior>\` y después escribe los nuevos.
   Botón "Revertir a versión anterior" para deshacerlo.

Los cambios se recogen en el **siguiente** arranque del script (recarga
manual desde el Lua Editor); no hay sustitución de código en caliente de
módulos ya cargados en memoria — no es seguro con el patrón de carga actual.

Consideraciones aplicadas:
- Las descargas van por frames (`GetFinished()`), nunca bloqueando (trampa 5.3).
- Cada espera de red lleva dos frenos independientes: tiempo e iteraciones
  (trampa 5.4).
- Si no hay red, el script arranca igual con lo que tenga en disco.
- El botón "Actualizar ahora" se rechaza si hay un minijuego en curso.
- Un fallo a mitad de la escritura restaura automáticamente desde el
  respaldo recién creado (trampa 5.5).
- Los `raw.githubusercontent.com` se cachean unos minutos; no esperar
  inmediatez tras un push.

### Instalador de un solo archivo

`PizzaGames.lua` puede repartirse **solo**, sin los otros 8 archivos: si al
arrancar no encuentra ningún módulo en la carpeta de instalación, los
descarga él mismo desde `src/PizzaScript/` de este repositorio antes de
seguir. Cada archivo se verifica con `load()` antes de guardarse, igual que
el auto-actualizador — no puede quedar una instalación a medias con módulos
mezclados de distintas versiones.

No reutiliza `PizzaGames_Updater.lua` para esto: ese módulo es justo uno de
los que hay que descargar, así que no puede existir todavía la primera vez.
Es una duplicación deliberada de una pequeña parte de la lógica (descarga
secuencial + `load()` + dos frenos), no un descuido — los dos mecanismos
corren en momentos distintos y con garantías distintas (el instalador no
tiene nada que revertir; el actualizador sí).

Una vez que los módulos ya existen en disco, `PizzaGames.lua` no vuelve a
descargar nada por su cuenta en arranques posteriores: eso es trabajo del
auto-actualizador (con su propia UI y comparación de versiones), no del
instalador.

### Estructura de repositorio

```
/                     README.md, LICENSE, version.json
/src                  PizzaGames.lua + PizzaScript/ (9 archivos, mismo árbol
                      que la instalación real)
/docs                 este documento
/sim                  simulador + pruebas (sección 8)
/.github/workflows    validate.yml — luac -p, sim/run_tests.lua y que
                      version.json coincida con src/, en cada push
```

---

## 8. Cómo se prueba esto sin GTA

`sim/sim.lua` — simulador mínimo de la API de Cherax, **reconstruido en esta
sesión**: la versión anterior de este documento daba por hecho que ya existía
y que había detectado tres crashes antes de llegar al juego, pero ese archivo
nunca llegó a construirse (o se perdió); ese historial no se puede recuperar.

Alcance actual, ajustado a lo que hacía falta para el auto-actualizador:

- Carga y ejecuta el `PizzaGames_Core.lua` **real** (no un mock: Core.lua es
  Lua puro salvo por `PG.now()`, que ya degrada solo a `os.time()` si falta
  `game_timer`, igual que dentro de Cherax cuando faltan capacidades).
- Mocks en memoria de `FileMgr` (sistema de archivos virtual), `Curl`
  (asíncrono simulado por ticks, con respuestas controlables: éxito, fallo de
  red, cuerpo que no compila, petición que nunca termina), `GUI.AddToast`,
  `Logger`, `Utils.Joaat`.
- `sim/run_tests.lua`: compila los 9 archivos de `/src` (equivalente a
  `luac -p`), prueba el comparador de versiones y el parser de
  `version.json`, y ejercita el auto-actualizador completo: sin red, versión
  igual, ciclo feliz con respaldo y reversión, archivo que no compila (debe
  abortar sin tocar disco), y el freno de iteraciones ante una descarga que
  nunca termina.
- **No cubre** (pendiente, fuera del alcance de esta sesión): `FeatureMgr`,
  `ClickGUI`, `GTA`, natives por hash, ni el ciclo completo de los cuatro
  minijuegos (geometría de pistas, tangentes, cierre de circuitos, fugas de
  entidades). Eso es lo que la versión anterior de este documento atribuía al
  simulador; si se necesita, es trabajo nuevo, no una restauración.

`luac5.4 -p *.lua` (o `lua sim/run_tests.lua`, que además ejecuta las
pruebas) valida sintaxis. El workflow de CI corre lo mismo en cada push.

---

## 9. Estado actual y siguientes pasos

**Funciona:** carga, pestaña con 4 categorías de minijuegos + Actualizaciones,
panel de salud, HUD, natives verificadas, borrado sin fugas, teletransporte a
la salida, intros cinematográficas (desactivadas por defecto), autotest,
**auto-actualizador con verificación por `load()`, respaldo y reversión**,
**instalador de un solo archivo** (`PizzaGames.lua` descarga el resto solo si
no los encuentra).

**Sin verificar en juego:** nombres de props de calzada; si el parpadeo
desapareció del todo; si la calzada queda a la altura correcta (`z_offset` está
en −0.5 m); el flujo real de red del auto-actualizador contra GitHub (el
simulador cubre toda la lógica que no depende de la red real ni del juego,
pero la petición HTTP de verdad sólo puede probarse dentro de Cherax).

**Ideas pendientes:**
- Tabla de récords persistente con `FileMgr.WriteFileContent`
- Más trazados y un editor de circuitos
- Cuenta atrás 3-2-1 antes de arrancar
- Sonido en los checkpoints (`AUDIO.PLAY_SOUND_FRONTEND`, ya extraída)
- Simulador ampliado a `FeatureMgr`/`ClickGUI`/`GTA`/natives y al ciclo
  completo de los 4 minijuegos, si una sesión futura lo necesita

---

## 10. Alcance

Esto es un proyecto de **un solo jugador**. La API de Cherax permite enviar
eventos de script a otros jugadores y alterar su estado; PizzaGames no lo hace y
no debería. Sincronizar un minijuego entre participantes que se han apuntado es
otra cosa y sería legítimo, pero nada de actuar sobre jugadores que no lo han
pedido.
