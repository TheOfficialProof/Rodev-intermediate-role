local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local DifficultyRoll = require(script.Parent.DifficultyRoll)
local StageController = require(script.Parent.StageController)
local DataManager = require(ServerScriptService.Data.DataManager)
local ItemData = require(ReplicatedStorage.Modules.Info.ItemData)

local Stages = ServerStorage:WaitForChild("Stages")
local MatchRemote = ReplicatedStorage.Remotes:WaitForChild("RaceRemote")

local Races = {}
local ActiveMatches = {}

Races.__index = Races

function Races.new(player1, player2, lobby)
	local self = setmetatable({}, Races)
	self.Players = {player1, player2}
	self.Lobby = lobby
	self.CharacterConnections = {}
	self.State = "Waiting"
	
	self.Round = 1
	self.RaceTime = 40
	self.RoundTime = 30

	self.RoundStartedAt = nil
	self.FinishConnection = nil
	self.RoundEnded = false

	self.PlayerData = {
		[player1] = {
			TimeLeft = self.RaceTime,
			RoundTime = 0,
			RoundStartTime = nil,
			Finished = false,
			Running = false,
			Multiplier = 1,
		},

		[player2] = {
			TimeLeft = self.RaceTime,
			RoundTime = 0,
			RoundStartTime = nil,
			Finished = false,
			Running = false,
			Multiplier = 1,
		},
	}

	self.CurrentDifficulty = nil
	self.CurrentStage = nil
	return self
end

function Races:Start()
	if self.State == "Ended" then return end
	self.State = "Playing"

	for _, player in ipairs(self.Players) do
		self.CharacterConnections[player] =
			player.CharacterAdded:Connect(function(character)
				self:OnCharacterAdded(player, character)
			end)

		if player.Character then
			self:OnCharacterAdded(player, player.Character)
		end
		
		MatchRemote:FireClient(player, "MatchStarted", {
			Players = {{Player = self.Players[1],
				TimeLeft = self.PlayerData[self.Players[1]].TimeLeft},
				
				{Player = self.Players[2],
				TimeLeft = self.PlayerData[self.Players[2]].TimeLeft}
            },

			RaceTime = self.RaceTime,
			RoundTime = self.RoundTime,
		})
	end

	self:TeleportPlayers()
	task.wait(1.5)
	self:StartRound()
end

function Races:AnchorPlayer(player)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")

	if hrp then
		hrp.Anchored = true
	end
end

function Races:UnanchorPlayer(player)
	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")

	if hrp then
		hrp.Anchored = false
	end
end

function Races:StartRound()
	if self.State == "Ended" then return end
	self.RoundEnded = false

	for _, player in ipairs(self.Players) do
		local data = self.PlayerData[player]

		data.RoundTime = 0
		data.RoundStartTime = nil
		data.Finished = false
		data.Running = false
	end

	self.CurrentDifficulty = DifficultyRoll.Roll(self.Round)
	self.RoundTime = self.CurrentDifficulty.Timer
	
	for _, player in ipairs(self.Players) do

		local opponent

		if player == self.Players[1] then
			opponent = self.Players[2]
		else
			opponent = self.Players[1]
		end

		local myLuckyBlock = player.Inventory.EquippedBlock.Value
		local opponentLuckyBlock = opponent.Inventory.EquippedBlock.Value

		MatchRemote:FireClient(player, "RollDifficulty", {
			Difficulty = self.CurrentDifficulty.Name,
			MyLuckyBlock = ItemData[myLuckyBlock].Image,
			CurrentRound = self.Round
		})
	end
	task.wait(3)
	self:LoadStage()

	if not self.CurrentStage then
		warn("Failed to load race stage")
		return
	end

	task.wait(1)
	self:TeleportPlayersToStage()
	
	for _, player in ipairs(self.Players) do
		self:AnchorPlayer(player)
	end
	for i = 3, 1, -1 do
		for _, player in ipairs(self.Players) do
			MatchRemote:FireClient(player, "RaceCountdown", {Time = i})
		end
		task.wait(1)
	end
	for _, player in ipairs(self.Players) do
		self:UnanchorPlayer(player)
	end
	
	self.RoundStartedAt = os.clock()

	for _, player in ipairs(self.Players) do
		local data = self.PlayerData[player]

		data.RoundStartTime = self.RoundStartedAt
		data.Running = true

		self:UnanchorPlayer(player)
	end
	self:StartRoundTimer()
end

function Races:StartRoundTimer()
	local thisRound = self.Round

	task.spawn(function()
		for i = self.RoundTime, 0, -1 do
			if self.State == "Ended" then return end
			if self.RoundEnded then return end
			if self.Round ~= thisRound then return end

			for _, player in ipairs(self.Players) do
				MatchRemote:FireClient(player, "UpdateRoundTimer", {Time = i,})
			end

			for _, player in ipairs(self.Players) do
				local data = self.PlayerData[player]

				if data.Running and data.RoundStartTime then
					local timeTaken = os.clock() - data.RoundStartTime
				end
			end

			task.wait(1)
		end

		if self.State == "Ended" then return end
		if self.RoundEnded then return end
		if self.Round ~= thisRound then return end

		self:EndRound()
	end)
end

function Races:PlayerTimeExpired(player)
	if self.State == "Ended" then return end
	if self.RoundEnded then return end
	self.RoundEnded = true

	local opponent

	if player == self.Players[1] then
		opponent = self.Players[2]
	else
		opponent = self.Players[1]
	end

	self.PlayerData[player].TimeLeft = 0
	self.PlayerData[player].Running = false
	
	for _, plr in ipairs(self.Players) do
		local data = self.PlayerData[plr]
		local opponentData = self.PlayerData[opponent]

		MatchRemote:FireClient(plr, "RoundEnded", {
			Round = self.Round,
			TimeUsed = data.RoundTime,
			OpponentTimeUsed = opponentData.RoundTime,
			TimeLeft = data.TimeLeft,
			OpponentTimeLeft = opponentData.TimeLeft,
			Multiplier = data.Multiplier,
			OpponentMultiplier = opponentData.Multiplier,
		})
	end

	task.wait(5)

	if self.State == "Ended" then return end

	self:EndMatch(opponent)
end

function Races:PlayerFinished(player)
	if self.State == "Ended" then return end
	if self.RoundEnded then return end

	local data = self.PlayerData[player]
	if data.Finished then return end
	if data.Running and data.RoundStartTime then
		data.RoundTime = os.clock() - data.RoundStartTime
	end

	data.Running = false
	data.Finished = true
	local opponent

	if player == self.Players[1] then
		opponent = self.Players[2]
	else
		opponent = self.Players[1]
	end
	
	for _, plr in ipairs(self.Players) do
		MatchRemote:FireClient(plr, "RaceFinished", {
			Time = data.RoundTime,
			PlayerName = player.Name,
			Opponent = opponent.Name
		})
	end

	local player1Finished = self.PlayerData[self.Players[1]].Finished
	local player2Finished = self.PlayerData[self.Players[2]].Finished

	if player1Finished and player2Finished then
		self:EndRound()
	end
end

function Races:OnCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid")

	humanoid.Died:Connect(function()
		self:PlayerDied(player)
	end)
end

function Races:TeleportPlayers()
	local character1 = self.Players[1].Character or self.Players[1].CharacterAdded:Wait()
	local character2 = self.Players[2].Character or self.Players[2].CharacterAdded:Wait()

	character1:PivotTo(self.Lobby.SpawnCF1.CFrame * CFrame.new(1, 0, 0))
	character2:PivotTo(self.Lobby.SpawnCF2.CFrame * CFrame.new(-1, 0, 0))

	local hrp1 = character1:WaitForChild("HumanoidRootPart")
	local hrp2 = character2:WaitForChild("HumanoidRootPart")

	hrp1.Anchored = true
	hrp2.Anchored = true
end

function Races:PlayerDied(player)
	if self.State == "Ended" then return end
	if self.RoundEnded then return end

	local data = self.PlayerData[player]

	task.spawn(function()
		player:LoadCharacter()

		local character = player.Character or player.CharacterAdded:Wait()
		local hrp = character:WaitForChild("HumanoidRootPart")

		if self.State == "Ended" or self.RoundEnded then return end

		local stage = self.CurrentStage
		if not stage then
			warn("No current stage when respawning", player.Name)
			return
		end

		local teleport = stage:FindFirstChild("Teleport", true)
		if not teleport then
			warn("No Teleport found in current stage")
			return
		end

		character:PivotTo(teleport.CFrame * CFrame.new(0, 5, 0))

		hrp.Anchored = false

		if not data.Finished then
			data.Running = true
			data.RoundStartTime = self.RoundStartedAt
		end
	end)
end

function Races:ReturnPlayersToLobby()
	for _, player in ipairs(self.Players) do
		local character = player.Character
		if character then
			local spawn

			if player == self.Players[1] then
				spawn = self.Lobby.SpawnCF1
			else
				spawn = self.Lobby.SpawnCF2
			end

			character:PivotTo(spawn.CFrame)

			self:AnchorPlayer(player)
		end
	end
end

function Races:TeleportPlayersToStage()
	local character1 = self.Players[1].Character or self.Players[1].CharacterAdded:Wait()
	local character2 = self.Players[2].Character or self.Players[2].CharacterAdded:Wait()

	local teleport = self.CurrentStage:FindFirstChild("Teleport", true)

	if not teleport then
		warn("No Teleport found in stage")
		return
	end
	
	local offset = 1.5
	character1:PivotTo(teleport.CFrame * CFrame.new(-offset, 5, 0))
	character2:PivotTo(teleport.CFrame * CFrame.new(offset, 5, 0))

	self:UnanchorPlayer(self.Players[1])
	self:UnanchorPlayer(self.Players[2])
end

function Races:LoadStage()
	if self.State == "Ended" then return end

	if self.FinishConnection then
		self.FinishConnection:Disconnect()
		self.FinishConnection = nil
	end

	if self.CurrentStage then
		self.CurrentStage:Destroy()
		self.CurrentStage = nil
	end

	local folder = Stages:FindFirstChild(self.CurrentDifficulty.Name)

	if not folder then
		warn(
			"Couldn't find difficulty:",
			self.CurrentDifficulty.Name
		)
		return
	end

	local stageList = folder:GetChildren()

	if #stageList == 0 then
		warn("No stages found for difficulty:", self.CurrentDifficulty.Name)
		return
	end

	local template = stageList[math.random(1, #stageList)]
	local stage = template:Clone()

	stage.Parent = self.Lobby

	local currentPivot = stage:GetPivot()

	stage:PivotTo(CFrame.new(self.Lobby.ObbySpawn.Position)	* (currentPivot - currentPivot.Position))

	self.CurrentStage = stage
	StageController.SetUp(self, stage)

	local finish = stage:FindFirstChild("Finish", true)

	if not finish then
		warn("No Finish found in stage")
		return
	end

	self.FinishConnection = finish.Touched:Connect(function(hit)
		local character = hit.Parent
		if not character then return end

		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end

		if table.find(self.Players, player) then
			self:PlayerFinished(player)
		end
	end)
end

function Races:EndRound()
	if self.State == "Ended" then return end
	if self.RoundEnded then return end
	self.RoundEnded = true

	local player1 = self.Players[1]
	local player2 = self.Players[2]

	local data1 = self.PlayerData[player1]
	local data2 = self.PlayerData[player2]

	if not data1.Finished and not data2.Finished then
		data1.RoundTime = 0
		data2.RoundTime = 0

		data1.Running = false
		data2.Running = false

		self:TeleportPlayers()
		for _, player in ipairs(self.Players) do
			MatchRemote:FireClient(player, "HideRaceTime")
		end
		task.wait(0.5)

		for _, player in ipairs(self.Players) do
			local data = self.PlayerData[player]
			local opponent

			if player == self.Players[1] then
				opponent = self.Players[2]
			else
				opponent = self.Players[1]
			end

			local opponentData = self.PlayerData[opponent]
			task.wait(.8)
			MatchRemote:FireClient(player, "RoundEnded", {
				Round = self.Round,
				TimeUsed = data.RoundTime,
				OpponentTimeUsed = opponentData.RoundTime,
				TimeLeft = data.TimeLeft,
				OpponentTimeLeft = opponentData.TimeLeft,
				Multiplier = data.Multiplier,
				OpponentMultiplier = opponentData.Multiplier,
			})
		end

		task.wait(2)
		if self.State == "Ended" then return end

		self.Round += 1
		self:StartRound()

		return
	end

	if not data1.Finished then
		data1.RoundTime = self.RoundTime
		data1.Running = false
	end

	if not data2.Finished then
		data2.RoundTime = self.RoundTime
		data2.Running = false
	end

	local slowerPlayer
	local slowerData

	if data1.RoundTime > data2.RoundTime then
		slowerPlayer = player1
		slowerData = data1
	elseif data2.RoundTime > data1.RoundTime then
		slowerPlayer = player2
		slowerData = data2
	end

	if slowerPlayer then
		local winner

		if slowerPlayer == player1 then
			winner = player2
		else
			winner = player1
		end

		local winnerData = self.PlayerData[winner]
		local appliedMultiplier = winnerData.Multiplier
		local timeDifference = slowerData.RoundTime - winnerData.RoundTime
		local timeLost = timeDifference * appliedMultiplier

		slowerData.TimeLeft = math.max(0, slowerData.TimeLeft - timeLost)
		winnerData.Multiplier += 0.5
	end
	
	self:TeleportPlayers()
	task.wait(1)
	for _, player in ipairs(self.Players) do
		local data = self.PlayerData[player]

		local opponent

		if player == self.Players[1] then
			opponent = self.Players[2]
		else
			opponent = self.Players[1]
		end

		local opponentData = self.PlayerData[opponent]

		MatchRemote:FireClient(player, "RoundEnded", {
			Round = self.Round,
			TimeUsed = data.RoundTime,
			OpponentTimeUsed = opponentData.RoundTime,
			TimeLeft = data.TimeLeft,
			OpponentTimeLeft = opponentData.TimeLeft,
			Multiplier = data.Multiplier,
			OpponentMultiplier = opponentData.Multiplier,
		})
	end

	if data1.TimeLeft <= 0 then
		task.wait(4)
		self:EndMatch(player2)
		return
	end

	if data2.TimeLeft <= 0 then
		task.wait(4)
		self:EndMatch(player1)
		return
	end

	task.wait(4)
	if self.State == "Ended" then return end

	self.Round += 1
	self:StartRound()
end

function Races:EndMatch(winner)
	if self.State == "Ended" then return end
	self.State = "Ended"

	for _, connection in pairs(self.CharacterConnections) do
		connection:Disconnect()
	end
	for _, player in ipairs(self.Players) do
		MatchRemote:FireClient(player, "MatchEnded", {
			Winner = winner.Name,
		})
	end
	
	DataManager.AddCash(winner, 100)
	DataManager.AddWins(winner, 1)

	task.wait(2)
	self.Lobby:SetAttribute("InUse", false)

	for _, player in ipairs(self.Players) do
		local character = player.Character
		if not character then continue end


		local hrp = character:FindFirstChild("HumanoidRootPart")
		character:PivotTo(workspace.SpawnLocation.CFrame * CFrame.new(0, 5, 0))

		if hrp then
			hrp.Anchored = false
		end
	end

	if self.FinishConnection then
		self.FinishConnection:Disconnect()
		self.FinishConnection = nil
	end

	if self.CurrentStage then
		self.CurrentStage:Destroy()
		self.CurrentStage = nil
	end

	Races.Remove(self)
end


function Races.Create(player1, player2, lobby)
	local match = Races.new(player1, player2, lobby)

	table.insert(ActiveMatches, match)
	match:Start()
	
	return match
end


function Races.Remove(match)
	local index = table.find(ActiveMatches, match)

	if index then
		table.remove(ActiveMatches, index)
	end
end


function Races.GetMatch(player)
	for _, match in ipairs(ActiveMatches) do
		if table.find(match.Players, player) then
			return match
		end
	end

	return nil
end

Players.PlayerRemoving:Connect(function(player)
	local match = Races.GetMatch(player)
	if not match then return end
	if match.State == "Ended" then return end

	local opponent

	if player == match.Players[1] then
		opponent = match.Players[2]
	else
		opponent = match.Players[1]
	end

	if opponent and opponent.Parent == Players then
		match:EndMatch(opponent)
	end
end)


return Races
