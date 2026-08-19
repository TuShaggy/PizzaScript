--[[
================================================================================
  PizzaGames_Natives  v0.7.0
  53 natives de GTA V invocadas por hash mediante Natives.Invoke*.

  BARRERA DE HILO  (lección aprendida a base de crashear el juego)
  ---------------------------------------------------------------
  Las natives SÓLO pueden invocarse desde el hilo de script del juego. El
  cuerpo de un .lua se ejecuta al cargarlo, en OTRO hilo: llamar ahí a
  PLAYER_PED_ID o CREATE_CAM cuelga GTA sin dejar rastro en el log.

  Por eso este módulo arranca DESARMADO. Hasta que alguien llame a N.arm()
  desde dentro de Script.RegisterLooped, toda invocación se rechaza y se
  registra en el log. Así un error de hilo produce una línea legible en vez
  de un cierre del juego.

  Fuente de los hashes:
    SATTY91/Cherax-Lua-API-Documentation -> natives/natives-one.lua
    (generado desde alloc8or/gta5-nativedb-data)
  Variante "one": los Vector3 se pasan como 3 floats sueltos.
================================================================================
]]

local N = {}
if not Natives then return nil end

local armed   = false
local blocked = {}   -- [nombre] = veces, para no inundar el log
local logger  = nil

--- Habilita las llamadas. Invocar SÓLO desde el hilo de script del juego.
function N.arm(log_fn)
    armed  = true
    logger = log_fn
    if log_fn then log_fn("INFO", "Natives armadas (hilo de script activo)") end
end

function N.is_armed() return armed end

--- Registro de llamadas rechazadas, para depurar problemas de hilo.
function N.blocked_report()
    local out = {}
    for name, count in pairs(blocked) do out[#out + 1] = { name = name, count = count } end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

local function refuse(name)
    blocked[name] = (blocked[name] or 0) + 1
    if blocked[name] == 1 and logger then
        logger("ERROR", "Native '" .. name .. "' llamada FUERA del hilo de script. "
            .. "Se ha bloqueado para evitar un cierre del juego.")
    end
    return nil
end

local InvokeVoid  = Natives.InvokeVoid
local InvokeInt   = Natives.InvokeInt
local InvokeBool  = Natives.InvokeBool
local InvokeFloat = Natives.InvokeFloat
local InvokeV3    = Natives.InvokeV3

N.ENTITY = _G.ENTITY or {}
if not N.ENTITY.SET_ENTITY_ROTATION then N.ENTITY.SET_ENTITY_ROTATION = function(...) if not armed then return refuse("ENTITY.SET_ENTITY_ROTATION") end return InvokeVoid(0x8524A8B0171D5E07, ...) end end
if not N.ENTITY.FREEZE_ENTITY_POSITION then N.ENTITY.FREEZE_ENTITY_POSITION = function(...) if not armed then return refuse("ENTITY.FREEZE_ENTITY_POSITION") end return InvokeVoid(0x428CA6DBD1094446, ...) end end
if not N.ENTITY.SET_ENTITY_COLLISION then N.ENTITY.SET_ENTITY_COLLISION = function(...) if not armed then return refuse("ENTITY.SET_ENTITY_COLLISION") end return InvokeVoid(0x1A9205C1B9EE827F, ...) end end
if not N.ENTITY.IS_ENTITY_DEAD then N.ENTITY.IS_ENTITY_DEAD = function(...) if not armed then return refuse("ENTITY.IS_ENTITY_DEAD") end return InvokeBool(0x5F9532F3B5CC2551, ...) end end
if not N.ENTITY.DELETE_ENTITY then N.ENTITY.DELETE_ENTITY = function(...) if not armed then return refuse("ENTITY.DELETE_ENTITY") end return InvokeVoid(0xAE3CBE5BF394C9C9, ...) end end
if not N.ENTITY.SET_ENTITY_AS_MISSION_ENTITY then N.ENTITY.SET_ENTITY_AS_MISSION_ENTITY = function(...) if not armed then return refuse("ENTITY.SET_ENTITY_AS_MISSION_ENTITY") end return InvokeVoid(0xAD738C3085FE7E11, ...) end end
if not N.ENTITY.SET_ENTITY_HEADING then N.ENTITY.SET_ENTITY_HEADING = function(...) if not armed then return refuse("ENTITY.SET_ENTITY_HEADING") end return InvokeVoid(0x8E2530AA8ADA980E, ...) end end
if not N.ENTITY.DOES_ENTITY_EXIST then N.ENTITY.DOES_ENTITY_EXIST = function(...) if not armed then return refuse("ENTITY.DOES_ENTITY_EXIST") end return InvokeBool(0x7239B21A38F536BA, ...) end end
if not N.ENTITY.GET_ENTITY_COORDS then N.ENTITY.GET_ENTITY_COORDS = function(...) if not armed then return refuse("ENTITY.GET_ENTITY_COORDS") end return InvokeV3(0x3FEF770D40960D5A, ...) end end
if not N.ENTITY.GET_ENTITY_HEADING then N.ENTITY.GET_ENTITY_HEADING = function(...) if not armed then return refuse("ENTITY.GET_ENTITY_HEADING") end return InvokeFloat(0xE83D4F9BA2A38914, ...) end end
if not N.ENTITY.GET_ENTITY_FORWARD_VECTOR then N.ENTITY.GET_ENTITY_FORWARD_VECTOR = function(...) if not armed then return refuse("ENTITY.GET_ENTITY_FORWARD_VECTOR") end return InvokeV3(0x0A794A5A57F8DF91, ...) end end

N.STREAMING = _G.STREAMING or {}
if not N.STREAMING.REQUEST_MODEL then N.STREAMING.REQUEST_MODEL = function(...) if not armed then return refuse("STREAMING.REQUEST_MODEL") end return InvokeVoid(0x963D27A58DF860AC, ...) end end
if not N.STREAMING.HAS_MODEL_LOADED then N.STREAMING.HAS_MODEL_LOADED = function(...) if not armed then return refuse("STREAMING.HAS_MODEL_LOADED") end return InvokeBool(0x98A4EB5D89A0C952, ...) end end
if not N.STREAMING.SET_MODEL_AS_NO_LONGER_NEEDED then N.STREAMING.SET_MODEL_AS_NO_LONGER_NEEDED = function(...) if not armed then return refuse("STREAMING.SET_MODEL_AS_NO_LONGER_NEEDED") end return InvokeVoid(0xE532F5D78798DAAB, ...) end end
if not N.STREAMING.IS_MODEL_VALID then N.STREAMING.IS_MODEL_VALID = function(...) if not armed then return refuse("STREAMING.IS_MODEL_VALID") end return InvokeBool(0xC0296A2EDF545E92, ...) end end
if not N.STREAMING.IS_MODEL_IN_CDIMAGE then N.STREAMING.IS_MODEL_IN_CDIMAGE = function(...) if not armed then return refuse("STREAMING.IS_MODEL_IN_CDIMAGE") end return InvokeBool(0x35B9E0803292B641, ...) end end

N.OBJECT = _G.OBJECT or {}
if not N.OBJECT.CREATE_OBJECT then N.OBJECT.CREATE_OBJECT = function(...) if not armed then return refuse("OBJECT.CREATE_OBJECT") end return InvokeInt(0x509D5878EB39E842, ...) end end

N.PED = _G.PED or {}
if not N.PED.CREATE_PED then N.PED.CREATE_PED = function(...) if not armed then return refuse("PED.CREATE_PED") end return InvokeInt(0xD49F9B0955C367DE, ...) end end

N.PLAYER = _G.PLAYER or {}
if not N.PLAYER.PLAYER_PED_ID then N.PLAYER.PLAYER_PED_ID = function(...) if not armed then return refuse("PLAYER.PLAYER_PED_ID") end return InvokeInt(0xD80958FC74E988A6, ...) end end

N.WEAPON = _G.WEAPON or {}
if not N.WEAPON.GIVE_DELAYED_WEAPON_TO_PED then N.WEAPON.GIVE_DELAYED_WEAPON_TO_PED = function(...) if not armed then return refuse("WEAPON.GIVE_DELAYED_WEAPON_TO_PED") end return InvokeVoid(0xB282DC6EBD803C75, ...) end end

N.TASK = _G.TASK or {}
if not N.TASK.TASK_COMBAT_PED then N.TASK.TASK_COMBAT_PED = function(...) if not armed then return refuse("TASK.TASK_COMBAT_PED") end return InvokeVoid(0xF166E48407BAC484, ...) end end

N.HUD = _G.HUD or {}
if not N.HUD.ADD_BLIP_FOR_COORD then N.HUD.ADD_BLIP_FOR_COORD = function(...) if not armed then return refuse("HUD.ADD_BLIP_FOR_COORD") end return InvokeInt(0x5A039BB0BCA604B6, ...) end end
if not N.HUD.REMOVE_BLIP then N.HUD.REMOVE_BLIP = function(...) if not armed then return refuse("HUD.REMOVE_BLIP") end return InvokeVoid(0x86A652570E5F25DD, ...) end end
if not N.HUD.SET_BLIP_COLOUR then N.HUD.SET_BLIP_COLOUR = function(...) if not armed then return refuse("HUD.SET_BLIP_COLOUR") end return InvokeVoid(0x03D7FB09E75D6B7E, ...) end end
if not N.HUD.SET_BLIP_SPRITE then N.HUD.SET_BLIP_SPRITE = function(...) if not armed then return refuse("HUD.SET_BLIP_SPRITE") end return InvokeVoid(0xDF735600A4696DAF, ...) end end
if not N.HUD.SET_TEXT_FONT then N.HUD.SET_TEXT_FONT = function(...) if not armed then return refuse("HUD.SET_TEXT_FONT") end return InvokeVoid(0x66E0276CC5F6B9DA, ...) end end
if not N.HUD.SET_TEXT_SCALE then N.HUD.SET_TEXT_SCALE = function(...) if not armed then return refuse("HUD.SET_TEXT_SCALE") end return InvokeVoid(0x07C837F9A01C34C9, ...) end end
if not N.HUD.SET_TEXT_COLOUR then N.HUD.SET_TEXT_COLOUR = function(...) if not armed then return refuse("HUD.SET_TEXT_COLOUR") end return InvokeVoid(0xBE6B23FFA53FB442, ...) end end
if not N.HUD.SET_TEXT_CENTRE then N.HUD.SET_TEXT_CENTRE = function(...) if not armed then return refuse("HUD.SET_TEXT_CENTRE") end return InvokeVoid(0xC02F4DBFB51D988B, ...) end end
if not N.HUD.SET_TEXT_OUTLINE then N.HUD.SET_TEXT_OUTLINE = function(...) if not armed then return refuse("HUD.SET_TEXT_OUTLINE") end return InvokeVoid(0x2513DFB0FB8400FE, ...) end end
if not N.HUD.SET_TEXT_DROP_SHADOW then N.HUD.SET_TEXT_DROP_SHADOW = function(...) if not armed then return refuse("HUD.SET_TEXT_DROP_SHADOW") end return InvokeVoid(0x1CA3E9EAC9D93E5E, ...) end end
if not N.HUD.BEGIN_TEXT_COMMAND_DISPLAY_TEXT then N.HUD.BEGIN_TEXT_COMMAND_DISPLAY_TEXT = function(...) if not armed then return refuse("HUD.BEGIN_TEXT_COMMAND_DISPLAY_TEXT") end return InvokeVoid(0x25FBB336DF1804CB, ...) end end
if not N.HUD.END_TEXT_COMMAND_DISPLAY_TEXT then N.HUD.END_TEXT_COMMAND_DISPLAY_TEXT = function(...) if not armed then return refuse("HUD.END_TEXT_COMMAND_DISPLAY_TEXT") end return InvokeVoid(0xCD015E5BB0D96A57, ...) end end
if not N.HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME then N.HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME = function(...) if not armed then return refuse("HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME") end return InvokeVoid(0x6C188BE134E074AA, ...) end end

N.GRAPHICS = _G.GRAPHICS or {}
if not N.GRAPHICS.DRAW_MARKER then N.GRAPHICS.DRAW_MARKER = function(...) if not armed then return refuse("GRAPHICS.DRAW_MARKER") end return InvokeVoid(0x28477EC23D892089, ...) end end
if not N.GRAPHICS.DRAW_RECT then N.GRAPHICS.DRAW_RECT = function(...) if not armed then return refuse("GRAPHICS.DRAW_RECT") end return InvokeVoid(0x3A618A217E5154F0, ...) end end

N.CAM = _G.CAM or {}
if not N.CAM.CREATE_CAM then N.CAM.CREATE_CAM = function(...) if not armed then return refuse("CAM.CREATE_CAM") end return InvokeInt(0xC3981DCE61D9E13F, ...) end end
if not N.CAM.SET_CAM_COORD then N.CAM.SET_CAM_COORD = function(...) if not armed then return refuse("CAM.SET_CAM_COORD") end return InvokeVoid(0x4D41783FB745E42E, ...) end end
if not N.CAM.POINT_CAM_AT_COORD then N.CAM.POINT_CAM_AT_COORD = function(...) if not armed then return refuse("CAM.POINT_CAM_AT_COORD") end return InvokeVoid(0xF75497BB865F0803, ...) end end
if not N.CAM.RENDER_SCRIPT_CAMS then N.CAM.RENDER_SCRIPT_CAMS = function(...) if not armed then return refuse("CAM.RENDER_SCRIPT_CAMS") end return InvokeVoid(0x07E5B515DB0636FC, ...) end end
if not N.CAM.DESTROY_CAM then N.CAM.DESTROY_CAM = function(...) if not armed then return refuse("CAM.DESTROY_CAM") end return InvokeVoid(0x865908C81A2C22E9, ...) end end
if not N.CAM.SET_CAM_ROT then N.CAM.SET_CAM_ROT = function(...) if not armed then return refuse("CAM.SET_CAM_ROT") end return InvokeVoid(0x85973643155D0B07, ...) end end
if not N.CAM.SET_CAM_FOV then N.CAM.SET_CAM_FOV = function(...) if not armed then return refuse("CAM.SET_CAM_FOV") end return InvokeVoid(0xB13C14F66A00D047, ...) end end
if not N.CAM.SET_CAM_ACTIVE then N.CAM.SET_CAM_ACTIVE = function(...) if not armed then return refuse("CAM.SET_CAM_ACTIVE") end return InvokeVoid(0x026FB97D0A425F84, ...) end end
if not N.CAM.SHAKE_CAM then N.CAM.SHAKE_CAM = function(...) if not armed then return refuse("CAM.SHAKE_CAM") end return InvokeVoid(0x6A25241C340D3822, ...) end end
if not N.CAM.STOP_CAM_SHAKING then N.CAM.STOP_CAM_SHAKING = function(...) if not armed then return refuse("CAM.STOP_CAM_SHAKING") end return InvokeVoid(0xBDECF64367884AC3, ...) end end
if not N.CAM.DO_SCREEN_FADE_IN then N.CAM.DO_SCREEN_FADE_IN = function(...) if not armed then return refuse("CAM.DO_SCREEN_FADE_IN") end return InvokeVoid(0xD4E8E24955024033, ...) end end
if not N.CAM.DO_SCREEN_FADE_OUT then N.CAM.DO_SCREEN_FADE_OUT = function(...) if not armed then return refuse("CAM.DO_SCREEN_FADE_OUT") end return InvokeVoid(0x891B5B39AC6302AF, ...) end end
if not N.CAM.IS_SCREEN_FADED_OUT then N.CAM.IS_SCREEN_FADED_OUT = function(...) if not armed then return refuse("CAM.IS_SCREEN_FADED_OUT") end return InvokeBool(0xB16FCE9DDC7BA182, ...) end end
if not N.CAM.POINT_CAM_AT_ENTITY then N.CAM.POINT_CAM_AT_ENTITY = function(...) if not armed then return refuse("CAM.POINT_CAM_AT_ENTITY") end return InvokeVoid(0x5640BFF86B16E8DC, ...) end end

N.AUDIO = _G.AUDIO or {}
if not N.AUDIO.PLAY_SOUND_FRONTEND then N.AUDIO.PLAY_SOUND_FRONTEND = function(...) if not armed then return refuse("AUDIO.PLAY_SOUND_FRONTEND") end return InvokeVoid(0x67C540AA08E4A6F5, ...) end end

N.MISC = _G.MISC or {}
if not N.MISC.GET_GAME_TIMER then N.MISC.GET_GAME_TIMER = function(...) if not armed then return refuse("MISC.GET_GAME_TIMER") end return InvokeInt(0x9CD27B0045628463, ...) end end
if not N.MISC.GET_GROUND_Z_FOR_3D_COORD then N.MISC.GET_GROUND_Z_FOR_3D_COORD = function(...) if not armed then return refuse("MISC.GET_GROUND_Z_FOR_3D_COORD") end return InvokeBool(0xC906A7DAB05C8D2B, ...) end end


--==============================================================================
-- Verificación de hashes
--   Un hash equivocado invocaría otra native con argumentos ajenos. Sólo puede
--   ejecutarse con el módulo armado, es decir, desde el bucle.
--==============================================================================

function N.verify()
    if not armed then
        return { ok = 0, failed = 1,
                 problems = { "verify() llamada antes de N.arm(): sin hilo de script" } }
    end

    local r = { ok = 0, failed = 0, problems = {} }
    local function check(name, cond, detail)
        if cond then r.ok = r.ok + 1
        else
            r.failed = r.failed + 1
            r.problems[#r.problems + 1] = name .. (detail and (": " .. tostring(detail)) or "")
        end
    end

    local t = N.MISC.GET_GAME_TIMER()
    check("GET_GAME_TIMER", type(t) == "number" and t >= 0, t)

    local ped = N.PLAYER.PLAYER_PED_ID()
    check("PLAYER_PED_ID", type(ped) == "number" and ped ~= 0, ped)
    check("DOES_ENTITY_EXIST", N.ENTITY.DOES_ENTITY_EXIST(ped) == true)

    local h = N.ENTITY.GET_ENTITY_HEADING(ped)
    check("GET_ENTITY_HEADING", type(h) == "number" and h >= -1 and h <= 361, h)

    check("IS_MODEL_VALID(válido)",
          N.STREAMING.IS_MODEL_VALID(Utils.Joaat("prop_barrier_work05")) == true)
    check("IS_MODEL_VALID(inventado)",
          N.STREAMING.IS_MODEL_VALID(Utils.Joaat("no_existe_este_modelo_xyz")) == false)

    return r
end

--==============================================================================
-- Ayudantes de texto en pantalla
--==============================================================================

--- @param x,y  coordenadas de pantalla 0..1
function N.draw_text(text, x, y, opts)
    if not armed then return end
    opts = opts or {}
    N.HUD.SET_TEXT_FONT(opts.font or 4)
    N.HUD.SET_TEXT_SCALE(opts.scale or 0.5, opts.scale or 0.5)
    N.HUD.SET_TEXT_COLOUR(opts.r or 255, opts.g or 255, opts.b or 255, opts.a or 255)
    if opts.centre ~= false then N.HUD.SET_TEXT_CENTRE(true) end
    if opts.outline ~= false then N.HUD.SET_TEXT_OUTLINE() end
    if opts.shadow then N.HUD.SET_TEXT_DROP_SHADOW() end
    N.HUD.BEGIN_TEXT_COMMAND_DISPLAY_TEXT("STRING")
    N.HUD.ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME(tostring(text))
    N.HUD.END_TEXT_COMMAND_DISPLAY_TEXT(x, y, 0)
end

function N.draw_rect(x, y, w, h, r, g, b, a)
    if not armed then return end
    N.GRAPHICS.DRAW_RECT(x, y, w, h, r or 0, g or 0, b or 0, a or 150, false)
end

return N
