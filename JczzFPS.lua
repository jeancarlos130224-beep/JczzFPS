--[[
    Jczz FPS  —  by: Jeannxx7_
    Otimizador VISUAL (somente cliente) para Steal a Egg, focado em celulares fracos.

    O que ele NÃO faz (de propósito):
      - não mexe em RemoteEvents, economia, inventário, mecânicas ou outros jogadores
      - não remove/destrói objetos do mapa (só altera propriedades visuais e guarda o valor original)
      - não promete FPS fixo: extrai o melhor que o aparelho consegue

    Arquitetura:
      1. Utilidades e detecção de capacidades (probe)
      2. Sistema de "features": cada otimização guarda o estado original -> restaurável
      3. Perfis (PERFORMANCE / LOW / VERY LOW / POTATO / INSANE / POTATO EXTREME)
      4. Smart Performance Detection + Auto Optimizer (com tolerância e cooldown)
      5. Interface compacta (botão flutuante + painel com 5 categorias)

    Fluxo de cada otimização:  Detectar -> verificar suporte -> aplicar -> confirmar -> continuar
    Se não houver suporte:     Detectar -> indisponível -> ignorar -> continuar
]]

--------------------------------------------------------------------------------
-- 0. SERVIÇOS E UTILIDADES BÁSICAS
--------------------------------------------------------------------------------
local function getService(name)
	local ok, s = pcall(function() return game:GetService(name) end)
	if ok then return s end
	return nil
end

if not game:IsLoaded() then game.Loaded:Wait() end

local Players          = getService("Players")
local RunService       = getService("RunService")
local UserInputService = getService("UserInputService")
local Lighting         = getService("Lighting")
local Stats            = getService("Stats")
local Workspace        = getService("Workspace")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	task.wait()
	LocalPlayer = Players.LocalPlayer
end

-- Ambiente global (getgenv se existir, senão _G). Nunca assume que getgenv existe.
local genv
do
	local ok, g = pcall(function() return getgenv() end)
	genv = (ok and type(g) == "table") and g or _G
end

-- Busca uma função opcional do executor (ex.: setfpscap) sem causar erro se não existir.
local function getFn(name)
	local ok, v = pcall(function() return getfenv()[name] end)
	if ok and type(v) == "function" then return v end
	ok, v = pcall(function() return genv[name] end)
	if ok and type(v) == "function" then return v end
	return nil
end

-- Evita executar duas vezes: descarrega a instância anterior (restaurando tudo).
if genv.__JczzFPS and type(genv.__JczzFPS.Unload) == "function" then
	pcall(genv.__JczzFPS.Unload)
end

local function median(t)
	local n = #t
	if n == 0 then return 0 end
	local c = table.clone(t)
	table.sort(c)
	return c[math.ceil(n / 2)]
end

--------------------------------------------------------------------------------
-- 1. ESTADO GLOBAL E DETECÇÃO DE CAPACIDADES
--------------------------------------------------------------------------------
local State = {
	mode = nil,        -- nome do perfil atual (nil = original)
	auto = false,      -- true quando o perfil veio do AUTO
	fps = 60,
	ping = nil,
	renderOff = false, -- render 3D desligado (economia)
	busy = false,      -- scan do mapa em andamento
	detecting = false, -- análise do dispositivo em andamento
	watchNew = true,   -- otimizar objetos novos que aparecem depois
	caps = {},
	device = nil,
}

-- Testa (sem alterar nada de fato) o que este ambiente realmente permite.
-- Regrava o mesmo valor: se der erro, a API não está disponível/permitida aqui.
local function probe()
	local c = {}
	c.quality    = pcall(function() local r = settings().Rendering; r.QualityLevel = r.QualityLevel end)
	c.meshDetail = pcall(function() local r = settings().Rendering; r.MeshPartDetailLevel = r.MeshPartDetailLevel end)
	c.technology = pcall(function() Lighting.Technology = Lighting.Technology end)
	c.decoration = pcall(function() local t = Workspace.Terrain; t.Decoration = t.Decoration end)
	c.render3d   = pcall(function() return RunService.Set3dRenderingEnabled end)
	c.fpsCap     = getFn("setfpscap") ~= nil
	c.gethui     = getFn("gethui") ~= nil
	return c
end
State.caps = probe()

--------------------------------------------------------------------------------
-- 2. SISTEMA DE FEATURES COM RESTAURAÇÃO
--    Active[feature]  = valor ativo (nil = desligada)
--    Saved[feature]   = { [instância] = { [propriedade] = valorOriginal } }
--------------------------------------------------------------------------------
local Active, Saved = {}, {}
local UI = { refresh = function() end, toast = function(_) end }

local function remember(feat, inst, prop, orig)
	local s = Saved[feat]
	if not s then
		s = setmetatable({}, { __mode = "k" }) -- chaves fracas: objetos destruídos não vazam memória
		Saved[feat] = s
	end
	local r = s[inst]
	if not r then r = {}; s[inst] = r end
	if r[prop] == nil then r[prop] = orig end -- guarda só o PRIMEIRO valor (o original)
end

-- Altera propriedade com segurança: verifica existência, guarda original, confirma.
local function setProp(feat, inst, prop, value)
	local ok, cur = pcall(function() return inst[prop] end)
	if not ok or cur == nil then return false end       -- propriedade não existe aqui
	if cur == value then return true end                -- já está assim, nada a fazer
	local ok2 = pcall(function() inst[prop] = value end)
	if ok2 then remember(feat, inst, prop, cur) end
	return ok2
end

local function restoreFeature(feat)
	local s = Saved[feat]
	if s then
		for inst, props in pairs(s) do
			for prop, val in pairs(props) do
				pcall(function() inst[prop] = val end)
			end
		end
	end
	Saved[feat] = nil
end

local function getTerrain()
	return Workspace:FindFirstChildOfClass("Terrain")
end

-- Categorias de classes que o scan reconhece (lookup O(1) por ClassName)
local CAT = {
	ParticleEmitter = "emitter", Fire = "fx", Smoke = "fx", Sparkles = "fx",
	Trail = "trail", Beam = "trail",
	PointLight = "light", SpotLight = "light", SurfaceLight = "light",
	Texture = "texture",
	BloomEffect = "post", BlurEffect = "post", ColorCorrectionEffect = "post",
	DepthOfFieldEffect = "post", SunRaysEffect = "post",
	Atmosphere = "atmo", Clouds = "clouds",
}

-- Features que dependem de varrer instâncias do mundo
local WORLD = {
	particles = true, trails = true, lightShadows = true, lightsOff = true,
	textures = true, postfx = true, atmosphere = true,
	partShadows = true, reflectance = true, materials = true, meshFidelity = true,
}

-- Materiais que NÃO trocamos (podem ter função visual importante)
local SKIP_MAT = {}
for _, n in ipairs({ "Neon", "ForceField", "Glass" }) do
	pcall(function() SKIP_MAT[Enum.Material[n]] = true end)
end

-- Personagens (jogadores e NPCs com Humanoid) nunca são tocados.
local charCache = setmetatable({}, { __mode = "k" })
local function inCharacter(inst)
	local m = inst:FindFirstAncestorWhichIsA("Model")
	if not m then return false end
	if Players:GetPlayerFromCharacter(m) then return true end
	local c = charCache[m]
	if c == nil then
		c = m:FindFirstChildOfClass("Humanoid") ~= nil
		charCache[m] = c
	end
	return c
end

local function on(feat, only)
	local v = Active[feat]
	if v == nil then return nil end
	if only and not only[feat] then return nil end
	return v
end

-- Aplica todas as features de mundo ativas a UMA instância.
local function processInstance(inst, only)
	local cls = inst.ClassName
	local cat = CAT[cls]

	if cat then
		if cat == "post" then
			if on("postfx", only) then setProp("postfx", inst, "Enabled", false) end
			return
		elseif cat == "atmo" then
			if on("atmosphere", only) then
				setProp("atmosphere", inst, "Density", 0)
				setProp("atmosphere", inst, "Haze", 0)
				setProp("atmosphere", inst, "Glare", 0)
			end
			return
		elseif cat == "clouds" then
			if on("atmosphere", only) then setProp("atmosphere", inst, "Enabled", false) end
			return
		end

		if inCharacter(inst) then return end

		if cat == "emitter" then
			local m = on("particles", only)
			if m then
				if m <= 0 then
					setProp("particles", inst, "Enabled", false)
				else
					local s = Saved.particles and Saved.particles[inst]
					local base = (s and s.Rate) or inst.Rate -- sempre relativo ao Rate ORIGINAL
					setProp("particles", inst, "Rate", base * m)
				end
			end
		elseif cat == "fx" then
			local m = on("particles", only)
			if m and m <= 0 then setProp("particles", inst, "Enabled", false) end
		elseif cat == "trail" then
			if on("trails", only) then setProp("trails", inst, "Enabled", false) end
		elseif cat == "light" then
			if on("lightShadows", only) then setProp("lightShadows", inst, "Shadows", false) end
			if on("lightsOff", only) then setProp("lightsOff", inst, "Enabled", false) end
		elseif cat == "texture" then
			if on("textures", only) then setProp("textures", inst, "Transparency", 1) end
		end
		return
	end

	-- Partes (BasePart) — só checa se alguma feature de parte está ligada
	if Active.partShadows ~= nil or Active.reflectance ~= nil
		or Active.materials ~= nil or Active.meshFidelity ~= nil then
		if cls ~= "Terrain" and inst:IsA("BasePart") then
			if inCharacter(inst) then return end
			if on("partShadows", only) then setProp("partShadows", inst, "CastShadow", false) end
			if on("reflectance", only) and inst.Reflectance ~= 0 then
				setProp("reflectance", inst, "Reflectance", 0)
			end
			if on("materials", only) and not SKIP_MAT[inst.Material] then
				setProp("materials", inst, "Material", Enum.Material.SmoothPlastic)
			end
			if cls == "MeshPart" and on("meshFidelity", only) then
				setProp("meshFidelity", inst, "RenderFidelity", Enum.RenderFidelity.Performance)
			end
		end
	end
end

-- Varredura do mapa em fatias de ~4ms para não travar o jogo.
local function runScan(only)
	local t0, n = os.clock(), 0
	for _, root in ipairs({ Workspace, Lighting }) do
		local ok, list = pcall(function() return root:GetDescendants() end)
		if ok then
			for i = 1, #list do
				pcall(processInstance, list[i], only)
				n += 1
				if n % 64 == 0 and os.clock() - t0 > 0.004 then
					task.wait()
					t0 = os.clock()
				end
			end
		end
	end
end

local Scan = { running = false, pending = {} }
local function requestScan(set)
	for k in pairs(set) do Scan.pending[k] = true end
	if Scan.running then return end
	Scan.running = true
	task.spawn(function()
		while next(Scan.pending) do
			local only = Scan.pending
			Scan.pending = {}
			State.busy = true
			runScan(only)
		end
		State.busy = false
		Scan.running = false
		UI.refresh()
	end)
end

-- Observa objetos NOVOS (uma única fila leve, processada em lotes a cada 0.4s).
local Watch = { conns = {}, queue = {}, running = false }
local function onAdded(inst)
	Watch.queue[#Watch.queue + 1] = inst
	if Watch.running then return end
	Watch.running = true
	task.spawn(function()
		while #Watch.queue > 0 do
			task.wait(0.4)
			local q = Watch.queue
			Watch.queue = {}
			local t0 = os.clock()
			for i = 1, #q do
				pcall(processInstance, q[i], nil)
				if i % 32 == 0 and os.clock() - t0 > 0.003 then
					task.wait()
					t0 = os.clock()
				end
			end
		end
		Watch.running = false
	end)
end

local function syncWatch()
	local need = false
	if State.watchNew then
		for f in pairs(WORLD) do
			if Active[f] ~= nil then need = true; break end
		end
	end
	if need and #Watch.conns == 0 then
		Watch.conns[1] = Workspace.DescendantAdded:Connect(onAdded)
		Watch.conns[2] = Lighting.DescendantAdded:Connect(onAdded)
	elseif not need and #Watch.conns > 0 then
		for _, c in ipairs(Watch.conns) do c:Disconnect() end
		Watch.conns = {}
		Watch.queue = {}
	end
end

-- Features GLOBAIS (aplicadas uma única vez). apply() devolve true se houve suporte.
-- cap = chave de State.caps usada para marcar botões como indisponíveis.
local F = {}

F.quality = { cap = "quality", apply = function(level)
	local ok, r = pcall(function() return settings().Rendering end)
	if not ok then return false end
	local enum
	pcall(function() enum = Enum.QualityLevel:FromValue(level) end)
	if not enum then return false end
	return setProp("quality", r, "QualityLevel", enum)
end }

F.globalShadows = { apply = function()
	local a = setProp("globalShadows", Lighting, "GlobalShadows", false)
	local b = setProp("globalShadows", Lighting, "ShadowSoftness", 0)
	return a or b
end }

F.envLight = { apply = function()
	local a = setProp("envLight", Lighting, "EnvironmentDiffuseScale", 0)
	local b = setProp("envLight", Lighting, "EnvironmentSpecularScale", 0)
	return a or b
end }

F.technology = { cap = "technology", apply = function()
	local ok, e = pcall(function() return Enum.Technology.Compatibility end)
	if not ok then return false end
	return setProp("technology", Lighting, "Technology", e)
end }

F.water = { apply = function()
	local t = getTerrain()
	if not t then return false end
	local a = setProp("water", t, "WaterWaveSize", 0)
	local b = setProp("water", t, "WaterWaveSpeed", 0)
	local c = setProp("water", t, "WaterReflectance", 0)
	return a or b or c
end }

F.decoration = { cap = "decoration", apply = function()
	local t = getTerrain()
	if not t then return false end
	return setProp("decoration", t, "Decoration", false)
end }

F.meshDetail = { cap = "meshDetail", apply = function()
	local ok, r = pcall(function() return settings().Rendering end)
	if not ok then return false end
	local ok2, lvl = pcall(function() return Enum.MeshPartDetailLevel.Level04 end)
	if not ok2 then return false end
	return setProp("meshDetail", r, "MeshPartDetailLevel", lvl)
end }

-- Economia de bateria: desliga o render 3D (tela do jogo fica preta). Restaurável.
F.render3d = { cap = "render3d",
	apply = function()
		local ok = pcall(function() RunService:Set3dRenderingEnabled(false) end)
		if ok then State.renderOff = true end
		return ok
	end,
	restore = function()
		pcall(function() RunService:Set3dRenderingEnabled(true) end)
		State.renderOff = false
	end }

-- Limite de FPS: só existe em alguns executores (setfpscap).
local origFpsCap
F.fpsCap = { cap = "fpsCap",
	apply = function(v)
		local set = getFn("setfpscap")
		if not set then return false end
		if origFpsCap == nil then
			local get = getFn("getfpscap")
			if get then
				local ok, cur = pcall(get)
				if ok and type(cur) == "number" then origFpsCap = cur end
			end
			origFpsCap = origFpsCap or 60 -- padrão do Roblox quando não dá para ler
		end
		return (pcall(set, v))
	end,
	restore = function()
		local set = getFn("setfpscap")
		if set then pcall(set, origFpsCap or 60) end
	end }

for name in pairs(WORLD) do F[name] = F[name] or { world = true }
end

local function disableFeature(feat)
	Active[feat] = nil -- primeiro desativa (o scan em andamento para de aplicar)
	local def = F[feat]
	if def and def.restore then pcall(def.restore) end
	restoreFeature(feat)
end

-- Liga uma feature. `set` (opcional) acumula features de mundo para um único scan.
local function enableFeature(feat, val, set)
	local def = F[feat]
	if not def then return false end
	if def.world then
		Active[feat] = val
		if set then set[feat] = true else requestScan({ [feat] = true }) end
		syncWatch()
		return true
	end
	if def.cap and State.caps[def.cap] == false then return false end -- suporte já negado no probe
	local ok = false
	local okc, res = pcall(def.apply, val)
	if okc then ok = res and true or false end
	if ok then
		Active[feat] = val
	else
		restoreFeature(feat) -- desfaz alteração parcial, se houve
	end
	return ok
end

local function restoreAll()
	for feat in pairs(Active) do disableFeature(feat) end
	for feat in pairs(Saved) do restoreFeature(feat) end
	syncWatch()
end

--------------------------------------------------------------------------------
-- 3. PERFIS
--------------------------------------------------------------------------------
local function extend(base, extra)
	local t = table.clone(base)
	for k, v in pairs(extra) do t[k] = v end
	return t
end

local P1 = { quality = 10, globalShadows = true, postfx = true, particles = 0.5, lightShadows = true, water = true }
local P2 = extend(P1, { quality = 6, atmosphere = true, particles = 0.3, trails = true, decoration = true, partShadows = true })
local P3 = extend(P2, { quality = 3, particles = 0, reflectance = true, meshDetail = true })
local P4 = extend(P3, { quality = 1, materials = true, meshFidelity = true, technology = true })
local P5 = extend(P4, { envLight = true })                           -- INSANE
local P6 = extend(P5, { lightsOff = true, textures = true })         -- POTATO EXTREME

local PROFILES = {
	["PERFORMANCE"]    = { order = 1, f = P1 },
	["LOW"]            = { order = 2, f = P2 },
	["VERY LOW"]       = { order = 3, f = P3 },
	["POTATO"]         = { order = 4, f = P4 },
	["INSANE"]         = { order = 5, f = P5 },
	["POTATO EXTREME"] = { order = 6, f = P6 },
}
local AUTO_LADDER = { "PERFORMANCE", "LOW", "VERY LOW", "POTATO" } -- o Auto nunca passa daqui

-- incremental = true: só soma otimizações (usado pelo Auto Optimizer, sem piscar a tela).
local function applyProfile(name, incremental)
	local p = PROFILES[name]
	if not p then return end
	if not incremental then restoreAll() end
	local set = {}
	for feat, val in pairs(p.f) do enableFeature(feat, val, set) end
	State.mode = name
	if next(set) then requestScan(set) end
	syncWatch()
	UI.refresh()
end

--------------------------------------------------------------------------------
-- 4. SMART PERFORMANCE DETECTION + AUTO OPTIMIZER
--------------------------------------------------------------------------------
local function smartDetect()
	-- (a) mede FPS real por ~3s (descarta a 1ª amostra)
	local samples, frames, acc = {}, 0, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		frames += 1
		acc += dt
		if acc >= 0.5 then
			samples[#samples + 1] = frames / acc
			frames, acc = 0, 0
		end
	end)
	task.wait(3.2)
	conn:Disconnect()
	if #samples > 1 then table.remove(samples, 1) end
	local fps = median(samples)
	if fps <= 0 then fps = State.fps end

	-- (b) conta efeitos existentes (partículas, luzes, pós-processamento...) em fatias
	local effects, n, t0 = 0, 0, os.clock()
	for _, root in ipairs({ Workspace, Lighting }) do
		local ok, list = pcall(function() return root:GetDescendants() end)
		if ok then
			for i = 1, #list do
				local c = CAT[list[i].ClassName]
				if c and c ~= "atmo" and c ~= "clouds" then effects += 1 end
				n += 1
				if n % 128 == 0 and os.clock() - t0 > 0.004 then task.wait(); t0 = os.clock() end
			end
		end
	end

	-- (c) demais informações (cada uma opcional)
	local vp = Vector2.new(0, 0)
	pcall(function() vp = Workspace.CurrentCamera.ViewportSize end)
	local mem = 0
	pcall(function() mem = Stats:GetTotalMemoryUsageMb() end)
	local quality = 0
	pcall(function() quality = settings().Rendering.QualityLevel.Value end)

	return {
		fps = fps, effects = effects, pixels = vp.X * vp.Y, vp = vp, mem = mem,
		quality = quality, touch = UserInputService.TouchEnabled,
	}
end

-- Pontuação simples -> perfil sugerido (nil = aparelho vai bem, não altera nada)
local function classify(info)
	local s, fps = 0, info.fps
	if fps < 20 then s += 4 elseif fps < 30 then s += 3 elseif fps < 45 then s += 2 elseif fps < 57 then s += 1 end
	if info.mem > 1500 then s += 1 end
	if info.pixels > 2000000 then s += 1 end
	if info.effects > 300 then s += 1 end
	if info.quality >= 8 and fps < 40 then s += 1 end
	if s >= 6 then return "POTATO" end
	if s >= 4 then return "VERY LOW" end
	if s >= 2 then return "LOW" end
	if s >= 1 then return "PERFORMANCE" end
	return nil
end

local function deviceText(info)
	if not info then return "Ainda não analisado. Toque em 'Reanalisar'." end
	return string.format("FPS medido: %d\nTela: %dx%d (%s)\nMemória em uso: %d MB\nEfeitos no mapa: %d\nQualidade atual: %d",
		math.floor(info.fps + 0.5), info.vp.X, info.vp.Y, info.touch and "toque" or "sem toque",
		math.floor(info.mem), info.effects, info.quality)
end

local AO = { on = true, samples = {}, settle = 0, cooldown = 20, window = 10, sens = 1 }
local SENS = { { "Normal", 30 }, { "Baixa", 22 }, { "Alta", 38 } }

local function runAuto()
	if State.detecting then return end
	State.detecting = true
	UI.toast("Analisando dispositivo (~5s)...")
	task.spawn(function()
		local info = smartDetect()
		State.device = info
		local prof = classify(info)
		State.auto = true
		if prof then
			applyProfile(prof, false)
			UI.toast("AUTO escolheu: " .. prof)
		else
			restoreAll()
			State.mode = nil
			UI.toast("Aparelho estável: nada alterado.")
		end
		AO.settle = os.clock() + 15
		AO.samples = {}
		State.detecting = false
		UI.refresh()
	end)
end

-- Auto Optimizer: só ESCALA quando a queda é persistente. Nunca alterna de volta
-- (evita stuttering). Zona neutra: acima do limite baixo, não mexe em nada.
local function aoStep(fps)
	if not AO.on or State.detecting or State.busy or State.renderOff then
		AO.samples = {}
		return
	end
	local now = os.clock()
	if now < AO.settle then AO.samples = {} return end
	local s = AO.samples
	s[#s + 1] = fps
	if #s > AO.window then table.remove(s, 1) end
	if #s < AO.window then return end
	if median(s) >= SENS[AO.sens][2] then return end -- estável: não altera nada

	local idx = 0
	for i, n in ipairs(AUTO_LADDER) do
		if n == State.mode then idx = i end
	end
	local order = State.mode and PROFILES[State.mode] and PROFILES[State.mode].order or 0
	if order > #AUTO_LADDER then return end -- INSANE/EXTREME: manual, Auto não interfere
	if idx >= #AUTO_LADDER then return end
	applyProfile(AUTO_LADDER[idx + 1], true)
	State.auto = true
	AO.settle = now + AO.cooldown
	AO.samples = {}
	UI.toast("Auto Optimizer: " .. AUTO_LADDER[idx + 1])
end

--------------------------------------------------------------------------------
-- 5. MONITOR LEVE (um único Heartbeat, trabalho real só 1x por segundo)
--------------------------------------------------------------------------------
local function readPing()
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	if ok and type(v) == "number" then return math.floor(v + 0.5) end
	return nil
end

local hbConn, secCount, frames, acc = nil, 0, 0, 0
local onSecond -- definido após a UI

hbConn = RunService.Heartbeat:Connect(function(dt)
	frames += 1
	acc += dt
	if acc >= 1 then
		State.fps = frames / acc
		frames, acc = 0, 0
		secCount += 1
		if onSecond then onSecond() end
	end
end)

--------------------------------------------------------------------------------
-- 6. INTERFACE
--------------------------------------------------------------------------------
local GREEN, YELLOW, RED = Color3.fromRGB(60, 210, 120), Color3.fromRGB(240, 200, 60), Color3.fromRGB(235, 70, 70)
local BG, BG2 = Color3.fromRGB(20, 22, 30), Color3.fromRGB(32, 35, 46)
local ACC, OFFC = Color3.fromRGB(0, 150, 120), Color3.fromRGB(46, 50, 66)
local TXT, GRAY = Color3.fromRGB(235, 238, 245), Color3.fromRGB(130, 134, 150)

local function mk(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function guiParent()
	local hui = getFn("gethui")
	if hui then
		local ok, p = pcall(hui)
		if ok and typeof(p) == "Instance" then return p end
	end
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok and cg then
		local t = Instance.new("Folder")
		local writable = pcall(function() t.Parent = cg end)
		t:Destroy()
		if writable then return cg end
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function statusOf(fps)
	if fps >= 45 then return "Optimized", GREEN end
	if fps >= 30 then return "Balanced", YELLOW end
	return "Low Performance", RED
end

local function countActive()
	local n = 0
	for _ in pairs(Active) do n += 1 end
	return n
end

local Gui, Panel, Controls = nil, nil, {}

local function buildUI()
	Gui = mk("ScreenGui", {
		Name = "JczzFPS", ResetOnSpawn = false, IgnoreGuiInset = true,
		DisplayOrder = 999, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, guiParent())

	local vp = Vector2.new(360, 640)
	pcall(function() vp = Workspace.CurrentCamera.ViewportSize end)
	local pw = math.min(330, vp.X - 16)
	local ph = math.min(330, vp.Y - 70)

	-- Botão flutuante (arrastável)
	local fab = mk("TextButton", {
		Name = "Fab", Size = UDim2.fromOffset(92, 30), Position = UDim2.new(0, 8, 0.35, 0),
		BackgroundColor3 = BG, TextColor3 = TXT, Text = "   Jczz FPS", Font = Enum.Font.GothamBold,
		TextSize = 13, AutoButtonColor = false,
	}, Gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 15) }, fab)
	mk("UIStroke", { Color = ACC, Thickness = 1.5 }, fab)
	local dot = mk("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, 10, 0.5, -5),
		BackgroundColor3 = GREEN }, fab)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)

	-- Painel
	Panel = mk("Frame", {
		Name = "Panel", Size = UDim2.fromOffset(pw, ph), AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 46), BackgroundColor3 = BG, Visible = false,
	}, Gui)
	mk("UICorner", { CornerRadius = UDim.new(0, 10) }, Panel)
	mk("UIStroke", { Color = ACC, Thickness = 1.2 }, Panel)

	mk("TextLabel", { Size = UDim2.new(0.6, 0, 0, 22), Position = UDim2.fromOffset(10, 4),
		BackgroundTransparency = 1, Text = "Jczz FPS", TextColor3 = TXT, Font = Enum.Font.GothamBold,
		TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left }, Panel)
	mk("TextLabel", { Size = UDim2.new(0.4, -40, 0, 22), Position = UDim2.new(0.5, 0, 0, 4),
		BackgroundTransparency = 1, Text = "by: Jeannxx7_", TextColor3 = GRAY, Font = Enum.Font.Gotham,
		TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right }, Panel)
	local closeBtn = mk("TextButton", { Size = UDim2.fromOffset(24, 22), Position = UDim2.new(1, -30, 0, 4),
		BackgroundTransparency = 1, Text = "✕", TextColor3 = TXT, Font = Enum.Font.GothamBold, TextSize = 14 }, Panel)

	-- Indicadores: FPS / Ping / Mode / Optimization Status
	local ind1 = mk("TextLabel", { Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(8, 28),
		BackgroundTransparency = 1, Text = "", TextColor3 = TXT, Font = Enum.Font.GothamMedium, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, Panel)
	local sdot = mk("Frame", { Size = UDim2.fromOffset(9, 9), Position = UDim2.fromOffset(10, 49),
		BackgroundColor3 = GREEN }, Panel)
	mk("UICorner", { CornerRadius = UDim.new(1, 0) }, sdot)
	local ind2 = mk("TextLabel", { Size = UDim2.new(1, -34, 0, 16), Position = UDim2.fromOffset(26, 45),
		BackgroundTransparency = 1, Text = "", TextColor3 = TXT, Font = Enum.Font.Gotham, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, Panel)

	-- Abas
	local tabBar = mk("Frame", { Size = UDim2.new(1, -12, 0, 24), Position = UDim2.fromOffset(6, 66),
		BackgroundTransparency = 1 }, Panel)
	mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3) }, tabBar)

	local toastLbl = mk("TextLabel", { Size = UDim2.new(1, -12, 0, 18), Position = UDim2.new(0, 6, 1, -20),
		BackgroundTransparency = 1, Text = "", TextColor3 = YELLOW, Font = Enum.Font.Gotham, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, Panel)

	local toastToken = 0
	UI.toast = function(msg)
		toastToken += 1
		local my = toastToken
		toastLbl.Text = msg
		task.delay(4, function() if my == toastToken then toastLbl.Text = "" end end)
	end

	local pages, tabBtns, built = {}, {}, {}
	local function newPage()
		local sf = mk("ScrollingFrame", {
			Size = UDim2.new(1, -10, 1, -(94 + 22)), Position = UDim2.fromOffset(5, 94),
			BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
			CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
		}, Panel)
		mk("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
		return sf
	end

	-- Controle genérico: render() -> texto, ligado?, indisponível?
	local function addControl(page, render, onClick)
		local b = mk("TextButton", { Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = OFFC,
			TextColor3 = TXT, Font = Enum.Font.GothamMedium, TextSize = 12, TextWrapped = true,
			AutoButtonColor = true, Text = "" }, page)
		mk("UICorner", { CornerRadius = UDim.new(0, 7) }, b)
		b.MouseButton1Click:Connect(function()
			local ok, err = pcall(onClick)
			if not ok then UI.toast("Não disponível neste ambiente.") end
			UI.refresh()
		end)
		Controls[#Controls + 1] = { btn = b, render = render }
		return b
	end

	local function addInfo(page, getText)
		local l = mk("TextLabel", { Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = BG2, TextColor3 = GRAY, Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left, Text = "" }, page)
		mk("UICorner", { CornerRadius = UDim.new(0, 7) }, l)
		mk("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
			PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, l)
		Controls[#Controls + 1] = { lbl = l, getText = getText }
	end

	local function unavailable(feat)
		local d = F[feat]
		return d and d.cap and State.caps[d.cap] == false
	end

	local function toggleFeature(feat, val)
		if Active[feat] ~= nil then
			disableFeature(feat)
		else
			if not enableFeature(feat, val) then UI.toast("Não disponível neste ambiente.") end
		end
		State.mode, State.auto = "CUSTOM", false
	end

	local function addFeatureToggle(page, label, feat, val)
		addControl(page, function()
			local on_ = Active[feat] ~= nil
			local un = unavailable(feat)
			return (on_ and "● " or "○ ") .. label .. (un and "  (indisp.)" or ""), on_, un
		end, function()
			if unavailable(feat) then UI.toast("Não disponível neste ambiente.") return end
			toggleFeature(feat, val)
		end)
	end

	-- Botão cíclico: Original -> v1 -> v2 ... -> Original
	local function addFeatureCycle(page, label, feat, values, fmt)
		addControl(page, function()
			local cur = Active[feat]
			local un = unavailable(feat)
			return "◐ " .. label .. ": " .. (cur ~= nil and fmt(cur) or "Original") .. (un and "  (indisp.)" or ""),
				cur ~= nil, un
		end, function()
			if unavailable(feat) then UI.toast("Não disponível neste ambiente.") return end
			local cur, idx = Active[feat], 0
			if cur ~= nil then
				for i, v in ipairs(values) do if v == cur then idx = i break end end
			end
			if idx >= #values then
				disableFeature(feat)
			elseif not enableFeature(feat, values[idx + 1]) then
				UI.toast("Não disponível neste ambiente.")
			end
			State.mode, State.auto = "CUSTOM", false
		end)
	end

	local function addProfile(page, label, name)
		addControl(page, function()
			return label, State.mode == name and not State.auto, false
		end, function()
			State.auto = false
			applyProfile(name, false)
			AO.settle = os.clock() + 10
			UI.toast("Perfil: " .. name)
		end)
	end

	-- ===== Páginas =====
	local builders = {}

	builders.PERFORMANCE = function(p)
		addControl(p, function() return "🤖 AUTO (detectar e adaptar)", State.auto and State.mode ~= "CUSTOM", false end, runAuto)
		addProfile(p, "PERFORMANCE", "PERFORMANCE")
		addProfile(p, "LOW", "LOW")
		addProfile(p, "VERY LOW", "VERY LOW")
		addProfile(p, "POTATO", "POTATO")
		addProfile(p, "🔥 INSANE FPS MODE", "INSANE")
		addProfile(p, "🥔 POTATO EXTREME", "POTATO EXTREME")
		addControl(p, function() return (AO.on and "● " or "○ ") .. "🤖 AUTO OPTIMIZER", AO.on, false end, function()
			AO.on = not AO.on
			AO.samples = {}
		end)
		addControl(p, function() return "🔄 RESTORE ALL", false, false end, function()
			restoreAll()
			State.mode, State.auto = nil, false
			AO.on = false
			AO.samples = {}
			UI.toast("Tudo restaurado. Auto Optimizer pausado.")
		end)
	end

	builders.GRAPHICS = function(p)
		addFeatureCycle(p, "Qualidade gráfica", "quality", { 10, 6, 3, 1 }, function(v) return "Nível " .. v end)
		addFeatureToggle(p, "Sombras globais OFF", "globalShadows", true)
		addFeatureToggle(p, "Pós-processamento OFF", "postfx", true)
		addFeatureToggle(p, "Atmosfera/Nuvens OFF", "atmosphere", true)
		addFeatureToggle(p, "Água simples", "water", true)
		addFeatureToggle(p, "Decoração do terreno OFF", "decoration", true)
		addFeatureToggle(p, "Detalhe de malha baixo", "meshDetail", true)
		addFeatureToggle(p, "Iluminação Compatibility", "technology", true)
		addFeatureToggle(p, "Reduzir luz ambiente", "envLight", true)
	end

	builders.EFFECTS = function(p)
		addFeatureCycle(p, "Partículas", "particles", { 0.5, 0 }, function(v)
			return v == 0 and "OFF" or (math.floor(v * 100) .. "%")
		end)
		addFeatureToggle(p, "Trails/Beams OFF", "trails", true)
		addFeatureToggle(p, "Sombras de luzes OFF", "lightShadows", true)
		addFeatureToggle(p, "Luzes locais OFF (agressivo)", "lightsOff", true)
		addFeatureToggle(p, "Texturas de superfície OFF", "textures", true)
		addFeatureToggle(p, "Reflexos OFF", "reflectance", true)
	end

	builders.MOBILE = function(p)
		addInfo(p, function() return deviceText(State.device) end)
		addControl(p, function() return "🔍 Reanalisar dispositivo (só medir)", false, false end, function()
			if State.detecting then return end
			State.detecting = true
			UI.toast("Medindo (~5s)...")
			task.spawn(function()
				State.device = smartDetect()
				State.detecting = false
				local sug = classify(State.device)
				UI.toast("Sugestão: " .. (sug or "nenhuma alteração"))
				UI.refresh()
			end)
		end)
		addFeatureToggle(p, "Sombras de partes OFF", "partShadows", true)
		addFeatureToggle(p, "Materiais simples", "materials", true)
		addFeatureToggle(p, "Malhas em modo Performance", "meshFidelity", true)
		addFeatureToggle(p, "Economia: 3D OFF (tela preta)", "render3d", true)
		addControl(p, function() return "🧹 Liberar memória (GC)", false, false end, function()
			local ok = pcall(function() collectgarbage("collect") end)
			UI.toast(ok and "Coleta de lixo executada." or "Não disponível neste ambiente.")
		end)
	end

	builders.ADVANCED = function(p)
		addControl(p, function() return "🎚 Sensibilidade do Auto: " .. SENS[AO.sens][1], false, false end, function()
			AO.sens = AO.sens % #SENS + 1
			AO.samples = {}
		end)
		addControl(p, function() return (State.watchNew and "● " or "○ ") .. "Otimizar objetos novos", State.watchNew, false end, function()
			State.watchNew = not State.watchNew
			syncWatch()
		end)
		addFeatureCycle(p, "Limite de FPS", "fpsCap", { 30, 60, 90, 120 }, function(v) return tostring(v) end)
		addInfo(p, function()
			local function y(b) return b and "sim" or "não" end
			local c = State.caps
			return "Suporte neste ambiente:\n"
				.. "Qualidade gráfica: " .. y(c.quality) .. "\n"
				.. "Iluminação Compatibility: " .. y(c.technology) .. "\n"
				.. "Decoração do terreno: " .. y(c.decoration) .. "\n"
				.. "Detalhe de malha: " .. y(c.meshDetail) .. "\n"
				.. "Render 3D on/off: " .. y(c.render3d) .. "\n"
				.. "Limite de FPS (executor): " .. y(c.fpsCap) .. "\n"
				.. "gethui (executor): " .. y(c.gethui)
		end)
		addControl(p, function() return "⏏ Descarregar Jczz FPS (restaura tudo)", false, false end, function()
			if genv.__JczzFPS then genv.__JczzFPS.Unload() end
		end)
	end

	local order = { "PERFORMANCE", "GRAPHICS", "EFFECTS", "MOBILE", "ADVANCED" }
	local short = { PERFORMANCE = "PERF", GRAPHICS = "GFX", EFFECTS = "FX", MOBILE = "MOBILE", ADVANCED = "ADV" }

	local function selectTab(name)
		for _, n in ipairs(order) do
			if pages[n] then pages[n].Visible = (n == name) end
			tabBtns[n].BackgroundColor3 = (n == name) and ACC or OFFC
		end
		if not built[name] then -- páginas criadas só na 1ª abertura (interface leve)
			built[name] = true
			pages[name] = newPage()
			builders[name](pages[name])
			pages[name].Visible = true
		end
		UI.refresh()
	end

	for _, n in ipairs(order) do
		local tb = mk("TextButton", { Size = UDim2.new(0.2, -3, 1, 0), BackgroundColor3 = OFFC,
			Text = short[n], TextColor3 = TXT, Font = Enum.Font.GothamBold, TextSize = 10 }, tabBar)
		mk("UICorner", { CornerRadius = UDim.new(0, 6) }, tb)
		tabBtns[n] = tb
		tb.MouseButton1Click:Connect(function() selectTab(n) end)
	end

	-- Atualiza aparência de todos os controles (chamado só quando algo muda)
	UI.refresh = function()
		for _, c in ipairs(Controls) do
			if c.btn then
				local ok, text, on_, un = pcall(c.render)
				if ok then
					c.btn.Text = text
					c.btn.BackgroundColor3 = un and BG2 or (on_ and ACC or OFFC)
					c.btn.TextColor3 = un and GRAY or TXT
				end
			elseif c.lbl then
				local ok, text = pcall(c.getText)
				if ok then c.lbl.Text = text end
			end
		end
	end

	-- Indicadores (chamado 1x/s, e só desenha se o painel estiver aberto)
	local function updateIndicators()
		local st, col = statusOf(State.fps)
		dot.BackgroundColor3 = col
		if not Panel.Visible then return end
		local modeText = State.mode and ((State.auto and "AUTO: " or "") .. State.mode) or "Original"
		ind1.Text = string.format("FPS %d  |  Ping %s  |  Mode %s", math.floor(State.fps + 0.5),
			State.ping and (State.ping .. "ms") or "--", modeText)
		sdot.BackgroundColor3 = col
		ind2.Text = string.format("%s  •  %d otimizações ativas%s", st, countActive(), State.busy and "  (aplicando...)" or "")
	end
	UI.updateIndicators = updateIndicators

	local function setPanel(v)
		Panel.Visible = v
		if v then
			State.ping = readPing()
			updateIndicators()
			UI.refresh()
		end
	end
	closeBtn.MouseButton1Click:Connect(function() setPanel(false) end)

	-- Arrastar o botão flutuante; toque curto abre/fecha o painel
	fab.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
		local startPos, basePos, moved = input.Position, fab.Position, false
		local moveConn
		moveConn = UserInputService.InputChanged:Connect(function(i)
			if i == input or i.UserInputType == Enum.UserInputType.MouseMovement then
				local d = i.Position - startPos
				if d.Magnitude > 8 then moved = true end
				if moved then
					fab.Position = UDim2.new(basePos.X.Scale, basePos.X.Offset + d.X,
						basePos.Y.Scale, basePos.Y.Offset + d.Y)
				end
			end
		end)
		local endConn
		endConn = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				moveConn:Disconnect()
				endConn:Disconnect()
				if not moved then setPanel(not Panel.Visible) end
			end
		end)
	end)

	selectTab("PERFORMANCE")
end

-- Tick de 1 segundo: indicadores, ping (a cada 2s) e Auto Optimizer
onSecond = function()
	if secCount % 2 == 0 then State.ping = readPing() end
	if UI.updateIndicators then UI.updateIndicators() end
	aoStep(State.fps)
end

--------------------------------------------------------------------------------
-- 7. INICIALIZAÇÃO E DESCARGA
--------------------------------------------------------------------------------
local function unload()
	pcall(restoreAll)
	if hbConn then hbConn:Disconnect() end
	for _, c in ipairs(Watch.conns) do c:Disconnect() end
	if Gui then Gui:Destroy() end
	genv.__JczzFPS = nil
end
genv.__JczzFPS = { Unload = unload, Version = "1.0" }

local okUI, errUI = pcall(buildUI)
if not okUI then
	warn("[Jczz FPS] Falha ao criar interface: " .. tostring(errUI))
end

-- Detecção inicial + perfil automático (o Auto Optimizer assume depois)
runAuto()
