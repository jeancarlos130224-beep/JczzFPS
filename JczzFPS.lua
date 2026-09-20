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
	UI.t
