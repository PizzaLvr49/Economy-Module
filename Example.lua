local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")

-- Get the Economy module
local Economy = require(ServerStorage.Economy)

-- Log a player's money
local function logPlayerMoney(player)
	local cashCurrency = Economy.GetCurrency("Cash")
	if not cashCurrency then return end

	local cash = cashCurrency:GetValue(player.UserId)
	print(player.Name .. " has " .. cash .. " cash")
end

-- Give starting cash to new players
local function onPlayerJoin(player)
	-- Wait for profile to load
	task.wait(2)

	local cashCurrency = Economy.GetCurrency("Cash")
	if not cashCurrency then return end

	-- Log initial amount
	local cash = cashCurrency:GetValue(player.UserId)
	print(player.Name .. " joined with " .. cash .. " cash")

	-- Give starting cash if new player
	if cash == 0 then
		cashCurrency:SetValue(player.UserId, 100)
		print(player.Name .. " received 100 starting cash")
		logPlayerMoney(player)
	end
end

-- Reward active players
local function giveActivePlayersReward()
	local cashCurrency = Economy.GetCurrency("Cash")
	local gemCurrency = Economy.GetCurrency("Gems")
	if not cashCurrency then return end
	if not gemCurrency then return end

	for _, player in ipairs(Players:GetPlayers()) do
		-- Add reward
		local oldCash = cashCurrency:GetValue(player.UserId)
		local oldGems = gemCurrency:GetValue(player.UserId)
		cashCurrency:IncrementValue(player.UserId, 10)
		gemCurrency:IncrementValue(player.UserId, 1)

		-- Log the reward
		print(player.Name .. ": " .. oldCash .. " cash → " .. (oldCash + 10) .. " cash (+10)")
		print(player.Name .. ": " .. oldGems .. " gems → " .. (oldGems + 1) .. " gems (+1)")
	end
end

-- Connect player events
Players.PlayerAdded:Connect(onPlayerJoin)
Players.PlayerRemoving:Connect(function(player)
	logPlayerMoney(player)
	print(player.Name .. " left the game")
end)

-- Main loop - reward and log every 5 minutes
task.wait(2)
while true do
	task.wait(0.2)
	print("--- Giving rewards to all players ---")
	giveActivePlayersReward()

	print("--- Current player balances ---")
	for _, player in ipairs(Players:GetPlayers()) do
		logPlayerMoney(player)
	end
end
