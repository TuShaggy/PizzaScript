--[[
================================================================================
  PizzaGames_Prefabs  v0.2.0
  Generación procedural de estructuras: pistas, arenas, plataformas, rampas.

  ESTE ARCHIVO ES LUA PURO. Cero dependencias del juego, cero llamadas a la API.
  Por eso puede verificarse al 100% fuera de GTA — y por eso los bugs de
  geometría (huecos entre tramos, curvas que no empalman, NaN) se detectan
  antes de entrar en partida.

  CONVENCIÓN DE ÁNGULOS (la de GTA V):
    heading 0   = norte (+Y)
    heading 90  = oeste (-X)
    forward(h)  = (-sin h,  cos h)
    right(h)    = ( cos h,  sin h)
    girar a la DERECHA disminuye el heading.
================================================================================
]]

local Prefabs = {}
Prefabs._VERSION = "0.2.0"

local sin, cos, rad, deg = math.sin, math.cos, math.rad, math.deg
local sqrt, pi, abs      = math.sqrt, math.pi, math.abs

--==============================================================================
-- Utilidades vectoriales
--==============================================================================

local function forward(h) local r = rad(h); return -sin(r),  cos(r) end
local function right(h)   local r = rad(h); return  cos(r),  sin(r) end

local function rotate_around(px, py, cx, cy, a)
    local r  = rad(a)
    local c, s = cos(r), sin(r)
    local dx, dy = px - cx, py - cy
    return cx + dx * c - dy * s, cy + dx * s + dy * c
end

local function dist2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

local function is_finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

Prefabs.forward, Prefabs.right = forward, right
Prefabs.dist2d, Prefabs.is_finite = dist2d, is_finite

--==============================================================================
-- CONSTRUCTOR DE TRAZADOS
--   Encadena tramos rectos y curvas. Cada tramo arranca exactamente donde
--   acabó el anterior, con el mismo heading -> continuidad garantizada.
--==============================================================================

local Path = {}
Path.__index = Path

--- @param origin {x,y,z}  @param heading grados
function Prefabs.path(origin, heading, opts)
    opts = opts or {}
    local self = setmetatable({}, Path)
    self.step     = opts.step or 5.0        -- distancia de muestreo (m)
    self.nodes    = {}
    self.segments = {}
    self.cursor   = {
        x = origin.x, y = origin.y, z = origin.z or 0,
        h = heading or 0, bank = 0,
    }
    -- El nodo inicial forma parte del trazado
    self.nodes[1] = {
        x = self.cursor.x, y = self.cursor.y, z = self.cursor.z,
        h = self.cursor.h, bank = 0, s = 0,
    }
    self.length = 0
    return self
end

function Path:_push(x, y, z, h, bank)
    local prev = self.nodes[#self.nodes]
    local d    = sqrt((x - prev.x) ^ 2 + (y - prev.y) ^ 2 + (z - prev.z) ^ 2)
    self.length = self.length + d
    self.nodes[#self.nodes + 1] = {
        x = x, y = y, z = z, h = h % 360, bank = bank or 0, s = self.length,
    }
end

--- Tramo recto.
--- @param length metros  @param opts {rise=Δz, bank=grados}
function Path:straight(length, opts)
    opts = opts or {}
    local rise = opts.rise or 0
    local bank = opts.bank or 0
    local c    = self.cursor
    local fx, fy = forward(c.h)
    local n    = math.max(1, math.ceil(length / self.step))

    local x0, y0, z0 = c.x, c.y, c.z
    for i = 1, n do
        local t = i / n
        self:_push(x0 + fx * length * t,
                   y0 + fy * length * t,
                   z0 + rise * t,
                   c.h, bank * t)
    end

    c.x, c.y, c.z, c.bank = x0 + fx * length, y0 + fy * length, z0 + rise, bank
    self.segments[#self.segments + 1] = { kind = "straight", length = length, rise = rise }
    return self
end

--- Curva de radio constante.
--- @param radius metros  @param angle grados (positivo = derecha)
--- @param opts {rise=Δz, bank=grados}
function Path:curve(radius, angle, opts)
    opts = opts or {}
    local rise = opts.rise or 0
    local bank = opts.bank or 0
    local c    = self.cursor

    assert(radius > 0, "curve(): el radio debe ser > 0")

    local sgn  = angle >= 0 and 1 or -1     -- +1 derecha, -1 izquierda
    local mag  = abs(angle)
    local rx, ry = right(c.h)
    -- Centro del giro, perpendicular al sentido de marcha
    local cx, cy = c.x + rx * radius * sgn, c.y + ry * radius * sgn

    local arc = rad(mag) * radius
    local n   = math.max(2, math.ceil(arc / self.step))
    local z0  = c.z

    for i = 1, n do
        local t  = i / n
        local a  = mag * t
        local px, py = rotate_around(c.x, c.y, cx, cy, -sgn * a)
        self:_push(px, py, z0 + rise * t, c.h - sgn * a, bank * t)
    end

    local fx, fy = rotate_around(c.x, c.y, cx, cy, -sgn * mag)
    c.x, c.y, c.z = fx, fy, z0 + rise
    c.h = (c.h - sgn * mag) % 360
    c.bank = bank

    self.segments[#self.segments + 1] =
        { kind = "curve", radius = radius, angle = angle, arc = arc, rise = rise }
    return self
end

--- Devuelve el trazado terminado.
function Path:build()
    return {
        nodes    = self.nodes,
        segments = self.segments,
        length   = self.length,
        closed   = dist2d(self.nodes[1], self.nodes[#self.nodes]) < 12.0,
        gap      = dist2d(self.nodes[1], self.nodes[#self.nodes]),
    }
end

--- Muestrea el trazado cada `spacing` metros (para checkpoints).
function Path.sample(track, spacing)
    local out, next_s = {}, 0
    for _, n in ipairs(track.nodes) do
        if n.s >= next_s then
            out[#out + 1] = n
            next_s = n.s + spacing
        end
    end
    return out
end
Prefabs.sample = Path.sample

--==============================================================================
-- COLOCACIÓN DE PROPS
--   Convierte un trazado en una lista de props listos para instanciar.
--   Devuelve descriptores puros: {model, x, y, z, rx, ry, rz}
--==============================================================================

--- Bordillos/barreras a ambos lados del trazado.
--- @param opts {model, width, spacing, both_sides, z_offset}
function Prefabs.line_props(track, opts)
    opts = opts or {}
    local model   = opts.model      or "prop_mp_barrier_02b"
    local width   = opts.width      or 6.0
    local spacing = opts.spacing    or 6.0
    local zoff    = opts.z_offset   or 0
    local sides   = opts.both_sides ~= false

    local props, next_s = {}, 0
    for _, n in ipairs(track.nodes) do
        if n.s >= next_s then
            next_s = n.s + spacing
            local rx, ry = right(n.h)
            props[#props + 1] = {
                model = model,
                x = n.x + rx * width, y = n.y + ry * width, z = n.z + zoff,
                rx = 0, ry = n.bank, rz = n.h,
            }
            if sides then
                props[#props + 1] = {
                    model = model,
                    x = n.x - rx * width, y = n.y - ry * width, z = n.z + zoff,
                    rx = 0, ry = n.bank, rz = n.h,
                }
            end
        end
    end
    return props
end

--- Anillo cerrado de props (arena, coliseo, zona de combate).
function Prefabs.arena(center, opts)
    opts = opts or {}
    local model  = opts.model  or "prop_mp_barrier_02b"
    local radius = opts.radius or 40
    local count  = opts.count  or 32
    local zoff   = opts.z_offset or 0

    local props = {}
    for i = 0, count - 1 do
        local a  = (i / count) * 2 * pi
        local px = center.x + cos(a) * radius
        local py = center.y + sin(a) * radius
        props[#props + 1] = {
            model = model, x = px, y = py, z = center.z + zoff,
            rx = 0, ry = 0, rz = deg(a) % 360,   -- de cara al centro
        }
    end
    return props
end

--- Escalera de plataformas ascendente (parkour).
function Prefabs.platforms(origin, heading, opts)
    opts = opts or {}
    local model   = opts.model   or "prop_container_01a"
    local count   = opts.count   or 10
    local gap     = opts.gap     or 9.0    -- avance horizontal por plataforma
    local rise    = opts.rise    or 3.0    -- ascenso por plataforma
    local jitter  = opts.jitter  or 4.0    -- desvío lateral máximo
    local seed    = opts.seed

    if seed then math.randomseed(seed) end

    local props, marks = {}, {}
    local fx, fy = forward(heading)
    local rx, ry = right(heading)

    for i = 1, count do
        local lateral = (math.random() * 2 - 1) * jitter
        local px = origin.x + fx * gap * i + rx * lateral
        local py = origin.y + fy * gap * i + ry * lateral
        local pz = origin.z + rise * i
        props[#props + 1] = { model = model, x = px, y = py, z = pz, rx = 0, ry = 0, rz = heading }
        marks[#marks + 1] = { x = px, y = py, z = pz + 2.0, index = i }
    end
    return props, marks
end

--- Rampa simple.
function Prefabs.ramp(origin, heading, opts)
    opts = opts or {}
    local model = opts.model or "prop_mp_ramp_01"
    local pitch = opts.pitch or -20   -- grados de inclinación
    local fx, fy = forward(heading)
    local d = opts.distance or 15
    return { {
        model = model,
        x = origin.x + fx * d, y = origin.y + fy * d, z = origin.z,
        rx = pitch, ry = 0, rz = heading,
    } }
end

--==============================================================================
-- PRESETS DE CIRCUITO
--==============================================================================

Prefabs.TRACKS = {}

Prefabs.TRACKS.oval = {
    name = "Óvalo rápido",
    desc = "Circuito cerrado. Dos rectas largas y dos peraltes de 180°.",
    circuit = true,     -- admite vueltas
    build = function(origin, heading)
        return Prefabs.path(origin, heading, { step = 5 })
            :straight(140)
            :curve(45, 180, { bank = 12 })
            :straight(140)
            :curve(45, 180, { bank = 12 })
            :build()
    end,
}

Prefabs.TRACKS.figure8 = {
    name = "Ocho",
    desc = "Circuito cruzado. Un giro amplio a derecha y otro a izquierda.",
    circuit = true,
    -- GEOMETRÍA: con dos giros de 270° de radio R, el trazado sólo cierra
    -- si las rectas miden exactamente 2R. Con R=38 -> rectas de 76 m.
    -- Si tocas el radio, ajusta la recta o el circuito quedará abierto.
    build = function(origin, heading)
        local R = 38
        return Prefabs.path(origin, heading, { step = 5 })
            :straight(2 * R)
            :curve(R, 270)
            :straight(2 * R)
            :curve(R, -270)
            :build()
    end,
}

Prefabs.TRACKS.mountain = {
    name = "Ascenso de montaña",
    desc = "Punto a punto. Sube 60 m entre curvas cerradas.",
    circuit = false,    -- meta distinta de la salida: sin vueltas
    build = function(origin, heading)
        return Prefabs.path(origin, heading, { step = 4 })
            :straight(60, { rise = 6 })
            :curve(28, 90,  { rise = 8,  bank = 8 })
            :straight(70, { rise = 10 })
            :curve(25, -120, { rise = 9, bank = -10 })
            :straight(50, { rise = 8 })
            :curve(30, 150, { rise = 10, bank = 12 })
            :straight(80, { rise = 9 })
            :build()
    end,
}

Prefabs.TRACKS.sprint = {
    name = "Sprint",
    desc = "Trazado corto y técnico. Ideal para pruebas rápidas.",
    circuit = false,
    build = function(origin, heading)
        return Prefabs.path(origin, heading, { step = 4 })
            :straight(50)
            :curve(22, 90)
            :straight(40)
            :curve(22, -90)
            :straight(60)
            :curve(20, 135)
            :straight(45)
            :build()
    end,
}

function Prefabs.track_ids()
    local ids = {}
    for id in pairs(Prefabs.TRACKS) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

--==============================================================================
-- VALIDACIÓN  (se ejecuta desde la pestaña de diagnóstico)
--==============================================================================

--- Comprueba que un trazado sea geométricamente sano.
function Prefabs.validate(track)
    local problems = {}

    if #track.nodes < 2 then
        problems[#problems + 1] = "el trazado tiene menos de 2 nodos"
        return false, problems
    end

    local max_gap, min_gap = 0, math.huge
    for i = 2, #track.nodes do
        local a, b = track.nodes[i - 1], track.nodes[i]

        for _, k in ipairs({ "x", "y", "z", "h" }) do
            if not is_finite(b[k]) then
                problems[#problems + 1] =
                    string.format("nodo %d: componente '%s' no finito (%s)", i, k, tostring(b[k]))
            end
        end

        local d = dist2d(a, b)
        if d > max_gap then max_gap = d end
        if d < min_gap then min_gap = d end

        -- El heading debe coincidir con la dirección real de avance
        if d > 0.01 then
            local fx, fy = forward(a.h)
            local ux, uy = (b.x - a.x) / d, (b.y - a.y) / d
            local dot    = fx * ux + fy * uy
            if dot < 0.90 then   -- ~25° de tolerancia entre muestras
                problems[#problems + 1] = string.format(
                    "nodo %d: el heading (%.1f°) no concuerda con el avance real (dot=%.3f)",
                    i, a.h, dot)
            end
        end
    end

    if max_gap > 25 then
        problems[#problems + 1] =
            string.format("hueco máximo entre nodos de %.1f m (posible discontinuidad)", max_gap)
    end

    return #problems == 0, problems, { max_gap = max_gap, min_gap = min_gap, nodes = #track.nodes }
end

return Prefabs
