--!strict
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")

local Packages = script.Parent

local GoodSignal = require(Packages.goodsignal)
local Trove = require(Packages.trove)

local AnimationManager = {}
AnimationManager.__index = AnimationManager

local DEBUG = true

type SetChangedSignal = GoodSignal.Signal<string?> & {
	DisconnectAll: (self: SetChangedSignal) -> (),
}

export type AnimationListTemplate = {
	["Individual"]: {
		[string]: Animation,
	},
	["Core"]: {
		[string]: Animation,
	},
	[string]: {
		[string]: Animation,
	},
}

export type AnimationManagerData = {
	_player: Player?,
	_char: Model,
	_humanoid: Humanoid,
	_animator: Animator,
	_animationList: AnimationListTemplate,
	_animationFolder: Folder,

	_coreAnimations: { [string]: Animation },
	_setAnimations: { [string]: Animation },
	_individualAnimations: { [string]: Animation },
	_currentSet: string?,

	_aliveTrove: Trove.Trove,
	_setChanged: SetChangedSignal,
	_destroyed: boolean,
}

export type AnimationManager = typeof(setmetatable({} :: AnimationManagerData, AnimationManager))

--// Constructor
function AnimationManager.new(
	char: Model,
	AnimationList: AnimationListTemplate,
	AnimationFolder: Folder
): AnimationManager
	assert(char and char:IsA("Model"), "[AnimationManager]: char must be a Model")
	assert(char and char:FindFirstChildWhichIsA("Humanoid"), "[AnimationManager]: char must have a Humanoid")
	assert(AnimationList and type(AnimationList) == "table", "[AnimationManager]: AnimationList must be a table")
	assert(AnimationFolder and AnimationFolder:IsA("Folder"), "[AnimationManager]: AnimationFolder must be a Folder")
	local self = setmetatable({} :: AnimationManagerData, AnimationManager) :: AnimationManager

	-->> Player and Character References
	self._player = Players:GetPlayerFromCharacter(char)
	self._char = char
	self._humanoid = char:WaitForChild("Humanoid") :: Humanoid
	self._animator = self._humanoid:WaitForChild("Animator") :: Animator
	self._animationList = AnimationList
	self._animationFolder = AnimationFolder

	-->> Animation registrations (configure identically on client and server)
	self._coreAnimations = {}
	self._setAnimations = {}
	self._individualAnimations = {}

	-->> Sets
	self._currentSet = nil
	self._setChanged = GoodSignal.new() :: SetChangedSignal

	-->> Cleanup
	self._destroyed = false
	self._aliveTrove = Trove.new()
	local setChanged = self._setChanged
	self._aliveTrove:Add(function()
		setChanged:DisconnectAll()
	end)
	-- Predicted death can be rolled back; clean up when the character is destroyed.
	self._aliveTrove:Add(char.Destroying:Connect(function()
		self:Destroy()
	end))
	if self._player then
		self._aliveTrove:Add(Players.PlayerRemoving:Connect(function(player: Player)
			if player == self._player then
				self:Destroy()
			end
		end))
	end

	-->> Initialization
	self:Preload()
	if not self._destroyed then
		self:LoadCore()
	end

	return self
end

--// Connections
function AnimationManager.OnSetChanged(self: AnimationManager, callback: (string?) -> ()): GoodSignal.Connection
	assert(not self._destroyed, "[AnimationManager]: Cannot subscribe after destruction")
	return self._aliveTrove:Add(self._setChanged:Connect(function(setName: string?)
		if not self._destroyed then
			callback(setName)
		end
	end), "Disconnect")
end

-- Track connections observe the current track only; reconnect if rollback replaces it.
function AnimationManager.OnTrackStopped(self: AnimationManager, name: string, callback: () -> ()): RBXScriptConnection?
	if self._destroyed then
		return nil
	end
	local animation = self._individualAnimations[name] or self._setAnimations[name] or self._coreAnimations[name]
	if not animation then
		return nil
	end

	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if not track then
		return nil
	end

	return self._aliveTrove:Add(track.Stopped:Connect(function()
		if not self._destroyed then
			callback()
		end
	end))
end

function AnimationManager.MarkerReached(
	self: AnimationManager,
	animName: string,
	markerName: string,
	callback: (string) -> ()
): RBXScriptConnection?
	if self._destroyed then
		return nil
	end
	local animation = self._individualAnimations[animName]
		or self._setAnimations[animName]
		or self._coreAnimations[animName]
	if not animation then
		return nil
	end

	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if not track then
		return nil
	end

	return self._aliveTrove:Add(track:GetMarkerReachedSignal(markerName):Connect(function(parameter: string)
		if not self._destroyed then
			callback(parameter)
		end
	end))
end

--// Loading Animations
function AnimationManager:Preload()
	assert(
		self._animationFolder and self._animationFolder:IsA("Folder"),
		"[AnimationManager]: AnimationFolder must be a Folder"
	)
	local animsToPreload = {}

	for _, v in pairs(self._animationFolder:GetDescendants()) do
		if v:IsA("Animation") then
			table.insert(animsToPreload, v)
		end
	end
	if DEBUG then
		print("[AnimationManager]: Preloading animations...")
	end
	ContentProvider:PreloadAsync(animsToPreload)
	if DEBUG then
		print(`[AnimationManager]: Preloaded {#animsToPreload} animations.`)
	end
end

function AnimationManager.LoadCore(self: AnimationManager)
	if self._destroyed then return end
	assert(self._animationList["Core"], "[AnimationManager]: Core animations not found in AnimationList")
	self:UnloadCoreTracks()

	for i, v in pairs(self._animationList["Core"]) do
		self._coreAnimations[i] = v
	end

	if DEBUG then
		print("[AnimationManager]: Core animations loaded")
	end
end

function AnimationManager.LoadIndividualTrack(self: AnimationManager, name: string)
	if self._destroyed then return nil end
	assert(
		self._animationList["Individual"][name],
		"[AnimationManager]: Individual animation not found in AnimationList"
	)
	if self._individualAnimations[name] then
		return self._individualAnimations[name]
	end

	local t = self._animationList.Individual[name]

	self._individualAnimations[name] = t

	if DEBUG then
		print("[AnimationManager]: Individual animation " .. name .. " loaded")
	end

	return t
end

function AnimationManager.LoadSet(self: AnimationManager, setName: string)
	if self._destroyed then return end
	assert(self._animationList[setName], "[AnimationManager]: Set not found in AnimationList")

	local previousSet = self._currentSet
	local previousAnimations = self._setAnimations
	self._setAnimations = {}

	self._currentSet = setName
	for i, v in pairs(self._animationList[setName]) do
		self._setAnimations[i] = v
	end
	self:_stopUnusedAnimations(previousAnimations)
	if previousSet ~= setName then
		self._setChanged:Fire(setName)
	end

	if DEBUG then
		print("[AnimationManager]: Set " .. setName .. " loaded")
	end
end

--// Unloading Animations
-- Resolve tracks only when needed, and preserve IDs registered in another group.
function AnimationManager._stopUnusedAnimations(self: AnimationManager, animations: { [string]: Animation })
	local retained: { [string]: boolean } = {}
	for _, group in { self._coreAnimations, self._setAnimations, self._individualAnimations } do
		for _, animation in group do
			retained[animation.AnimationId] = true
		end
	end
	for _, animation in animations do
		if not retained[animation.AnimationId] then
			local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
			if track then
				if not track.IsPlaying and track.WeightCurrent == 0 then
					-- Already ended (or never played): no future Ended event to wait for.
					track:Destroy()
				else
					-- This one-shot owns cleanup independently of the manager's Trove,
					-- so Destroy() cannot disconnect it before the fade has finished.
					track.Ended:Once(function()
						-- An unload/reload during the fade may have reclaimed this track.
						for _, group in { self._coreAnimations, self._setAnimations, self._individualAnimations } do
							for _, registered in group do
								if registered.AnimationId == animation.AnimationId then
									return
								end
							end
						end
						if not track.IsPlaying then
							track:Destroy()
						end
					end)
					track:Stop(0)
				end
			end
			retained[animation.AnimationId] = true
		end
	end
end

function AnimationManager.UnloadCoreTracks(self: AnimationManager)
	local animations = self._coreAnimations
	self._coreAnimations = {}
	self:_stopUnusedAnimations(animations)
end

function AnimationManager.UnloadSet(self: AnimationManager)
	local animations = self._setAnimations
	self._setAnimations = {}
	self:_stopUnusedAnimations(animations)

	local previousSet = self._currentSet
	self._currentSet = nil
	if previousSet ~= nil and not self._destroyed then
		self._setChanged:Fire(nil)
	end
end

function AnimationManager.UnloadIndividualTrack(self: AnimationManager, name: string)
	local animation: Animation = self._individualAnimations[name]
	if not animation then
		return
	end

	self._individualAnimations[name] = nil
	self:_stopUnusedAnimations({ [name] = animation })
end

function AnimationManager.UnloadIndividualTracks(self: AnimationManager)
	local animations = self._individualAnimations
	self._individualAnimations = {}
	self:_stopUnusedAnimations(animations)
end

function AnimationManager._getOrLoadTrack(self: AnimationManager, animation: Animation)
	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if track then
		return track
	end

	track = self._animator:LoadAnimation(animation)

	return track
end

--// Playing Animations
-- Call playback methods from the caller's shared BindToSimulation callback.
-- Each call performs one operation; the manager creates no simulation bindings.
function AnimationManager.Play(self: AnimationManager, name: string, fadeTime: number?)
	if self._destroyed then return end
	local animation: Animation = self._individualAnimations[name] or self._setAnimations[name] or self._coreAnimations[name]
	if not animation then
		warn(`[AnimationManager]: {name} is not loaded`)
		return
	end

	local track = self:_getOrLoadTrack(animation)
	if not track.IsPlaying then
		track:Play(fadeTime)
	end
end

--// Stopping Animations
function AnimationManager.Stop(self: AnimationManager, name: string, fadeTime: number?)
	if self._destroyed then return end
	local animation: Animation = self._individualAnimations[name] or self._setAnimations[name] or self._coreAnimations[name]
	if not animation then
		warn(`[AnimationManager]: {name} is not loaded`)
		return
	end

	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if track and track.IsPlaying then
		track:Stop(fadeTime)
	end
end

function AnimationManager.StopAll(self: AnimationManager, fadeTime: number?)
	if self._destroyed then return end
	for _, animations in { self._coreAnimations, self._setAnimations, self._individualAnimations } do
		for _, animation in pairs(animations) do
			local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
			if track and track.IsPlaying then
				track:Stop(fadeTime)
			end
		end
	end
end

--// Adjusting Animations
function AnimationManager.AdjustSpeed(self: AnimationManager, name: string, speed: number)
	if self._destroyed then return end
	local animation: Animation = self._individualAnimations[name] or self._setAnimations[name] or self._coreAnimations[name]
	if not animation then
		warn("[AnimationManager]: Animation " .. name .. " not loaded")
		return
	end

	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if track then
		track:AdjustSpeed(speed)
	end
end

--// Information Getters
function AnimationManager.GetCurrentSet(self: AnimationManager): string?
	return self._currentSet
end

function AnimationManager.IsIndividualLoaded(self: AnimationManager, animation: string): boolean
	return self._individualAnimations[animation] ~= nil
end

function AnimationManager.IsSet(self: AnimationManager, setName: string): boolean
	return self._currentSet == setName
end

function AnimationManager.IsPlaying(self: AnimationManager, animation: string): boolean
	local anim = self._individualAnimations[animation] or self._setAnimations[animation] or self._coreAnimations[animation]
	if not anim then
		return false
	end
	local track = self._animator:GetTrackByAnimationId(anim.AnimationId)

	return track ~= nil and track.IsPlaying
end

function AnimationManager.GetLoadedTracks(self: AnimationManager): (
	{ AnimationTrack },
	{ [string]: AnimationTrack },
	{ [string]: AnimationTrack },
	{ [string]: AnimationTrack }
)
	local tracks: { AnimationTrack } = {}
	local coreTracks: { [string]: AnimationTrack } = {}
	local setTracks: { [string]: AnimationTrack } = {}
	local individualTracks: { [string]: AnimationTrack } = {}

	for index, animations in { self._coreAnimations, self._setAnimations, self._individualAnimations } do
		local loadedTracks = ({ coreTracks, setTracks, individualTracks })[index]
		for name, animation in pairs(animations) do
			local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
			if track then
				loadedTracks[name] = track
				table.insert(tracks, track)
			end
		end
	end
	return tracks, coreTracks, setTracks, individualTracks
end

function AnimationManager.GetLength(self: AnimationManager, name: string): number?
	local animation = self._individualAnimations[name] or self._setAnimations[name] or self._coreAnimations[name]
	if not animation then
		return nil
	end

	local track = self._animator:GetTrackByAnimationId(animation.AnimationId)
	if not track then
		return nil
	end
	return track.Length
end

--// Cleanup
function AnimationManager.Destroy(self: AnimationManager)
	if self._destroyed then
		return
	end
	self._destroyed = true

	self._aliveTrove:Destroy()
	self:UnloadCoreTracks()
	self:UnloadSet()
	self:UnloadIndividualTracks()
end

return AnimationManager
