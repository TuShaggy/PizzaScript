--[[
================================================================================
  PizzaGames_Cinema  v0.6.0
  Director de cámara y títulos en pantalla.

  IDEA
  ----
  Una secuencia es una lista de PLANOS. Cada plano define de dónde a dónde va
  la cámara, hacia dónde mira, cuánto dura y con qué curva de aceleración.
  El director avanza por ellos frame a frame; los minijuegos sólo dicen qué
  secuencia quieren y se olvidan del resto.

  Los puntos pueden ser fijos {x,y,z} o dinámicos (una función que devuelve la
  posición), lo que permite planos que siguen al jugador mientras se mueve.

  REGLA DE ORO
  ------------
  La cámara SIEMPRE se libera. Si una secuencia se interrumpe a mitad (fallo,
  parada manual, descarga del script), abort() devuelve el control al juego.
  Una cámara con render activo y sin script detrás deja al jugador atrapado
  mirando al vacío, sin forma de recuperarse salvo reiniciar el juego.

  Uso:  local Cinema = dofile(".../PizzaGames_Cinema.lua")(PG, NAT)
================================================================================
]]

return function(PG, NAT)

local Log = PG.Log
local M   = { active = false, cam = nil, seq = nil, shot = 1, t0 = 0,
              titles = {}, fade_state = "none" }

--==============================================================================
-- Curvas de aceleración
--==============================================================================

local Ease = {}

function Ease.linear(t) return t end
function Ease.in_out(t) return t * t * (3 - 2 * t) end
function Ease.out(t)    return 1 - (1 - t) * (1 - t) end
function Ease.in_(t)    return t * t end

--- Arranca muy lento y termina rápido. Da sensación de "caída" al descender.
function Ease.drop(t) return t * t * t end

--- Sobrepasa ligeramente y vuelve. Aporta un remate elástico.
function Ease.overshoot(t)
    local s = 1.70158
    local u = t - 1
    return u * u * ((s + 1) * u + s) + 1
end

M.Ease = Ease

--==============================================================================
-- Utilidades
--==============================================================================

local function resolve(p)
    if type(p) == "function" then return p() end
    return p
end

local function lerp3(a, b, e)
    return {
        x = a.x + (b.x - a.x) * e,
        y = a.y + (b.y - a.y) * e,
        z = a.z + (b.z - a.z) * e,
    }
end

--- Posición relativa al jugador, en su propio sistema de referencia.
--- @param back  metros por detrás   @param up  metros por encima
--- @param side  metros a la derecha
function M.behind_player(back, up, side)
    return function()
        local ped = NAT and NAT.PLAYER.PLAYER_PED_ID()
        if not ped then return { x = 0, y = 0, z = 0 } end

        local px, py, pz = NAT.ENTITY.GET_ENTITY_COORDS(ped, true)
        local h = math.rad(NAT.ENTITY.GET_ENTITY_HEADING(ped))
        local fx, fy = -math.sin(h), math.cos(h)   -- vector de avance
        local rx, ry = math.cos(h), math.sin(h)    -- vector a la derecha

        return {
            x = px - fx * (back or 6) + rx * (side or 0),
            y = py - fy * (back or 6) + ry * (side or 0),
            z = pz + (up or 2),
        }
    end
end

function M.player_pos(up)
    return function()
        local ped = NAT and NAT.PLAYER.PLAYER_PED_ID()
        if not ped then return { x = 0, y = 0, z = 0 } end
        local px, py, pz = NAT.ENTITY.GET_ENTITY_COORDS(ped, true)
        return { x = px, y = py, z = pz + (up or 0) }
    end
end

--- Punto sobre una órbita alrededor de un centro.
function M.orbit_point(center, radius, height, angle_deg)
    local a = math.rad(angle_deg)
    return {
        x = center.x + math.cos(a) * radius,
        y = center.y + math.sin(a) * radius,
        z = center.z + height,
    }
end

--==============================================================================
-- Títulos en pantalla
--==============================================================================

--- Muestra un título temporal.
--- @param opts {sub, secs, y, scale, r,g,b, band}
function M.title(text, opts)
    opts = opts or {}
    M.titles[#M.titles + 1] = {
        text  = text,
        sub   = opts.sub,
        until_= PG.now() + (opts.secs or 3),
        born  = PG.now(),
        y     = opts.y or 0.38,
        scale = opts.scale or 1.1,
        r = opts.r or 255, g = opts.g or 190, b = opts.b or 40,
        band  = opts.band ~= false,
    }
end

function M.clear_titles() M.titles = {} end

--- Dibuja los títulos vivos. Debe llamarse CADA frame: el texto en GTA no
--- persiste, se redibuja constantemente.
local function draw_titles()
    if not NAT or #M.titles == 0 then return end
    local now = PG.now()

    for i = #M.titles, 1, -1 do
        local t = M.titles[i]
        if now >= t.until_ then
            table.remove(M.titles, i)
        else
            -- Entrada y salida suaves para que no aparezca de golpe
            local total   = t.until_ - t.born
            local elapsed = now - t.born
            local alpha   = 255
            if elapsed < 0.4 then alpha = math.floor(255 * (elapsed / 0.4))
            elseif (t.until_ - now) < 0.6 then
                alpha = math.floor(255 * ((t.until_ - now) / 0.6))
            end
            alpha = math.max(0, math.min(255, alpha))

            if t.band then
                NAT.draw_rect(0.5, t.y + 0.022, 0.62, 0.11, 0, 0, 0,
                              math.floor(alpha * 0.55))
            end
            NAT.draw_text(t.text, 0.5, t.y,
                { scale = t.scale, r = t.r, g = t.g, b = t.b, a = alpha, shadow = true })
            if t.sub then
                NAT.draw_text(t.sub, 0.5, t.y + 0.055,
                    { scale = 0.45, r = 235, g = 235, b = 235, a = alpha, shadow = true })
            end
        end
    end
end

--==============================================================================
-- Secuencias
--==============================================================================

--- Arranca una secuencia de planos.
--- Cada plano: { from, to, look, look_to, secs, ease, fov, shake }
function M.play(seq, opts)
    opts = opts or {}
    if not NAT then
        Log.warn("Cinema", "Sin natives: no hay cámara cinemática")
        return false
    end
    if M.active then M.abort() end
    if not seq or #seq == 0 then return false end

    local cam = NAT.CAM.CREATE_CAM("DEFAULT_SCRIPTED_CAMERA", true)
    if not cam or cam == 0 then
        Log.warn("Cinema", "No se pudo crear la cámara; se sigue sin cinemática")
        return false
    end

    M.cam, M.seq, M.shot, M.active = cam, seq, 1, true
    M.t0 = PG.now()
    M.on_finish = opts.on_finish

    local first = seq[1]
    local p = resolve(first.from)
    NAT.CAM.SET_CAM_COORD(cam, p.x, p.y, p.z)
    NAT.CAM.SET_CAM_FOV(cam, first.fov or 50.0)
    NAT.CAM.RENDER_SCRIPT_CAMS(true, opts.ease_in ~= false, opts.blend_ms or 800, true, false)

    Log.debug("Cinema", "Secuencia iniciada: %d planos", #seq)
    return true
end

--- Avanza la secuencia. Llamar una vez por frame.
--- @return true si sigue reproduciéndose
function M.update()
    draw_titles()
    if not M.active or not M.seq then return false end

    local shot = M.seq[M.shot]
    if not shot then M.finish(); return false end

    local elapsed = PG.now() - M.t0
    local dur     = shot.secs or 3
    local t       = math.max(0, math.min(1, elapsed / dur))
    local ease    = Ease[shot.ease or "in_out"] or Ease.in_out
    local e       = ease(t)

    local from = resolve(shot.from)
    local to   = resolve(shot.to) or from
    local pos  = lerp3(from, to, e)
    NAT.CAM.SET_CAM_COORD(M.cam, pos.x, pos.y, pos.z)

    -- El punto de mira también puede desplazarse durante el plano
    local look = resolve(shot.look)
    if look then
        local look_to = resolve(shot.look_to)
        local target  = look_to and lerp3(look, look_to, e) or look
        NAT.CAM.POINT_CAM_AT_COORD(M.cam, target.x, target.y, target.z)
    end

    if shot.fov_to and shot.fov then
        NAT.CAM.SET_CAM_FOV(M.cam, shot.fov + (shot.fov_to - shot.fov) * e)
    end

    if t >= 1 then
        M.shot = M.shot + 1
        M.t0   = PG.now()
        if M.shot > #M.seq then M.finish(); return false end
        local nxt = M.seq[M.shot]
        if nxt.shake then
            NAT.CAM.SHAKE_CAM(M.cam, nxt.shake, nxt.shake_amp or 0.3)
        end
    end

    return true
end

--- Termina con normalidad, devolviendo el control con una transición suave.
function M.finish()
    if not M.active then return end
    Log.debug("Cinema", "Secuencia terminada")
    local cb = M.on_finish
    M.release(true)
    if cb then PG.try("Cinema.on_finish", cb) end
end

--- Corta de inmediato. Se usa ante fallos o paradas.
function M.abort()
    if not M.active then return end
    Log.debug("Cinema", "Secuencia abortada")
    M.release(false)
end

function M.release(smooth)
    if NAT and M.cam then
        PG.try("Cinema.release", function()
            NAT.CAM.RENDER_SCRIPT_CAMS(false, smooth and true or false,
                                       smooth and 900 or 0, true, false)
            NAT.CAM.DESTROY_CAM(M.cam, true)
        end)
    end
    M.cam, M.seq, M.active, M.on_finish = nil, nil, false, nil
    M.shot = 1
end

function M.is_active() return M.active end

--==============================================================================
-- Secuencias predefinidas
--==============================================================================

M.PRESETS = {}

--- Descenso desde el cielo hasta detrás del jugador. Es la que ya te gustaba,
--- ahora en tres planos con curvas distintas: caída, frenada y asentamiento.
function M.PRESETS.descend(secs)
    secs = secs or 5
    local high  = M.player_pos(70)
    local mid   = M.behind_player(18, 12, 6)
    local final = M.behind_player(5.5, 1.8, 0)
    local look  = M.player_pos(1.0)

    return {
        { from = high, to = mid,   look = look, secs = secs * 0.5,
          ease = "drop",   fov = 70, fov_to = 55 },
        { from = mid,  to = final, look = look, secs = secs * 0.35,
          ease = "out",    fov = 55, fov_to = 48 },
        { from = final, to = final, look = look, secs = secs * 0.15,
          ease = "linear", fov = 48 },
    }
end

--- Órbita alrededor de un punto: ideal para presentar una arena o un circuito.
function M.PRESETS.orbit(center, radius, secs, turns)
    secs, turns = secs or 6, turns or 1
    local shots = {}
    local steps = math.max(4, math.floor(8 * turns))
    local look  = { x = center.x, y = center.y, z = center.z + 2 }

    for i = 1, steps do
        local a0 = (i - 1) / steps * 360 * turns
        local a1 = i / steps * 360 * turns
        shots[i] = {
            from = M.orbit_point(center, radius, radius * 0.45, a0),
            to   = M.orbit_point(center, radius, radius * 0.45, a1),
            look = look, secs = secs / steps, ease = "linear", fov = 55,
        }
    end

    -- Remate: acercarse desde la órbita hasta detrás del jugador
    shots[#shots + 1] = {
        from = M.orbit_point(center, radius, radius * 0.45, 360 * turns),
        to   = M.behind_player(6, 2, 0),
        look = M.player_pos(1.0), secs = 1.8, ease = "in_out",
        fov = 55, fov_to = 48,
    }
    return shots
end

--- Recorrido a lo largo de un trazado: presenta el circuito antes de correr.
function M.PRESETS.flyover(nodes, secs)
    secs = secs or 6
    local n = #nodes
    if n < 2 then return M.PRESETS.descend(secs) end

    local picks, shots = {}, {}
    for i = 1, 5 do picks[i] = nodes[math.max(1, math.floor((i - 1) / 4 * (n - 1)) + 1)] end

    for i = 1, 4 do
        local a, b = picks[i], picks[i + 1]
        shots[i] = {
            from = { x = a.x, y = a.y, z = a.z + 28 },
            to   = { x = b.x, y = b.y, z = b.z + 28 },
            look = { x = a.x, y = a.y, z = a.z },
            look_to = { x = b.x, y = b.y, z = b.z },
            secs = secs / 4, ease = "linear", fov = 60,
        }
    end

    shots[#shots + 1] = {
        from = { x = picks[5].x, y = picks[5].y, z = picks[5].z + 28 },
        to   = M.behind_player(6, 2, 0),
        look = M.player_pos(1.0), secs = 2.0, ease = "in_out",
        fov = 60, fov_to = 48,
    }
    return shots
end

--- Presentación del script al cargarse: giro amplio y remate detrás.
function M.PRESETS.boot()
    local center = M.player_pos(0)()
    local shots = M.PRESETS.orbit(center, 22, 5.5, 0.75)
    shots[1].fov = 75
    return shots
end

return M
end
