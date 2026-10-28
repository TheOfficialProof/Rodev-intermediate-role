local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local ZonePlus = require(ReplicatedStorage.Modules.Zone)
local MatchManager = require(ServerScriptService.MatchServer.MatchManager)

local MatchLobbies = workspace:WaitForChild("MatchLobbies")
local TeleportZones = game.Workspace.TeleportZones
local Configuration = TeleportZones.Configuration
local QueueRemote = Remotes:WaitForChild("QueueSystem"):WaitForChild("QueueRemote")

local ZoneData = {}
local PlayerConnections = {}

local function SafeDisconnect(connection)
	if connection and connection.Connected then
		connection:Disconnect()
	end
end

local function GetAvailableLobby()
	for _, lobby in ipairs(MatchLobbies:GetChildren()) do
		if not lobby:GetAttribute("InUse") then
			lobby:SetAttribute("InUse", true)
			return lobby
		end
	end

	return nil
end

local function UpdateBillboard(TpZones)
	local Data = ZoneData[TpZones]
	TpZones.BillboardGui.PlayerCount.Text = #Data.Players .. "/" .. Configuration.MaxPlayers.Value
end

local function StartMatch(tpZone)
	local data = ZoneData[tpZone]
	local player1 = data.Players[1]
	local player2 = data.Players[2]
	local gamemode = tpZone:GetAttribute("Mode")

	if not gamemode then
		warn("No Gamemode attribute on", tpZone.Name)
		return
	end

	local lobby = GetAvailableLobby()

	if not lobby then
		warn("No available lobbies!")
		return
	end

	table.clear(data.Players)
	UpdateBillboard(tpZone)
	data.CountdownRunning = false

	MatchManager.Create(player1, player2, lobby, gamemode)
end

local function StartCountdown(TpZones, plr)
	local Data = ZoneData[TpZones]
	if Data.CountdownRunning then return end

	Data.CountdownRunning = true

	task.spawn(function()
		for i = Configuration.Countdown.Value,1,-1 do
			if #Data.Players < Configuration.MaxPlayers.Value then
				Data.CountdownRunning = false
				TpZones.BillboardGui.StateLabel.Text = "Waiting for player..."
				return
			end
			TpZones.BillboardGui.StateLabel.Text = "Starting in "..i
			task.wait(1)
		end
		TpZones.BillboardGui.StateLabel.Text = "Teleporting..."
		for _, player in ipairs(Data.Players) do
			QueueRemote:FireClient(player, "Teleporting")
		end
		task.wait(1)

		local player1 = Data.Players[1]
		local player2 = Data.Players[2]
		if not player1 or not player2 then return end

		StartMatch(TpZones)
		Data.CountdownRunning = false
	end)
end

function JoinParty(plr, ZoneContainer, TpZones)
	if table.find(ZoneData[TpZones].Players, plr) then return end
	table.insert(ZoneData[TpZones]["Players"], plr)
	UpdateBillboard(TpZones)
	QueueRemote:FireClient(plr, "JoinParty")

	local MatchUi = plr.PlayerGui.Main
	PlayerConnections[plr] = PlayerConnections[plr] or {}

	PlayerConnections[plr].Leave = MatchUi.LeaveButton.MouseButton1Click:Connect(function()
		LeaveParty(plr, TpZones)
	end)

	local Char = plr.Character
	if not Char then return end
	Char:PivotTo(ZoneContainer.CFrame * CFrame.new(0, 3, 0))

	if #ZoneData[TpZones].Players == Configuration.MaxPlayers.Value then
		StartCountdown(TpZones)
	end
end

function LeaveParty(plr, TpZones)
	if PlayerConnections[plr] then
		SafeDisconnect(PlayerConnections[plr].Leave)
		PlayerConnections[plr] = nil
	end

	local index = table.find(ZoneData[TpZones].Players, plr)

	if index then
		table.remove(ZoneData[TpZones].Players, index)
	end

	QueueRemote:FireClient(plr, "LeaveParty")
	local Char = plr.Character
	if not Char then return end
	Char:PivotTo(TeleportZones.LobbyPos.CFrame * CFrame.new(0, 3, 0))
	UpdateBillboard(TpZones)
	TpZones.BillboardGui.StateLabel.Text = "Waiting..."
	local data = ZoneData[TpZones]

	if #data.Players == 0 then
		data.CountdownRunning = false
	end
end

for _, TpZones in pairs(TeleportZones:GetChildren()) do
	if TpZones:IsA("Model") then

		ZoneData[TpZones] = {
			Players = {},
			CountdownRunning = false,
		}

		local ZoneContainer = TpZones.ZoneContainer
		local Zone = ZonePlus.new(ZoneContainer)

		Zone.playerEntered:Connect(function(player)
			local data = ZoneData[TpZones]

			if #data.Players < Configuration.MaxPlayers.Value then
				JoinParty(player, ZoneContainer, TpZones)
			end
		end)

		Zone.playerExited:Connect(function(player)
			local match = MatchManager.GetMatch(player)
			if match then return end

			if table.find(ZoneData[TpZones].Players, player) then
				LeaveParty(player, TpZones)
			end
		end)
	end
end

Players.PlayerRemoving:Connect(function(player)
	local match = MatchManager.GetMatch(player)

	if match then
		local opponent

		if player == match.Players[1] then
			opponent = match.Players[2]
		else
			opponent = match.Players[1]
		end

		if opponent and opponent.Parent == Players then
			match:EndMatch(opponent)
		end
		return
	end

	for TpZones, data in pairs(ZoneData) do
		if table.find(data.Players, player) then
			LeaveParty(player, TpZones)
			break
		end
	end
end)
