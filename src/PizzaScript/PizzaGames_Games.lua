--[[
================================================================================
  PizzaGames_Games  v0.2.0
  Cuatro minijuegos, uno por categoría, todos con escenario generado.

  PATRÓN DE FASES
  Cargar 200 props no cabe en un frame, así que ningún minijuego "empieza"
  de golpe. Todos siguen la misma máquina:

     MODELOS -> PROPS -> INTRO -> JUGANDO -> FIN

  on_tick despacha según la fase. Así el escenario se construye sin congelar
  el juego y cualquier fallo queda localizado en una fase concreta del log.

  Uso:  dofile("PizzaGames_Games.lua")(PG, Scene, Prefabs)
================================================================================
]]

return function(PG, Scene, Prefabs, Cinema)

local Log = PG.Log
local API = PG.API

local PHASE = { MODELS = "MODELOS", PROPS = "PROPS", INTRO = "INTRO",
                PLAY = "JUGANDO", DONE = "FIN" }

--==============================================================================
-- Ayudantes compartidos
--==============================================================================

local function wait_fn(ms) API.call("wait", nil, ms or 0) end

--- Estilos de intro, en el orden del deslizador de la interfaz.
local INTRO_STYLES = { "descend", "orbit", "flyover", "none" }
local INTRO_NAMES  = { "Descenso", "Órbita", "Sobrevuelo", "Sin intro" }
PG.INTRO_NAMES = INTRO_NAMES

--- Arranca la intro cinematográfica del minijuego.
--- DEBE definirse antes de pump_loading: en Lua una función local usada antes
--- de su declaración se resuelve como global (nil) y revienta en ejecución.
--- @param style "descend" | "orbit" | "flyover" | "none"
local function start_intro(ctx, def, style, extra)
    ctx.data.intro_secs = extra and extra.secs or 5

    if not Cinema or style == "none" then
        ctx.data.intro_secs = 0.5
        ctx.data.intro_end  = PG.now() + 0.5
        return
    end

    local seq
    if style == "orbit" and extra and extra.center then
        seq = Cinema.PRESETS.orbit(extra.center, extra.radius or 40, ctx.data.intro_secs, 1)
    elseif style == "flyover" and extra and extra.nodes then
        seq = Cinema.PRESETS.flyover(extra.nodes, ctx.data.intro_secs)
    else
        seq = Cinema.PRESETS.descend(ctx.data.intro_secs)
    end

    Cinema.play(seq)
    Cinema.title(def.name, {
        sub = extra and extra.subtitle or def.description,
        secs = math.min(4, ctx.data.intro_secs), y = 0.34,
    })
    ctx.data.intro_end = PG.now() + ctx.data.intro_secs
end

--- Avanza las fases de carga comunes. Devuelve true cuando toca jugar.
local function pump_loading(ctx, scene)
    if ctx.data.phase == PHASE.MODELS then
        scene:preload(wait_fn)
        ctx.data.phase = PHASE.PROPS
        ctx.log("Fase -> PROPS (%d por instanciar)", scene:total())
        return false
    end

    if ctx.data.phase == PHASE.DONE then return "abort" end

    if ctx.data.phase == PHASE.PROPS then
        local done, pct = scene:load_step()
        -- Aviso de progreso cada 25 %, para no saturar
        local step = math.floor(pct * 4)
        if step > (ctx.data.last_pct or -1) then
            ctx.data.last_pct = step
            ctx.notify("Construyendo escenario... %d%%", math.floor(pct * 100))
        end
        if done and scene.state == "FAILED" then
            ctx.notify("No se pudo construir el escenario. Revisa el log.")
            ctx.data.phase = PHASE.DONE
            return false
        end
        if done then
            ctx.data.phase = PHASE.INTRO
            local def   = PG.Runtime.registry[ctx.id]
            local style = INTRO_STYLES[ctx.data.intro_style or 1] or "descend"
            start_intro(ctx, def, style, ctx.data.intro_extra)
            ctx.log("Fase -> INTRO (estilo: %s)", style)
        end
        return false
    end

    if ctx.data.phase == PHASE.INTRO then
        -- Doble condición: la secuencia termina, O vence el tope de frames.
        -- Si la cámara no pudo crearse o el reloj va mal, la intro acaba
        -- igualmente en vez de dejar la partida colgada.
        ctx.data.intro_frames = (ctx.data.intro_frames or 0) + 1
        local playing  = Cinema and Cinema.update()
        local by_frame = ctx.data.intro_frames >= (ctx.data.intro_secs * 70)
        local by_time  = PG.now() >= ctx.data.intro_end

        if (not playing and by_time) or by_frame then
            if by_frame and playing then
                ctx.log("La intro venció por frames; se corta la secuencia")
                if Cinema then Cinema.abort() end
            end
            ctx.data.phase = PHASE.PLAY
            ctx.data.play_start = PG.now()
            ctx.notify("¡Adelante!")
            ctx.log("Fase -> JUGANDO")
        end
        return false
    end

    return ctx.data.phase == PHASE.PLAY
end

--- Cierre común a todos los minijuegos.
local function common_stop(ctx, reason)
    if Cinema then Cinema.abort(); Cinema.clear_titles() end
    Scene.Camera.stop()
    if ctx.data.scene then ctx.data.scene:unload() end
    ctx.log("Parada en fase %s. Motivo: %s", tostring(ctx.data.phase), tostring(reason))
end

--- Comprobar IS_ENTITY_DEAD en cada ped y cada frame dispara las llamadas a
--- natives (con 12 enemigos son ~720/segundo). Basta revisarlo cada ~15
--- frames: un cuarto de segundo de retardo en sumar puntos es imperceptible.
local DEAD_CHECK_EVERY = 15

local function reap_dead(ctx, list, points)
    if PG.Runtime.tick_count % DEAD_CHECK_EVERY ~= 0 then return 0 end
    local reaped = 0
    for i = #list, 1, -1 do
        if API.call("is_ped_dead", false, list[i]) then
            table.remove(list, i)
            ctx.score = ctx.score + points
            reaped = reaped + 1
        end
    end
    return reaped
end


local function offset_from(pos, heading, dist)
    local fx, fy = Prefabs.forward(heading)
    return { x = pos.x + fx * dist, y = pos.y + fy * dist, z = pos.z }
end

--==============================================================================
-- 1. CONDUCCIÓN — Circuito
--==============================================================================

local RACE_IDS = Prefabs.track_ids()

PG.register({
    id          = "race_circuit",
    name        = "Circuito",
    category    = "Conducción",
    description = "Construye una pista con barreras y corre contrarreloj.",

    params = {
        { key = "track_index", label = "Pista",             type = "int", min = 1, max = #RACE_IDS, default = 1 },
        { key = "laps",        label = "Vueltas",           type = "int", min = 1, max = 5,   default = 2 },
        { key = "cp_spacing",  label = "Separación CP (m)", type = "int", min = 30, max = 150, default = 60 },
        { key = "barrier_gap", label = "Separación vallas", type = "int", min = 4,  max = 25,  default = 8 },
        { key = "track_width", label = "Ancho de pista (m)",type = "int", min = 4,  max = 20,  default = 8 },
        { key = "intro_style", label = "Estilo de intro (1-4)", type = "int", min = 1, max = 4, default = 3 },
    },
    settings = { track_index = 1, laps = 2, cp_spacing = 60, barrier_gap = 8, track_width = 8 , intro_style = 3 },

    on_start = function(ctx)
        local s   = PG.Runtime.registry.race_circuit.settings
        local tid = RACE_IDS[s.track_index] or RACE_IDS[1]
        local def = Prefabs.TRACKS[tid]

        local origin = ctx.player_pos()
        local track  = def.build(origin, 0)

        -- Validar ANTES de instanciar nada: mejor abortar que dejar 200 props sueltos
        local ok, problems, stats = Prefabs.validate(track)
        if not ok then
            ctx.log("TRAZADO INVÁLIDO: %s", table.concat(problems, "; "))
            ctx.notify("Error de geometría en la pista. Revisa el log.")
            error("validación del trazado fallida para '" .. tid .. "'")
        end

        ctx.log("Pista '%s': %.0f m, %d nodos, hueco máx %.1f m, circuito=%s",
                def.name, track.length, stats.nodes, stats.max_gap, tostring(def.circuit))

        local scene = Scene.new("pista_" .. tid, ctx.res, { per_frame = 10, frozen = true })
        scene:add(Prefabs.line_props(track, {
            spacing = s.barrier_gap, width = s.track_width, both_sides = true,
        }))

        ctx.data.scene      = scene
        ctx.data.track      = track
        ctx.data.circuit    = def.circuit
        ctx.data.checkpoints= Prefabs.sample(track, s.cp_spacing)
        ctx.data.cp_index   = 1
        ctx.data.lap        = 1
        ctx.data.total_laps = def.circuit and s.laps or 1
        ctx.data.phase = PHASE.MODELS
        ctx.data.intro_style = s.intro_style
        ctx.data.intro_extra = { nodes = track.nodes, secs = 6,
            subtitle = string.format("%s — %.0f m, %d vueltas",
                                     def.name, track.length, ctx.data.total_laps) }

        ctx.notify("Pista: %s (%.0f m, %d vueltas)", def.name, track.length, ctx.data.total_laps)
    end,

    on_tick = function(ctx)
        local s = PG.Runtime.registry.race_circuit.settings
        local pumped = pump_loading(ctx, ctx.data.scene)
        if pumped == "abort" then return false end
        if not pumped then return end

        local cp = ctx.data.checkpoints[ctx.data.cp_index]
        if not cp then return false end

        API.call("draw_marker", nil, 1, cp.x, cp.y, cp.z - 1, 0,0,0, 0,0,0, 8.0,8.0,4.0, 255,180,0,120)

        local pos = ctx.player_pos()
        if ctx.dist3(pos, cp) < 10 then
            ctx.score = ctx.score + 50
            ctx.data.cp_index = ctx.data.cp_index + 1
            ctx.log("CP %d/%d, vuelta %d", ctx.data.cp_index - 1,
                    #ctx.data.checkpoints, ctx.data.lap)

            if ctx.data.cp_index > #ctx.data.checkpoints then
                if ctx.data.lap >= ctx.data.total_laps then
                    local t = PG.now() - ctx.data.play_start
                    ctx.score = ctx.score + math.max(0, 1000 - math.floor(t * 5))
                    ctx.notify("¡Meta! Tiempo: %.1fs", t)
                    return false
                end
                ctx.data.lap = ctx.data.lap + 1
                ctx.data.cp_index = 1
                ctx.notify("Vuelta %d/%d", ctx.data.lap, ctx.data.total_laps)
            end
        end
    end,

    on_stop = common_stop,
})

--==============================================================================
-- 2. COMBATE — Arena de oleadas
--==============================================================================

PG.register({
    id          = "combat_arena",
    name        = "Arena de oleadas",
    category    = "Combate",
    description = "Levanta una arena cerrada y sobrevive a oleadas crecientes.",

    params = {
        { key = "radius",    label = "Radio de arena (m)", type = "int", min = 20, max = 90, default = 40 },
        { key = "wall_count",label = "Segmentos de muro",  type = "int", min = 16, max = 80, default = 40 },
        { key = "waves",     label = "Oleadas",            type = "int", min = 1,  max = 15, default = 5 },
        { key = "per_wave",  label = "Enemigos por oleada",type = "int", min = 1,  max = 12, default = 3 },
        { key = "intro_style", label = "Estilo de intro (1-4)", type = "int", min = 1, max = 4, default = 2 },
    },
    settings = { radius = 40, wall_count = 40, waves = 5, per_wave = 3 , intro_style = 2 },

    on_start = function(ctx)
        local s      = PG.Runtime.registry.combat_arena.settings
        local center = ctx.player_pos()

        local scene = Scene.new("arena", ctx.res, { per_frame = 8, frozen = true })
        scene:add(Prefabs.arena(center, { radius = s.radius, count = s.wall_count }))

        ctx.data.scene      = scene
        ctx.data.center     = center
        ctx.data.wave       = 0
        ctx.data.enemies    = {}
        ctx.data.phase = PHASE.MODELS
        ctx.data.intro_style = s.intro_style
        ctx.data.intro_extra = { center = center, radius = s.radius + 15, secs = 6,
            subtitle = string.format("%d oleadas", s.waves) }
    end,

    on_tick = function(ctx)
        local s = PG.Runtime.registry.combat_arena.settings
        local pumped = pump_loading(ctx, ctx.data.scene)
        if pumped == "abort" then return false end
        if not pumped then return end

        -- Limpiar la lista de enemigos abatidos (comprobación espaciada)
        reap_dead(ctx, ctx.data.enemies, 100)
        if #ctx.data.enemies > 0 then return end

        -- Oleada superada
        if ctx.data.wave >= s.waves then
            ctx.notify("¡Todas las oleadas superadas! Puntuación: %d", ctx.score)
            return false
        end

        ctx.data.wave = ctx.data.wave + 1
        local count   = s.per_wave + (ctx.data.wave - 1)
        ctx.notify("Oleada %d/%d — %d enemigos", ctx.data.wave, s.waves, count)
        ctx.log("Generando oleada %d con %d enemigos", ctx.data.wave, count)

        local player = PG.player_ped()
        local spawned = 0
        for i = 1, count do
            local a  = (i / count) * 2 * math.pi
            local px = ctx.data.center.x + math.cos(a) * (s.radius - 6)
            local py = ctx.data.center.y + math.sin(a) * (s.radius - 6)

            local ok, hash = Scene.Models.request("a_m_y_hipster_01", wait_fn)
            local ped = ok and API.call("create_ped", nil, 4, hash, px, py, ctx.data.center.z, 0.0, true, false)

            if ped and ped ~= 0 then
                ctx.res:track("entity", ped)
                ctx.data.enemies[#ctx.data.enemies + 1] = ped
                API.call("give_weapon", nil, ped, "WEAPON_PISTOL", 200, false, true)
                API.call("task_combat", nil, ped, player, 0, 16)
                spawned = spawned + 1
            end
        end

        if spawned < count then
            ctx.log("AVISO: sólo %d/%d enemigos generados", spawned, count)
        end
        if spawned == 0 then
            ctx.notify("No se pudo generar ningún enemigo. Revisa el log.")
            return false
        end
    end,

    on_stop = common_stop,
})

--==============================================================================
-- 3. HABILIDAD — Parkour ascendente
--==============================================================================

PG.register({
    id          = "skill_parkour",
    name        = "Parkour ascendente",
    category    = "Habilidad",
    description = "Torre de plataformas. Súbelas en orden antes de que acabe el tiempo.",

    params = {
        { key = "count",     label = "Plataformas",   type = "int", min = 5,  max = 30,  default = 12 },
        { key = "gap",       label = "Separación (m)",type = "int", min = 5,  max = 20,  default = 9 },
        { key = "rise",      label = "Altura (m)",    type = "int", min = 1,  max = 8,   default = 3 },
        { key = "time_limit",label = "Límite (s)",    type = "int", min = 30, max = 600, default = 180 },
        { key = "intro_style", label = "Estilo de intro (1-4)", type = "int", min = 1, max = 4, default = 1 },
    },
    settings = { count = 12, gap = 9, rise = 3, time_limit = 180 , intro_style = 1 },

    on_start = function(ctx)
        local s      = PG.Runtime.registry.skill_parkour.settings
        local origin = ctx.player_pos()

        local props, marks = Prefabs.platforms(origin, 0, {
            count = s.count, gap = s.gap, rise = s.rise, seed = os.time(),
        })

        local scene = Scene.new("parkour", ctx.res, { per_frame = 6, frozen = true })
        scene:add(props)

        ctx.data.scene      = scene
        ctx.data.marks      = marks
        ctx.data.index      = 1
        ctx.data.deadline   = nil          -- el reloj arranca al terminar la intro
        ctx.data.phase = PHASE.MODELS
        ctx.data.intro_style = s.intro_style
        ctx.data.top_mark = marks[#marks]
        ctx.data.intro_extra = { center = origin, radius = 30, secs = 5,
            nodes = marks,
            subtitle = string.format("%d plataformas, %d s", s.count, s.time_limit) }
    end,

    on_tick = function(ctx)
        local s = PG.Runtime.registry.skill_parkour.settings
        local pumped = pump_loading(ctx, ctx.data.scene)
        if pumped == "abort" then return false end
        if not pumped then return end

        ctx.data.deadline = ctx.data.deadline or (PG.now() + s.time_limit)
        local left = ctx.data.deadline - PG.now()
        if left <= 0 then
            ctx.notify("¡Tiempo agotado! Plataformas: %d/%d", ctx.data.index - 1, #ctx.data.marks)
            return false
        end

        local m = ctx.data.marks[ctx.data.index]
        if not m then return false end

        API.call("draw_marker", nil, 1, m.x, m.y, m.z, 0,0,0, 0,0,0, 2.0,2.0,1.5, 0,220,255,140)

        local pos = ctx.player_pos()
        -- Tolerancia vertical más estrecha: hay que estar ENCIMA, no debajo
        local flat = math.sqrt((pos.x - m.x)^2 + (pos.y - m.y)^2)
        if flat < 3.0 and math.abs(pos.z - m.z) < 3.5 then
            ctx.score = ctx.score + 150 + math.floor(left)
            ctx.data.index = ctx.data.index + 1
            ctx.log("Plataforma %d alcanzada (quedan %.0fs)", ctx.data.index - 1, left)

            if ctx.data.index > #ctx.data.marks then
                ctx.notify("¡Cima alcanzada! Puntuación: %d", ctx.score)
                return false
            end
            ctx.notify("Plataforma %d/%d", ctx.data.index - 1, #ctx.data.marks)
        end
    end,

    on_stop = common_stop,
})

--==============================================================================
-- 4. SUPERVIVENCIA — Rey de la colina
--==============================================================================

PG.register({
    id          = "survival_koth",
    name        = "Rey de la colina",
    category    = "Supervivencia",
    description = "Mantente dentro de la zona mientras llegan enemigos. Salir congela el marcador.",

    params = {
        { key = "zone_radius", label = "Radio de zona (m)", type = "int", min = 5,  max = 40,  default = 12 },
        { key = "hold_time",   label = "Tiempo a aguantar", type = "int", min = 30, max = 600, default = 120 },
        { key = "spawn_every", label = "Enemigo cada (s)",  type = "int", min = 3,  max = 60,  default = 12 },
        { key = "max_enemies", label = "Máx. simultáneos",  type = "int", min = 1,  max = 20,  default = 8 },
        { key = "intro_style", label = "Estilo de intro (1-4)", type = "int", min = 1, max = 4, default = 2 },
    },
    settings = { zone_radius = 12, hold_time = 120, spawn_every = 12, max_enemies = 8 , intro_style = 2 },

    on_start = function(ctx)
        local s      = PG.Runtime.registry.survival_koth.settings
        local center = ctx.player_pos()

        local scene = Scene.new("koth", ctx.res, { per_frame = 6, frozen = true })
        scene:add(Prefabs.arena(center, { radius = s.zone_radius, count = 16 }))

        ctx.data.scene      = scene
        ctx.data.center     = center
        ctx.data.held       = 0
        ctx.data.enemies    = {}
        ctx.data.next_spawn = 0
        ctx.data.last_t     = PG.now()
        ctx.data.phase = PHASE.MODELS
        ctx.data.intro_style = s.intro_style
        ctx.data.intro_extra = { center = center, radius = s.zone_radius + 20, secs = 5,
            subtitle = string.format("Aguanta %d s", s.hold_time) }
    end,

    on_tick = function(ctx)
        local s = PG.Runtime.registry.survival_koth.settings
        local pumped = pump_loading(ctx, ctx.data.scene)
        if pumped == "abort" then return false end
        if not pumped then return end

        local now = PG.now()
        local dt  = now - ctx.data.last_t
        ctx.data.last_t = now

        local c = ctx.data.center
        API.call("draw_marker", nil, 1, c.x, c.y, c.z - 1, 0,0,0, 0,0,0,
                 s.zone_radius * 2, s.zone_radius * 2, 2.0, 0,255,120,90)

        local pos     = ctx.player_pos()
        local in_zone = math.sqrt((pos.x - c.x)^2 + (pos.y - c.y)^2) <= s.zone_radius

        if in_zone then
            ctx.data.held = ctx.data.held + dt
            ctx.score = math.floor(ctx.data.held * 10)
        elseif not ctx.data.warned_out then
            ctx.data.warned_out = true
            ctx.notify("¡Fuera de zona! El marcador está detenido.")
        end
        if in_zone then ctx.data.warned_out = false end

        if ctx.data.held >= s.hold_time then
            ctx.notify("¡Colina defendida %ds! Puntuación: %d", s.hold_time, ctx.score)
            return false
        end

        -- Aviso de progreso cada 25 %
        local q = math.floor((ctx.data.held / s.hold_time) * 4)
        if q > (ctx.data.last_q or -1) and q < 4 then
            ctx.data.last_q = q
            ctx.notify("Aguantando: %d%% (%ds/%ds)", q * 25,
                       math.floor(ctx.data.held), s.hold_time)
        end

        reap_dead(ctx, ctx.data.enemies, 50)

        -- Generación periódica
        if now >= ctx.data.next_spawn and #ctx.data.enemies < s.max_enemies then
            ctx.data.next_spawn = now + s.spawn_every
            local a  = math.random() * 2 * math.pi
            local d  = s.zone_radius + 25
            local ok, hash = Scene.Models.request("a_m_y_hipster_01", wait_fn)
            local ped = ok and API.call("create_ped", nil, 4, hash,
                            c.x + math.cos(a) * d, c.y + math.sin(a) * d, c.z, 0.0, true, false)
            if ped and ped ~= 0 then
                ctx.res:track("entity", ped)
                ctx.data.enemies[#ctx.data.enemies + 1] = ped
                API.call("give_weapon", nil, ped, "WEAPON_PISTOL", 200, false, true)
                API.call("task_combat", nil, ped, PG.player_ped(), 0, 16)
                ctx.log("Enemigo generado (%d activos)", #ctx.data.enemies)
            else
                ctx.log("Fallo al generar enemigo")
            end
        end
    end,

    on_stop = common_stop,
})

Log.info("Games", "4 minijuegos registrados en 4 categorías")

end
